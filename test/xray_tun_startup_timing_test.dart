import 'dart:convert';
import 'dart:io';

import 'package:entropy_vpn/models/split_tunnel.dart';
import 'package:entropy_vpn/models/vpn_profile.dart';
import 'package:entropy_vpn/services/core_config_builder.dart';
import 'package:entropy_vpn/services/core_runtime_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prints generated Xray TUN config build time', () {
    final builder = CoreConfigBuilder();
    const profile = ParsedVpnProfile(
      protocol: LinkProtocol.vless,
      server: '203.0.113.8',
      port: 443,
      transport: TransportMode.raw,
      tlsMode: TlsMode.tls,
      userId: '11111111-1111-1111-1111-111111111111',
      sni: 'example.com',
    );

    late Map<String, dynamic> config;
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < 500; i += 1) {
      config = builder.buildFor(
        CoreFlavor.xray,
        profile,
        trafficMode: TrafficMode.tun,
        tunIpMode: TunIpMode.ipv4,
        tunInterfaceName: 'EntropyVPN TUN timing',
        outboundBindInterface: 'Ethernet',
        xrayServerAddressOverride: '203.0.113.8',
      );
    }
    stopwatch.stop();

    final perBuildMicros = stopwatch.elapsedMicroseconds / 500;

    print(
      'Xray TUN config build timing: total=${stopwatch.elapsedMicroseconds}us, per_build=${perBuildMicros.toStringAsFixed(1)}us.',
    );

    final inbound = (config['inbounds'] as List<dynamic>).single as Map;
    expect(inbound['protocol'], 'tun');
  });

  test(
    'starts real Windows Xray TUN when elevated',
    () async {
      if (!Platform.isWindows) {
        print('Xray TUN startup timing: skipped because this is not Windows.');
        return;
      }
      if (Platform.environment['ENTROPYVPN_RUN_XRAY_TUN_STARTUP_TEST'] == '0') {
        print(
          'Xray TUN startup timing: real start skipped because ENTROPYVPN_RUN_XRAY_TUN_STARTUP_TEST=0.',
        );
        return;
      }
      if (!await _isRunningAsAdministrator()) {
        print(
          'Xray TUN startup timing: real start skipped because the test process is not elevated.',
        );
        return;
      }

      final service = CoreRuntimeService();
      final observedLogs = <String>[];
      service.onLogUpdated = () {
        final line = service.lastLogLine;
        if (line != null) {
          observedLogs.add(line);
        }
      };

      final profile = ParsedVpnProfile.xrayConfig(
        server: '127.0.0.1',
        port: 443,
        configJson: jsonEncode(<String, dynamic>{
          'log': <String, dynamic>{'loglevel': 'warning'},
          'inbounds': <Map<String, dynamic>>[
            <String, dynamic>{
              'tag': 'tun-in',
              'protocol': 'tun',
              'settings': <String, dynamic>{
                'name': 'EntropyVPN TUN',
                'MTU': CoreConfigBuilder.tunMtu,
                'userLevel': 0,
              },
            },
          ],
          'outbounds': <Map<String, dynamic>>[
            <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
          ],
        }),
      );

      final stopwatch = Stopwatch()..start();
      Object? startError;
      try {
        await service.start(
          core: CoreFlavor.xray,
          profile: profile,
          language: AppLanguage.en,
          trafficMode: TrafficMode.tun,
          tunIpMode: TunIpMode.ipv4,
          splitTunnelSettings: const SplitTunnelSettings(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } catch (error) {
        startError = error;
      } finally {
        stopwatch.stop();
        await service.stop();
      }

      final timingLines = observedLogs
          .where((line) => line.contains('Startup timing:'))
          .toList(growable: false);

      print(
        'Xray TUN startup wall timing: ${stopwatch.elapsedMilliseconds}ms.',
      );
      for (final line in timingLines) {
        print(line);
      }

      expect(startError, isNull);
      expect(
        observedLogs.any(
          (line) =>
              line.contains('Failed to prepare Xray TUN adapter and routes'),
        ),
        isFalse,
      );
      expect(
        observedLogs.any((line) => line.contains('Xray TUN adapter ready:')),
        isTrue,
      );
      expect(timingLines, isNotEmpty);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'Windows Xray TUN setup delegates fallback choice to native runner',
    () async {
      final source = await _runtimeServiceSource();
      expect(source, contains('prepareXrayTunRoutes'));
      expect(source, isNot(contains('prepareXrayTunRoutesOnly')));
      expect(source, isNot(contains('prepareXrayTunAdapterAndRoutes')));
      expect(source, isNot(contains('xray_tun_route_only')));
      expect(source, isNot(contains('xray_tun_adapter_routes')));
      expect(source, isNot(contains(r'Get-NetAdapter -Name $InterfaceAlias')));
    },
  );

  test('Windows service startup uses native service control', () async {
    final source = await _runtimeServiceSource();
    expect(source, contains('startWindowsService'));
    expect(source, isNot(contains("Process.run('sc.exe'")));
    expect(source, isNot(contains('Process.run("sc.exe"')));
  });

  test('Windows service pipe client uses native runner', () async {
    final source = await _runtimeServiceSource();
    expect(source, contains('runWindowsServiceHelper'));
    expect(source, isNot(contains('_sendWindowsServicePipeRequest')));
    expect(source, isNot(contains('_buildWindowsServiceRequest')));
    expect(source, isNot(contains('_parseWindowsServiceResponse')));
    expect(source, isNot(contains('WaitNamedPipeW')));
    expect(source, isNot(contains('Isolate.run')));
  });

  test('Windows service Xray TUN setup starts core before routes', () async {
    final source = await File(
      'lib/services/core_runtime_service_lifecycle.dart',
    ).readAsString();
    final branchStart = source.indexOf(
      'if (needsXrayTunRoutes && _windowsTunServiceReady)',
    );
    final coreStart = source.indexOf("'core_process_start'", branchStart);
    final routeSetup = source.indexOf("'xray_tun_adapter_routes'", branchStart);

    expect(branchStart, greaterThanOrEqualTo(0));
    expect(coreStart, greaterThan(branchStart));
    expect(routeSetup, greaterThan(coreStart));
    expect(source, isNot(contains('tunRoutesFuture')));
  });

  test(
    'Windows Xray TUN route setup replaces stale interface routes',
    () async {
      final nativeTunSource = await File(
        'windows/runner/windows_tun_channel/windows_tun_channel_routes.inc',
      ).readAsString();
      final nativeTunWrapper = await File(
        'windows/runner/entropy_vpn_native_tun.cpp',
      ).readAsString();

      expect(nativeTunWrapper, contains('ENTROPY_VPN_NATIVE_TUN_ONLY'));
      expect(nativeTunSource, contains('RemoveConflictingIpv4Routes'));
      expect(
        nativeTunSource,
        contains('route.InterfaceIndex != interface_index'),
      );
      expect(nativeTunSource, contains('"replaced"'));
    },
  );

  test(
    'Windows runner and service share native protocol and route helpers',
    () async {
      final cmake = await File('windows/runner/CMakeLists.txt').readAsString();
      final runnerSource = await File(
        'windows/runner/windows_tun_channel.cpp',
      ).readAsString();
      final serviceSource = await File(
        'windows/runner/entropy_vpn_service.cpp',
      ).readAsString();
      final servicePipeSource = await File(
        'windows/runner/windows_tun_channel/windows_tun_channel_service.inc',
      ).readAsString();

      expect(cmake, contains('add_library(entropy_vpn_windows_native STATIC'));
      expect(
        cmake,
        contains(
          'target_link_libraries(\${BINARY_NAME} PRIVATE entropy_vpn_windows_native)',
        ),
      );
      expect(
        cmake,
        contains(
          'target_link_libraries(entropy_vpn_service PRIVATE entropy_vpn_windows_native)',
        ),
      );
      expect(runnerSource, contains('entropy_vpn_service_protocol.h'));
      expect(serviceSource, contains('entropy_vpn_service_protocol.h'));
      expect(servicePipeSource, isNot(contains('ServiceBase64Encode')));
      expect(servicePipeSource, isNot(contains('ParseServiceFields')));
      expect(servicePipeSource, isNot(contains('QuoteWindowsCommandArgument')));
    },
  );

  test('desktop runtime config writer uses native JSON directly', () async {
    final source = await _runtimeServiceSource();
    expect(source, contains('buildJsonFor'));
    expect(
      source,
      isNot(contains("JsonEncoder.withIndent('  ').convert(config)")),
    );
  });

  test(
    'Windows split tunnel process tree expansion uses native runner',
    () async {
      final source = await _runtimeServiceSource();
      expect(source, contains('expandSplitTunnelProcessTree'));
      expect(source, isNot(contains('_findRunningDescendantAppsWithToolhelp')));
      expect(source, isNot(contains('childrenByParent')));
    },
  );

  test('Windows stale core sweep and termination use native runner', () async {
    final source = await _runtimeServiceSource();
    expect(source, contains('stopStaleCoreProcesses'));
    expect(source, contains('terminateProcessTree'));
    expect(source, isNot(contains('_snapshotWindowsProcesses')));
    expect(source, isNot(contains('_terminateWindowsProcessWithTaskkill')));
    expect(source, isNot(contains('taskkill.exe')));
    expect(source, isNot(contains('CreateToolhelp32Snapshot')));
    expect(source, isNot(contains('TerminateProcessNative')));
  });

  test('Windows TUN TCP ping bypass routes are action-scoped', () async {
    final source = await _runtimeServiceSource();

    expect(source, contains('final existingRouteKeys'));
    expect(source, contains('final pingRoutes'));
    expect(source, contains('return await action();'));
    expect(source, contains('finally {'));
    expect(
      source,
      contains('_removeTemporaryServerRoute(routes: scopedPingRoutes)'),
    );
    expect(source, contains('_forgetTemporaryServerRoutes(scopedPingRoutes)'));
  });

  test('Windows runtime start has no Dart desktop fallback', () async {
    final runtime = await File(
      'lib/services/core_runtime_service.dart',
    ).readAsString();

    final windowsBranch = runtime.substring(
      runtime.indexOf('if (Platform.isWindows)'),
    );
    expect(windowsBranch, contains('_startOnWindowsNativeRuntime'));
    expect(
      windowsBranch,
      isNot(
        contains(
          'Native Windows runtime channel is unavailable; falling back to Dart desktop runtime.',
        ),
      ),
    );
    expect(
      windowsBranch,
      isNot(contains('_isWindowsNativeRuntimeUnavailable')),
    );
  });

  test('prints Xray process startup timing smoke test', () async {
    if (!Platform.isWindows) {
      print(
        'Xray process startup timing: skipped because this is not Windows.',
      );
      return;
    }
    if (Platform.environment['ENTROPYVPN_RUN_WINDOWS_RUNTIME_SMOKE'] != '1') {
      print(
        'Xray process startup timing: skipped because native Windows runtime smoke test is opt-in.',
      );
      return;
    }

    final port = await _reserveLoopbackPort();
    final profile = ParsedVpnProfile.xrayConfig(
      server: '127.0.0.1',
      port: port,
      configJson: jsonEncode(<String, dynamic>{
        'log': <String, dynamic>{'loglevel': 'warning'},
        'inbounds': <Map<String, dynamic>>[
          <String, dynamic>{
            'tag': 'socks-in',
            'listen': '127.0.0.1',
            'port': port,
            'protocol': 'socks',
            'settings': <String, dynamic>{'udp': false},
          },
        ],
        'outbounds': <Map<String, dynamic>>[
          <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        ],
      }),
    );

    final service = CoreRuntimeService();
    final observedLogs = <String>[];
    service.onLogUpdated = () {
      final line = service.lastLogLine;
      if (line != null) {
        observedLogs.add(line);
      }
    };

    final stopwatch = Stopwatch()..start();
    try {
      await service.start(
        core: CoreFlavor.xray,
        profile: profile,
        language: AppLanguage.en,
        trafficMode: TrafficMode.systemProxy,
      );
    } finally {
      stopwatch.stop();
      await service.stop();
    }

    final timingLines = observedLogs
        .where((line) => line.contains('Startup timing:'))
        .toList(growable: false);

    print(
      'Xray process startup smoke timing: ${stopwatch.elapsedMilliseconds}ms.',
    );
    for (final line in timingLines) {
      print(line);
    }

    expect(timingLines, isNotEmpty);
  });
}

Future<String> _runtimeServiceSource() async {
  final files = <String>[
    'lib/services/core_runtime_service.dart',
    'lib/services/core_runtime_service_config_io.dart',
    'lib/services/core_runtime_service_windows.dart',
    'lib/services/core_runtime_service_windows_process.dart',
    'lib/services/core_runtime_service_windows_service.dart',
    'lib/services/core_runtime_service_windows_temporary_routes.dart',
    'lib/services/core_runtime_service_windows_types.dart',
  ];
  final chunks = await Future.wait(
    files.map((path) => File(path).readAsString()),
  );
  return chunks.join('\n');
}

Future<bool> _isRunningAsAdministrator() async {
  final result = await Process.run('fltmc.exe', const <String>[]);
  return result.exitCode == 0;
}

Future<int> _reserveLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
