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
    'Windows Xray TUN setup JSON serialization works on PowerShell 5',
    () async {
      final source = await _runtimeServiceSource();
      expect(source, contains(r'Routes = $routeResults.ToArray()'));
      expect(source, isNot(contains(r'Routes = @($routeResults)')));

      if (!Platform.isWindows) {
        print(
          'Xray TUN PowerShell serialization: skipped because this is not Windows.',
        );
        return;
      }

      const script = r'''
$changes = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$routeResults = New-Object System.Collections.Generic.List[object]
$timings = New-Object System.Collections.Generic.List[string]
$changes.Add('ipv6-binding=enabled')
$warnings.Add('Route 0.0.0.0/1: Access is denied.')
$routeResults.Add([PSCustomObject]@{
  DestinationPrefix = '0.0.0.0/1'
  NextHop = '0.0.0.0'
  Status = 'failed'
})
$timings.Add('wait_adapter=0ms')
[PSCustomObject]@{
  Changes = $changes.ToArray()
  Warnings = $warnings.ToArray()
  Routes = $routeResults.ToArray()
  Timings = $timings.ToArray()
} | ConvertTo-Json -Depth 4 -Compress
''';

      final result = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(
        result.stderr.toString(),
        isNot(contains('Argument types do not match')),
      );
      final decoded = jsonDecode(result.stdout.toString().trim());
      expect(decoded, isA<Map<String, dynamic>>());
      final routes =
          (decoded as Map<String, dynamic>)['Routes'] as List<dynamic>;
      expect((routes.first as Map<String, dynamic>)['Status'], 'failed');
    },
  );

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

  test('prints Xray process startup timing smoke test', () async {
    if (!Platform.isWindows) {
      print(
        'Xray process startup timing: skipped because this is not Windows.',
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
    'lib/services/core_runtime_service_windows.dart',
    'lib/services/core_runtime_service_windows_types.dart',
  ];
  final chunks = await Future.wait(
    files.map((path) => File(path).readAsString()),
  );
  return chunks.join('\n');
}

Future<bool> _isRunningAsAdministrator() async {
  final result = await Process.run('powershell.exe', <String>[
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    r'''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
[Console]::Out.Write($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
''',
  ]);
  return result.exitCode == 0 &&
      result.stdout.toString().trim().toLowerCase() == 'true';
}

Future<int> _reserveLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
