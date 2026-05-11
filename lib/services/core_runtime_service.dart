import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/vpn_profile.dart';
import '../models/split_tunnel.dart';
import 'android_vpn_bridge.dart';
import 'core_config_builder.dart';
import 'geo_ip_service.dart';
import 'system_proxy_service.dart';

part 'core_runtime_service_windows.dart';
part 'core_runtime_service_windows_types.dart';

class CoreRuntimeService {
  CoreRuntimeService({
    CoreConfigBuilder? configBuilder,
    GeoIpService? geoIpService,
    SystemProxyService? systemProxyService,
  }) : _configBuilder = configBuilder ?? CoreConfigBuilder(),
       _geoIpService = geoIpService ?? GeoIpService(),
       _systemProxyService = systemProxyService ?? SystemProxyService();

  static const int _maxRecentLogs = 400;
  static const Duration _splitTunnelExpansionCacheTtl = Duration(seconds: 30);
  static const Duration _windowsProcessSnapshotCacheTtl = Duration(seconds: 2);
  static const MethodChannel _windowsTunChannel = MethodChannel(
    'entropy_vpn/windows_tun',
  );

  final CoreConfigBuilder _configBuilder;
  final GeoIpService _geoIpService;
  final SystemProxyService _systemProxyService;
  final Queue<String> _recentLogs = Queue<String>();
  final AndroidVpnBridge? _androidBridge = Platform.isAndroid
      ? AndroidVpnBridge()
      : null;

  Process? _process;
  Directory? _runtimeDirectory;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  SystemProxySnapshot? _savedProxySnapshot;
  bool? _cachedWindowsElevation;
  _SplitTunnelExpansionCacheEntry? _splitTunnelExpansionCache;
  _WindowsProcessSnapshotCacheEntry? _windowsProcessSnapshotCache;
  Future<void>? _pendingStopCleanup;
  final Set<String> _sweptWindowsTunCorePaths = <String>{};
  final Set<String> _preparedXrayTunAdapterKeys = <String>{};
  List<_WindowsHostRoute> _temporaryServerRoutes = const <_WindowsHostRoute>[];
  List<_WindowsTunRoute> _temporaryTunRoutes = const <_WindowsTunRoute>[];

  void Function(String? error)? onProcessExit;
  void Function()? onLogUpdated;

  bool get isRunning => Platform.isAndroid
      ? (_androidBridge?.isRunning ?? false)
      : _process != null;
  String? get androidPhase => Platform.isAndroid ? _androidBridge?.phase : null;
  String? get lastLogLine => Platform.isAndroid
      ? _androidBridge?.lastLogLine
      : (_recentLogs.isEmpty ? null : _recentLogs.last);
  List<String> get recentLogs => Platform.isAndroid
      ? (_androidBridge?.recentLogs ?? const <String>[])
      : List<String>.unmodifiable(_recentLogs);
  DateTime? get connectedAt =>
      Platform.isAndroid ? _androidBridge?.connectedAt : null;

  Future<void> synchronizeState() async {
    if (!Platform.isAndroid) {
      return;
    }
    _androidBridge?.onProcessExit = onProcessExit;
    _androidBridge?.onLogUpdated = onLogUpdated;
    await _androidBridge?.refreshState();
  }

  Future<T> withTcpPingBypassRoutes<T>({
    required Iterable<ParsedVpnProfile> profiles,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required Future<T> Function() action,
  }) async {
    if (!Platform.isWindows ||
        trafficMode != TrafficMode.tun ||
        _process == null) {
      return action();
    }

    final targets = profiles
        .where(
          (profile) =>
              profile.server.trim().isNotEmpty &&
              profile.port > 0 &&
              profile.port <= 65535,
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      return action();
    }

    _rememberAppLog(
      'Preparing Windows TUN TCP ping bypass routes for ${targets.length} target(s)...',
    );
    final existingRouteKeys = _temporaryServerRoutes.map(_hostRouteKey).toSet();
    final pingRoutes = <_WindowsHostRoute>[];
    final failedTargets = <String>[];
    try {
      for (final profile in targets) {
        final routing = await _prepareTunServerRouting(
          profile,
          trafficMode: trafficMode,
          tunIpMode: tunIpMode,
        );
        if (routing?.hasHostRoute == true) {
          pingRoutes.addAll(routing!.hostRoutes);
        } else {
          failedTargets.add(profile.endpointLabel);
        }
      }

      if (failedTargets.isNotEmpty) {
        _rememberAppLog(
          'Windows TUN TCP ping bypass route preparation failed for: ${failedTargets.join(', ')}.',
        );
        throw StateError(
          'TCP ping could not prepare direct Windows routes while TUN is active.',
        );
      }
      return await action();
    } finally {
      final scopedPingRoutes = pingRoutes
          .where((route) => !existingRouteKeys.contains(_hostRouteKey(route)))
          .toList(growable: false);
      if (scopedPingRoutes.isNotEmpty) {
        _rememberAppLog(
          'Removing Windows TUN TCP ping bypass routes for ${scopedPingRoutes.length} target(s)...',
        );
        await _removeTemporaryServerRoute(routes: scopedPingRoutes);
        _forgetTemporaryServerRoutes(scopedPingRoutes);
      }
    }
  }

  Future<void> saveAndroidStartPayload({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TunIpMode tunIpMode,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    final bridge = _androidBridge;
    if (bridge == null) {
      return;
    }

    final payload = _buildAndroidStartPayload(
      core: core,
      profile: profile,
      language: language,
      serverCountryCode: await _resolveAndroidServerCountryCode(profile),
      tunIpMode: tunIpMode,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
    );
    await bridge.saveStartPayload(
      core: payload.core,
      configJson: payload.configJson,
      profileName: payload.profileName,
      serverAddress: payload.serverAddress,
      serverCountryCode: payload.serverCountryCode,
      language: payload.language,
      tunIpMode: payload.tunIpMode,
      splitTunnelSettings: payload.splitTunnelSettings,
    );
  }

  Future<void> start({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TrafficMode trafficMode,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
  }) async {
    if (Platform.isAndroid) {
      await _startOnAndroid(
        core: core,
        profile: profile,
        language: language,
        tunIpMode: tunIpMode,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
      );
      return;
    }

    await stop();
    await _waitForPendingStopCleanup(reason: 'before reconnecting');
    _recentLogs.clear();
    _rememberAppLog(
      'Starting ${core.name} in ${trafficMode.name} mode for ${profile.server}:${profile.port}.',
    );
    final startupTiming = _StartupTiming()..start();
    Directory? runtimeDirectory;

    try {
      final effectiveSplitTunnelFuture = startupTiming.time(
        'split_tunnel',
        () async => trafficMode == TrafficMode.tun
            ? await _expandSplitTunnelSettings(splitTunnelSettings)
            : splitTunnelSettings.normalized,
      );
      final effectiveDomainSplitTunnelSettings = trafficMode == TrafficMode.tun
          ? domainSplitTunnelSettings.normalized
          : const DomainSplitTunnelSettings();

      if (trafficMode == TrafficMode.tun) {
        _rememberAppLog('Selected TUN IP mode: ${tunIpMode.name}.');
        _rememberAppLog(
          'Domain split tunneling: ${effectiveDomainSplitTunnelSettings.mode.name}, selected domains: ${effectiveDomainSplitTunnelSettings.domains.length}.',
        );
      }
      _rememberAppLog('Selected profile: ${_describeProfile(profile)}');

      final binaryPath = await startupTiming.time(
        'resolve_binary',
        () => _resolveBinary(core),
      );
      _rememberAppLog('Resolved core binary: $binaryPath');
      final requiresTunPrerequisites =
          (!profile.isNativeConfig && trafficMode == TrafficMode.tun) ||
          _profileConfigHasTunInbound(profile);
      if (Platform.isWindows && requiresTunPrerequisites) {
        await startupTiming.time(
          'windows_tun_prerequisites',
          () => _ensureWindowsTunPrerequisites(binaryPath),
        );
      }

      var staleCoreSweep = Future<void>.value();
      if (Platform.isWindows && requiresTunPrerequisites) {
        final sweepKey = p.normalize(binaryPath).toLowerCase();
        if (!_sweptWindowsTunCorePaths.contains(sweepKey)) {
          _sweptWindowsTunCorePaths.add(sweepKey);
          staleCoreSweep = startupTiming.time(
            'stale_core_sweep',
            () => _stopStaleWindowsTunCoreProcesses(binaryPath),
          );
        }
      }
      final tunInterfaceName = Platform.isWindows && requiresTunPrerequisites
          ? _buildWindowsTunInterfaceName()
          : null;
      if (tunInterfaceName != null) {
        _rememberAppLog('Selected TUN interface name: $tunInterfaceName.');
      }

      final tunRoutingFuture = startupTiming.time(
        'server_routing',
        () async => profile.isNativeConfig
            ? null
            : await _prepareTunServerRouting(
                profile,
                trafficMode: trafficMode,
                tunIpMode: tunIpMode,
              ),
      );
      await staleCoreSweep;
      final tunRouting = await tunRoutingFuture;
      final outboundBindInterface = tunRouting?.outboundBindInterface;
      final xrayServerAddressOverride = core == CoreFlavor.xray
          ? tunRouting?.serverAddressOverride
          : null;
      if (outboundBindInterface != null) {
        _rememberAppLog(
          'Selected outbound bind interface: $outboundBindInterface',
        );
      }
      if (xrayServerAddressOverride != null) {
        _rememberAppLog(
          'Selected Xray outbound server address: $xrayServerAddressOverride',
        );
      }
      if (trafficMode == TrafficMode.tun) {
        await startupTiming.time(
          'tun_diagnostics',
          () => _logTunDiagnostics(binaryPath),
        );
      }

      final effectiveSplitTunnelSettings = await effectiveSplitTunnelFuture;
      if (trafficMode == TrafficMode.tun) {
        _rememberAppLog(
          'Split tunneling: ${effectiveSplitTunnelSettings.mode.name}, selected apps: ${effectiveSplitTunnelSettings.apps.length}.',
        );
      }

      runtimeDirectory = await startupTiming.time(
        'runtime_directory',
        () => Directory.systemTemp.createTemp('entropy_vpn_'),
      );
      final currentRuntimeDirectory = runtimeDirectory!;

      _rememberAppLog('Runtime directory: ${currentRuntimeDirectory.path}');
      await startupTiming.time(
        'core_process_start',
        () => _startSingleCore(
          core: core,
          binaryPath: binaryPath,
          profile: profile,
          trafficMode: trafficMode,
          tunIpMode: tunIpMode,
          splitTunnelSettings: effectiveSplitTunnelSettings,
          domainSplitTunnelSettings: effectiveDomainSplitTunnelSettings,
          tunInterfaceName: tunInterfaceName,
          runtimeDirectory: currentRuntimeDirectory,
          outboundBindInterface: outboundBindInterface,
          xrayServerAddressOverride: xrayServerAddressOverride,
        ),
      );

      if (core == CoreFlavor.xray &&
          trafficMode == TrafficMode.tun &&
          tunInterfaceName != null) {
        await startupTiming.time(
          'xray_tun_adapter_routes',
          () => _installTemporaryXrayTunRoutes(
            interfaceAlias: tunInterfaceName,
            tunIpMode: tunIpMode,
          ),
        );
      }

      if (trafficMode == TrafficMode.systemProxy &&
          core == CoreFlavor.xray &&
          !profile.isNativeConfig) {
        _rememberAppLog('Capturing current Windows system proxy settings...');
        _savedProxySnapshot = await _systemProxyService.capture();
        _rememberAppLog(
          'Saved proxy snapshot: ${_describeProxySnapshot(_savedProxySnapshot!)}',
        );
        try {
          _rememberAppLog(
            'Enabling Windows system proxy on 127.0.0.1:${CoreConfigBuilder.xrayHttpPort}...',
          );
          await _systemProxyService.enableHttpProxy(
            port: CoreConfigBuilder.xrayHttpPort,
          );
          _rememberAppLog('Windows system proxy enabled.');
        } catch (error) {
          _rememberAppLog(
            'Failed to enable Windows system proxy: ${_describeError(error)}',
          );
          final process = _process;
          if (process != null) {
            await _terminateProcess(process);
          }
          await _removeTemporaryTunRoutes();
          await _removeTemporaryServerRoute();
          await _cleanupRuntimeDirectory(currentRuntimeDirectory);
          _process = null;
          _runtimeDirectory = null;
          _savedProxySnapshot = null;
          rethrow;
        }
      }

      final process = _process;
      if (process != null) {
        _attachPrimaryProcessExitHandler(process, currentRuntimeDirectory);
      }
    } catch (error) {
      _rememberAppLog('Start failed: ${_describeError(error)}');
      final process = _process;
      _process = null;
      if (process != null) {
        await _cleanupSubscriptions();
        await _terminateProcess(process);
      }
      await _removeTemporaryTunRoutes();
      await _removeTemporaryServerRoute();
      await _restoreProxyIfNeeded();
      if (runtimeDirectory != null) {
        await _cleanupRuntimeDirectory(runtimeDirectory);
      }
      rethrow;
    } finally {
      startupTiming.stop();
      _rememberAppLog('Startup timing: ${startupTiming.summary()}.');
    }
  }

  Future<void> stop({bool waitForCleanup = false}) async {
    if (Platform.isAndroid) {
      _androidBridge?.onProcessExit = onProcessExit;
      _androidBridge?.onLogUpdated = onLogUpdated;
      await _androidBridge?.stop();
      return;
    }
    if (waitForCleanup) {
      await _waitForPendingStopCleanup(reason: 'before exiting');
    }

    final process = _process;
    final runtimeDirectory = _runtimeDirectory;
    final tunRoutes = _temporaryTunRoutes;
    final serverRoutes = _temporaryServerRoutes;
    final proxySnapshot = _savedProxySnapshot;

    _process = null;
    _runtimeDirectory = null;
    _temporaryTunRoutes = const <_WindowsTunRoute>[];
    _temporaryServerRoutes = const <_WindowsHostRoute>[];
    _savedProxySnapshot = null;
    final stopTiming = _StartupTiming()..start();

    try {
      if (process != null) {
        await stopTiming.time('core_process_stop', () async {
          _rememberAppLog('Stopping core process...');
          await _terminateProcess(process);
          _rememberAppLog('Core process stopped.');
        });
      }

      await stopTiming.time(
        'cleanup_subscriptions',
        () => _cleanupSubscriptions(),
      );

      final cleanup = _scheduleStopCleanup(
        tunRoutes: tunRoutes,
        serverRoutes: serverRoutes,
        proxySnapshot: proxySnapshot,
        runtimeDirectory: runtimeDirectory,
      );
      if (waitForCleanup) {
        await cleanup;
      }
    } finally {
      stopTiming.stop();
      _rememberAppLog('Stop timing: ${stopTiming.summary()}.');
    }
  }

  Future<void> _waitForPendingStopCleanup({required String reason}) async {
    final cleanup = _pendingStopCleanup;
    if (cleanup == null) {
      return;
    }

    _rememberAppLog('Waiting for previous stop cleanup $reason...');
    await cleanup;
  }

  Future<void> _scheduleStopCleanup({
    required List<_WindowsTunRoute> tunRoutes,
    required List<_WindowsHostRoute> serverRoutes,
    required SystemProxySnapshot? proxySnapshot,
    required Directory? runtimeDirectory,
  }) {
    if (tunRoutes.isEmpty &&
        serverRoutes.isEmpty &&
        proxySnapshot == null &&
        runtimeDirectory == null) {
      return Future<void>.value();
    }

    late final Future<void> cleanup;
    cleanup =
        _runStopCleanup(
          tunRoutes: tunRoutes,
          serverRoutes: serverRoutes,
          proxySnapshot: proxySnapshot,
          runtimeDirectory: runtimeDirectory,
        ).whenComplete(() {
          if (identical(_pendingStopCleanup, cleanup)) {
            _pendingStopCleanup = null;
          }
        });
    _pendingStopCleanup = cleanup;
    unawaited(cleanup);
    return cleanup;
  }

  Future<void> _runStopCleanup({
    required List<_WindowsTunRoute> tunRoutes,
    required List<_WindowsHostRoute> serverRoutes,
    required SystemProxySnapshot? proxySnapshot,
    required Directory? runtimeDirectory,
  }) async {
    final cleanupTiming = _StartupTiming()..start();
    try {
      await cleanupTiming.time('cleanup_windows_state', () async {
        await Future.wait(<Future<void>>[
          _removeTemporaryTunRoutes(routes: tunRoutes),
          _removeTemporaryServerRoute(routes: serverRoutes),
          _restoreProxySnapshot(proxySnapshot),
        ]);
      });

      if (runtimeDirectory != null) {
        await cleanupTiming.time(
          'cleanup_runtime_directory',
          () => _cleanupRuntimeDirectory(runtimeDirectory),
        );
      }
    } catch (error) {
      _rememberAppLog('Stop cleanup failed: ${_describeError(error)}');
    } finally {
      cleanupTiming.stop();
      _rememberAppLog('Stop cleanup timing: ${cleanupTiming.summary()}.');
    }
  }

  Future<void> _startOnAndroid({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TunIpMode tunIpMode,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) async {
    final bridge = _androidBridge;
    if (bridge == null) {
      throw StateError('Android VPN bridge is unavailable.');
    }

    bridge.onProcessExit = onProcessExit;
    bridge.onLogUpdated = onLogUpdated;

    final payload = _buildAndroidStartPayload(
      core: core,
      profile: profile,
      language: language,
      serverCountryCode: await _resolveAndroidServerCountryCode(profile),
      tunIpMode: tunIpMode,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
    );
    await bridge.start(
      core: payload.core,
      configJson: payload.configJson,
      profileName: payload.profileName,
      serverAddress: payload.serverAddress,
      serverCountryCode: payload.serverCountryCode,
      language: payload.language,
      tunIpMode: payload.tunIpMode,
      splitTunnelSettings: payload.splitTunnelSettings,
    );
  }

  _AndroidStartPayload _buildAndroidStartPayload({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required String? serverCountryCode,
    required TunIpMode tunIpMode,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) {
    if (profile.isSingBoxConfig) {
      final config = _buildNativeSingBoxRuntimeConfig(
        profile: profile,
        tunIpMode: tunIpMode,
      );
      return _AndroidStartPayload(
        core: CoreFlavor.singBox.name,
        configJson: const JsonEncoder.withIndent('  ').convert(config),
        profileName: profile.remark ?? profile.endpointLabel,
        serverAddress: profile.server,
        serverCountryCode: serverCountryCode,
        language: language,
        tunIpMode: tunIpMode,
        splitTunnelSettings: splitTunnelSettings.normalized,
      );
    }
    if (profile.isXrayConfig) {
      final config = _buildNativeXrayRuntimeConfig(profile: profile);
      return _AndroidStartPayload(
        core: CoreFlavor.xray.name,
        configJson: const JsonEncoder.withIndent('  ').convert(config),
        profileName: profile.remark ?? profile.endpointLabel,
        serverAddress: profile.server,
        serverCountryCode: serverCountryCode,
        language: language,
        tunIpMode: tunIpMode,
        splitTunnelSettings: splitTunnelSettings.normalized,
      );
    }

    final effectiveTrafficMode = core == CoreFlavor.singBox
        ? TrafficMode.tun
        : TrafficMode.systemProxy;
    final config = _configBuilder.buildFor(
      core,
      profile,
      trafficMode: effectiveTrafficMode,
      tunIpMode: tunIpMode,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
    );
    return _AndroidStartPayload(
      core: core.name,
      configJson: const JsonEncoder.withIndent('  ').convert(config),
      profileName: profile.remark ?? profile.endpointLabel,
      serverAddress: profile.server,
      serverCountryCode: serverCountryCode,
      language: language,
      tunIpMode: tunIpMode,
      splitTunnelSettings: splitTunnelSettings.normalized,
    );
  }

  Future<String?> _resolveAndroidServerCountryCode(
    ParsedVpnProfile profile,
  ) async {
    final server = profile.server.trim();
    if (server.isEmpty) {
      return null;
    }
    try {
      final info = await _geoIpService.resolveServer(server);
      return _normalizeCountryCode(info?.countryCode);
    } catch (_) {
      return null;
    }
  }

  String? _normalizeCountryCode(String? countryCode) {
    final normalized = countryCode?.trim().toUpperCase();
    if (normalized == null || normalized.length != 2) {
      return null;
    }
    final units = normalized.codeUnits;
    if (units.any((unit) => unit < 65 || unit > 90)) {
      return null;
    }
    return normalized;
  }

  Future<void> _startSingleCore({
    required CoreFlavor core,
    required String binaryPath,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
    String? tunInterfaceName,
    required Directory runtimeDirectory,
    String? outboundBindInterface,
    String? xrayServerAddressOverride,
  }) async {
    final configFile = File(p.join(runtimeDirectory.path, 'config.json'));
    final config = _buildRuntimeConfig(
      core: core,
      profile: profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface: outboundBindInterface,
      xrayServerAddressOverride: xrayServerAddressOverride,
    );
    final configJson = const JsonEncoder.withIndent('  ').convert(config);
    final workingDirectory =
        _resolveConfigWorkingDirectory(profile) ?? runtimeDirectory.path;
    _rememberAppLog('Runtime config path: ${configFile.path}');
    _rememberAppLog('Core working directory: $workingDirectory');
    _rememberAppLog('Runtime config summary: ${_describeConfig(config)}');
    _rememberAppLog(
      'Writing runtime config (${utf8.encode(configJson).length} bytes)...',
    );
    await configFile.writeAsString(configJson);
    final shouldSkipValidation = _shouldSkipRuntimeValidation(core, config);
    if (shouldSkipValidation) {
      _rememberAppLog(
        'Skipping runtime config validation because xray run -test initializes the Windows TUN driver.',
      );
    } else {
      _rememberAppLog('Validating runtime config...');
      await _validateConfig(
        core,
        binaryPath,
        configFile.path,
        workingDirectory: workingDirectory,
      );
      _rememberAppLog('Config validation passed.');
    }

    final args = <String>['run', '-c', configFile.path];
    _rememberAppLog(
      'Starting core process: ${_formatCommand(binaryPath, args)}',
    );
    final process = await _startTimedProcess(
      '${core.name}_core_start',
      binaryPath,
      args,
      workingDirectory: workingDirectory,
    );

    _process = process;
    _runtimeDirectory = runtimeDirectory;
    _stdoutSubscription = _listenTo(process.stdout);
    _stderrSubscription = _listenTo(process.stderr, isError: true);
    _rememberAppLog('Core process started with PID ${process.pid}.');
  }

  Map<String, dynamic> _buildRuntimeConfig({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? xrayServerAddressOverride,
  }) {
    if (profile.isSingBoxConfig) {
      if (core != CoreFlavor.singBox) {
        throw StateError('Native sing-box configs must be run with sing-box.');
      }
      final decoded = _buildNativeSingBoxRuntimeConfig(
        profile: profile,
        tunIpMode: tunIpMode,
        tunInterfaceName: tunInterfaceName,
      );
      if (splitTunnelSettings.isEnabled ||
          domainSplitTunnelSettings.isEnabled) {
        _rememberAppLog(
          'Native sing-box JSON profile is used as-is; split tunneling is only injected into generated TUN configs.',
        );
      }
      return decoded;
    }
    if (profile.isXrayConfig) {
      if (core != CoreFlavor.xray) {
        throw StateError('Native Xray configs must be run with Xray.');
      }
      final decoded = _buildNativeXrayRuntimeConfig(profile: profile);
      if (splitTunnelSettings.isEnabled ||
          domainSplitTunnelSettings.isEnabled) {
        _rememberAppLog(
          'Native Xray JSON profile is used as-is; split tunneling is only injected into generated TUN configs.',
        );
      }
      return decoded;
    }

    return _configBuilder.buildFor(
      core,
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface:
          core == CoreFlavor.xray || trafficMode != TrafficMode.tun
          ? outboundBindInterface
          : null,
      routeDefaultInterface:
          core == CoreFlavor.singBox && trafficMode == TrafficMode.tun
          ? outboundBindInterface
          : null,
      xrayServerAddressOverride: xrayServerAddressOverride,
    );
  }

  Map<String, dynamic> _buildNativeSingBoxRuntimeConfig({
    required ParsedVpnProfile profile,
    required TunIpMode tunIpMode,
    String? tunInterfaceName,
  }) {
    final decoded = jsonDecode(profile.singBoxConfigJson!);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Native sing-box config must be a JSON object.');
    }
    final appliedTunSettings = _configBuilder.applyNativeSingBoxTunSettings(
      decoded,
      tunIpMode: tunIpMode,
      tunInterfaceName: Platform.isWindows ? tunInterfaceName : null,
      mtu: Platform.isAndroid ? CoreConfigBuilder.tunMtu : null,
      androidCompatibility: Platform.isAndroid,
    );
    if (appliedTunSettings && !Platform.isAndroid) {
      _rememberAppLog(
        'Applied ${tunIpMode.name} TUN IP mode to native sing-box config.',
      );
    }
    return decoded;
  }

  Map<String, dynamic> _buildNativeXrayRuntimeConfig({
    required ParsedVpnProfile profile,
  }) {
    final decoded = jsonDecode(profile.xrayConfigJson!);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Native Xray config must be a JSON object.');
    }
    return decoded;
  }

  String? _resolveConfigWorkingDirectory(ParsedVpnProfile profile) {
    final configDirectory =
        profile.singBoxConfigDirectory?.trim() ??
        profile.xrayConfigDirectory?.trim();
    if (configDirectory == null || configDirectory.isEmpty) {
      return null;
    }
    if (!Directory(configDirectory).existsSync()) {
      _rememberAppLog(
        'Configured core working directory does not exist: $configDirectory',
      );
      return null;
    }
    return configDirectory;
  }

  bool _profileConfigHasTunInbound(ParsedVpnProfile profile) {
    if (!profile.isNativeConfig) {
      return false;
    }

    try {
      final decoded = jsonDecode(
        profile.singBoxConfigJson ?? profile.xrayConfigJson!,
      );
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      final inbounds = decoded['inbounds'];
      if (inbounds is! List) {
        return false;
      }
      return inbounds.any((item) {
        if (item is! Map) {
          return false;
        }
        final field = profile.isSingBoxConfig ? 'type' : 'protocol';
        return item[field]?.toString().trim().toLowerCase() == 'tun';
      });
    } catch (_) {
      return false;
    }
  }

  bool _shouldSkipRuntimeValidation(
    CoreFlavor core,
    Map<String, dynamic> config,
  ) {
    return Platform.isWindows &&
        core == CoreFlavor.xray &&
        _configHasXrayTunInbound(config);
  }

  bool _configHasXrayTunInbound(Map<String, dynamic> config) {
    final inbounds = config['inbounds'];
    if (inbounds is! List) {
      return false;
    }
    return inbounds.any((item) {
      if (item is! Map) {
        return false;
      }
      return item['protocol']?.toString().trim().toLowerCase() == 'tun';
    });
  }

  void _attachPrimaryProcessExitHandler(
    Process process,
    Directory runtimeDirectory,
  ) {
    unawaited(
      process.exitCode.then((exitCode) async {
        if (!identical(_process, process)) {
          return;
        }
        final error = _buildUnexpectedExitMessage(exitCode);
        _rememberAppLog('Core process exited with code $exitCode.');
        _process = null;
        await _removeTemporaryTunRoutes();
        await _removeTemporaryServerRoute();
        await _restoreProxyIfNeeded();
        await _cleanupSubscriptions();
        await _cleanupRuntimeDirectory(runtimeDirectory);
        _runtimeDirectory = null;
        onProcessExit?.call(error);
      }),
    );
  }

  void dispose() {
    unawaited(_androidBridge?.dispose() ?? Future<void>.value());
    if (!Platform.isAndroid) {
      unawaited(stop());
    }
  }

  Future<String> _resolveBinary(CoreFlavor core) async {
    final fileName = switch (core) {
      CoreFlavor.xray => 'xray.exe',
      CoreFlavor.singBox => 'sing-box.exe',
    };

    final candidates = <String>{};
    for (final root in _candidateRoots()) {
      candidates.add(p.join(root, 'tools', 'cores', fileName));
      candidates.add(p.join(root, 'cores', fileName));
    }

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    ProcessResult? pathLookup;
    try {
      pathLookup = await _runTimedProcess(
        'where:$fileName',
        'where.exe',
        <String>[fileName],
      );
    } on ProcessException {
      pathLookup = null;
    }

    if (pathLookup != null && pathLookup.exitCode == 0) {
      final resolved = pathLookup.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      if (resolved.isNotEmpty) {
        return resolved;
      }
    }

    throw StateError(
      'Binary $fileName was not found. Expected in tools/cores or next to the built application.',
    );
  }

  Iterable<String> _candidateRoots() sync* {
    final seen = <String>{};

    for (final start in <String>[
      Directory.current.path,
      File(Platform.resolvedExecutable).parent.path,
    ]) {
      var current = p.normalize(start);
      while (seen.add(current)) {
        yield current;
        final parent = p.dirname(current);
        if (parent == current) {
          break;
        }
        current = parent;
      }
    }
  }

  Future<void> _validateConfig(
    CoreFlavor core,
    String binaryPath,
    String configPath, {
    String? workingDirectory,
  }) async {
    final args = switch (core) {
      CoreFlavor.xray => <String>['run', '-test', '-c', configPath],
      CoreFlavor.singBox => <String>['check', '-c', configPath],
    };

    _rememberAppLog('Validation command: ${_formatCommand(binaryPath, args)}');
    final result = await _runTimedProcess(
      '${core.name}_config_validation',
      binaryPath,
      args,
      workingDirectory: workingDirectory,
    );
    _rememberProcessOutput('[check][stdout] ', result.stdout.toString());
    _rememberProcessOutput('[check][stderr] ', result.stderr.toString());
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      final stdout = result.stdout.toString().trim();
      final message = stderr.isNotEmpty ? stderr : stdout;
      _rememberAppLog(
        'Runtime config validation failed with exit code ${result.exitCode}.',
      );
      throw StateError(
        message.isEmpty ? 'Core configuration validation failed.' : message,
      );
    }
  }

  StreamSubscription<String> _listenTo(
    Stream<List<int>> stream, {
    bool isError = false,
    String? sourceLabel,
  }) {
    return stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final prefix = sourceLabel == null ? '' : '[$sourceLabel] ';
          _rememberLog(isError ? 'ERR: $prefix$line' : '$prefix$line');
        });
  }

  void _rememberLog(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    _recentLogs.add(line.trim());
    while (_recentLogs.length > _maxRecentLogs) {
      _recentLogs.removeFirst();
    }
    onLogUpdated?.call();
  }

  void _rememberAppLog(String line) {
    _rememberLog('[app] $line');
  }

  void _rememberProcessOutput(String prefix, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    for (final line in const LineSplitter().convert(trimmed)) {
      _rememberLog('$prefix$line');
    }
  }

  Future<void> _cleanupSubscriptions() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
  }

  Future<void> _restoreProxyIfNeeded() async {
    final snapshot = _savedProxySnapshot;
    _savedProxySnapshot = null;
    await _restoreProxySnapshot(snapshot);
  }

  Future<void> _restoreProxySnapshot(SystemProxySnapshot? snapshot) async {
    if (snapshot == null) {
      return;
    }
    _rememberAppLog(
      'Restoring Windows system proxy: ${_describeProxySnapshot(snapshot)}',
    );
    await _systemProxyService.restore(snapshot);
    _rememberAppLog('Windows system proxy restored.');
  }

  Future<void> _terminateProcess(Process process) async {
    _rememberAppLog('Sending termination signal to PID ${process.pid}...');
    if (Platform.isWindows) {
      await _terminateWindowsProcess(process);
      return;
    }

    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _rememberAppLog(
        'Process PID ${process.pid} did not exit in time, forcing termination.',
      );
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  Future<void> _terminateWindowsProcess(Process process) async {
    var usedTaskkillFallback = false;
    try {
      final terminatedNatively = _terminateWindowsProcessByPid(
        process.pid,
        timingLabel: 'native_terminate:${process.pid}',
      );
      if (!terminatedNatively && !await _hasProcessExited(process)) {
        _rememberAppLog(
          'Native termination failed for PID ${process.pid}; falling back to taskkill.',
        );
        usedTaskkillFallback = true;
        await _terminateWindowsProcessWithTaskkill(process);
      }
    } catch (error) {
      _rememberAppLog(
        'Native termination failed for PID ${process.pid}: ${_describeError(error)}',
      );
      if (!await _hasProcessExited(process)) {
        usedTaskkillFallback = true;
        await _terminateWindowsProcessWithTaskkill(process);
      }
    }

    if (!await _hasProcessExited(process)) {
      process.kill(ProcessSignal.sigkill);
    }

    try {
      await process.exitCode.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      final method = usedTaskkillFallback ? 'native/taskkill' : 'native';
      _rememberAppLog(
        'Process PID ${process.pid} still did not report exit after $method termination.',
      );
    }
  }

  Future<void> _terminateWindowsProcessWithTaskkill(Process process) async {
    try {
      final result = await _runTimedProcess(
        'taskkill:${process.pid}',
        'taskkill.exe',
        <String>['/PID', process.pid.toString(), '/T', '/F'],
        timeout: const Duration(seconds: 2),
      );
      if (result.exitCode != 0 && !await _hasProcessExited(process)) {
        _rememberAppLog(
          'taskkill failed for PID ${process.pid}: ${_describeError(result.stderr)}',
        );
      }
    } catch (error) {
      _rememberAppLog(
        'taskkill failed for PID ${process.pid}: ${_describeError(error)}',
      );
    }
  }

  Future<bool> _hasProcessExited(Process process) async {
    try {
      await process.exitCode.timeout(Duration.zero);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _cleanupRuntimeDirectory(Directory directory) async {
    if (!directory.existsSync()) {
      return;
    }
    _rememberAppLog('Removing runtime directory ${directory.path}...');
    await directory.delete(recursive: true);
    _rememberAppLog('Runtime directory removed.');
  }

  Future<void> _logTunDiagnostics(String binaryPath) async {
    _rememberAppLog(
      'TUN diagnostics: platform=${Platform.operatingSystem}, os=${Platform.operatingSystemVersion}.',
    );

    if (Platform.isWindows) {
      final elevated = await _isRunningAsAdministrator();
      _rememberAppLog(
        'TUN diagnostics: elevated=${_describeNullableBool(elevated)}.',
      );
      if (elevated == false) {
        _rememberAppLog(
          'TUN prerequisite warning: Windows TUN mode usually requires Administrator rights.',
        );
      }
    }

    final wintunPath = p.join(p.dirname(binaryPath), 'wintun.dll');
    _rememberAppLog(
      'TUN diagnostics: sibling wintun.dll present=${File(wintunPath).existsSync()} at $wintunPath.',
    );
  }

  String _describeProfile(ParsedVpnProfile profile) {
    if (profile.isSingBoxConfig) {
      return <String>[
        'kind=sing-box-config',
        'name=${_orDash(profile.remark)}',
        'endpoint=${profile.endpointLabel}',
        'config_dir=${_orDash(profile.singBoxConfigDirectory)}',
      ].join(', ');
    }
    if (profile.isXrayConfig) {
      return <String>[
        'kind=xray-config',
        'name=${_orDash(profile.remark)}',
        'endpoint=${profile.endpointLabel}',
        'config_dir=${_orDash(profile.xrayConfigDirectory)}',
      ].join(', ');
    }

    final fields = <String>[
      'protocol=${profile.protocol.name}',
      'endpoint=${profile.server}:${profile.port}',
      'transport=${profile.transport.name}',
      'tls=${profile.tlsMode.name}',
      'remark=${_orDash(profile.remark)}',
      'plugin=${_orDash(profile.plugin)}',
    ];

    if (profile.host?.trim().isNotEmpty == true) {
      fields.add('host=${profile.host!.trim()}');
    }
    if (profile.path?.trim().isNotEmpty == true) {
      fields.add('path=${profile.path!.trim()}');
    }
    if (profile.serviceName?.trim().isNotEmpty == true) {
      fields.add('service=${profile.serviceName!.trim()}');
    }
    if (profile.sni?.trim().isNotEmpty == true) {
      fields.add('sni=${profile.sni!.trim()}');
    }

    return fields.join(', ');
  }

  String _describeConfig(Map<String, dynamic> config) {
    final inbounds = config['inbounds'] as List<dynamic>? ?? const <dynamic>[];
    final outboundList =
        config['outbounds'] as List<dynamic>? ?? const <dynamic>[];
    final inbound = inbounds.isEmpty
        ? const <String, dynamic>{}
        : (inbounds.first as Map).cast<String, dynamic>();
    final outbound = outboundList.isEmpty
        ? const <String, dynamic>{}
        : (outboundList.first as Map).cast<String, dynamic>();
    final route = (config['route'] as Map?)?.cast<String, dynamic>();
    final dns = (config['dns'] as Map?)?.cast<String, dynamic>();
    final inboundKind =
        inbound['type']?.toString() ?? inbound['protocol']?.toString();
    final outboundServer = _describeConfigOutboundServer(outbound);

    final fields = <String>[
      'inbound=${_orDash(inboundKind)}',
      'outbound=${_orDash(outbound['type']?.toString() ?? outbound['protocol']?.toString())}',
      'server=$outboundServer',
      'route.final=${_orDash(route?['final']?.toString())}',
    ];

    if (inboundKind == 'tun') {
      final xraySettings = (inbound['settings'] as Map?)
          ?.cast<String, dynamic>();
      fields.add(
        'interface=${_orDash(inbound['interface_name']?.toString() ?? xraySettings?['name']?.toString())}',
      );
      fields.add(
        'mtu=${_orDash(inbound['mtu']?.toString() ?? xraySettings?['MTU']?.toString() ?? xraySettings?['mtu']?.toString())}',
      );
      fields.add(
        'address=${_orDash((inbound['address'] as List?)?.join('|') ?? (xraySettings?['gateway'] as List?)?.join('|'))}',
      );
      fields.add('auto_route=${_orDash(inbound['auto_route']?.toString())}');
      fields.add('stack=${_orDash(inbound['stack']?.toString())}');
      fields.add(
        'strict_route=${_orDash(inbound['strict_route']?.toString())}',
      );
      fields.add(
        'dns.final=${_orDash(dns?['final']?.toString() ?? (xraySettings?['dns'] as List?)?.join('|'))}',
      );
    } else {
      fields.add('listen=${_orDash(inbound['listen']?.toString())}');
      fields.add('listen_port=${_orDash(inbound['listen_port']?.toString())}');
      fields.add(
        'set_system_proxy=${_orDash(inbound['set_system_proxy']?.toString())}',
      );
    }

    if (outbound['transport'] is Map<String, dynamic>) {
      final transport = outbound['transport'] as Map<String, dynamic>;
      fields.add('transport=${_orDash(transport['type']?.toString())}');
    }
    if (outbound['streamSettings'] is Map<String, dynamic>) {
      final streamSettings = outbound['streamSettings'] as Map<String, dynamic>;
      fields.add('network=${_orDash(streamSettings['network']?.toString())}');
      final sockopt = (streamSettings['sockopt'] as Map?)
          ?.cast<String, dynamic>();
      if (sockopt?['interface'] != null) {
        fields.add(
          'bind_interface=${_orDash(sockopt?['interface']?.toString())}',
        );
      }
    }
    if (outbound['bind_interface'] != null) {
      fields.add(
        'bind_interface=${_orDash(outbound['bind_interface']?.toString())}',
      );
    }
    if (outbound['tls'] is Map<String, dynamic>) {
      final tls = outbound['tls'] as Map<String, dynamic>;
      final tlsMode = tls['reality'] is Map<String, dynamic>
          ? 'reality'
          : 'tls';
      fields.add('tls_mode=$tlsMode');
    }

    return fields.join(', ');
  }

  String _describeConfigOutboundServer(Map<String, dynamic> outbound) {
    final directServer = outbound['server']?.toString();
    final directPort = outbound['server_port']?.toString();
    if (directServer != null || directPort != null) {
      return '${_orDash(directServer)}:${_orDash(directPort)}';
    }

    final settings = (outbound['settings'] as Map?)?.cast<String, dynamic>();
    final vnext = settings?['vnext'];
    if (vnext is List && vnext.isNotEmpty && vnext.first is Map) {
      final server = (vnext.first as Map)['address']?.toString();
      final port = (vnext.first as Map)['port']?.toString();
      return '${_orDash(server)}:${_orDash(port)}';
    }

    final servers = settings?['servers'];
    if (servers is List && servers.isNotEmpty && servers.first is Map) {
      final server = (servers.first as Map)['address']?.toString();
      final port = (servers.first as Map)['port']?.toString();
      return '${_orDash(server)}:${_orDash(port)}';
    }

    return '-:-';
  }

  String _describeProxySnapshot(SystemProxySnapshot snapshot) {
    return 'enabled=${snapshot.enabled}, server=${_orDash(snapshot.server)}, override=${_orDash(snapshot.override)}';
  }

  String _buildUnexpectedExitMessage(int exitCode) {
    final diagnostic = _findLastDiagnosticLog();
    if (diagnostic == null) {
      return 'Core process exited with code $exitCode.';
    }
    return 'Core process exited with code $exitCode.\n$diagnostic';
  }

  String? _findLastDiagnosticLog() {
    for (final line in _recentLogs.toList().reversed) {
      if (line.startsWith('[app] Core process exited with code ')) {
        continue;
      }
      if (line.startsWith('[app]')) {
        if (line.contains('Start failed:') ||
            line.contains('validation failed') ||
            line.contains('prerequisite warning')) {
          return line;
        }
        continue;
      }
      if (line.startsWith('ERR:')) {
        return line;
      }
      if (_looksLikeFailure(line)) {
        return line;
      }
    }
    return null;
  }

  bool _looksLikeFailure(String line) {
    final lowered = line.toLowerCase();
    return lowered.contains('error') ||
        lowered.contains('fatal') ||
        lowered.contains('fail') ||
        lowered.contains('denied') ||
        lowered.contains('permission');
  }

  String _formatCommand(String executable, List<String> args) {
    return ([executable, ...args]).map(_quoteIfNeeded).join(' ');
  }

  Future<ProcessResult> _runPowerShellScript(
    String script, {
    String label = 'script',
    Map<String, String> namedArgs = const <String, String>{},
  }) {
    return _runTimedProcess('powershell:$label', 'powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      _buildPowerShellInvocation(script, namedArgs: namedArgs),
    ]);
  }

  Future<ProcessResult> _runTimedProcess(
    String label,
    String executable,
    List<String> args, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final run = Process.run(
        executable,
        args,
        workingDirectory: workingDirectory,
      );
      final result = await (timeout == null ? run : run.timeout(timeout));
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms exit=${result.exitCode}.',
      );
      return result;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      rethrow;
    }
  }

  Future<Process> _startTimedProcess(
    String label,
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final process = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
      );
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms pid=${process.pid}.',
      );
      return process;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      rethrow;
    }
  }

  String _buildPowerShellInvocation(
    String script, {
    Map<String, String> namedArgs = const <String, String>{},
  }) {
    final buffer = StringBuffer('& {\n');
    buffer.write(script.trim());
    buffer.write('\n}');
    namedArgs.forEach((key, value) {
      buffer.write(' -');
      buffer.write(key);
      buffer.write(' ');
      buffer.write(_quotePowerShellLiteral(value));
    });
    return buffer.toString();
  }

  String _quoteIfNeeded(String value) {
    return value.contains(' ') ? '"$value"' : value;
  }

  String _quotePowerShellLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  String _describeNullableBool(bool? value) {
    if (value == null) {
      return 'unknown';
    }
    return value ? 'true' : 'false';
  }

  String _orDash(String? value) {
    if (value == null) {
      return '-';
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? '-' : trimmed;
  }

  String _describeError(Object error) {
    final text = error.toString().trim();
    return text.isEmpty ? error.runtimeType.toString() : text;
  }
}

class _StartupTiming {
  final Stopwatch _total = Stopwatch();
  final List<_StartupTimingEntry> _entries = <_StartupTimingEntry>[];

  void start() {
    _total.start();
  }

  void stop() {
    _total.stop();
  }

  Future<T> time<T>(String label, FutureOr<T> Function() action) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      stopwatch.stop();
      _entries.add(_StartupTimingEntry(label, stopwatch.elapsed));
    }
  }

  String summary() {
    final fields = <String>['total=${_format(_total.elapsed)}'];
    for (final entry in _entries) {
      fields.add('${entry.label}=${_format(entry.elapsed)}');
    }
    return fields.join(', ');
  }

  String _format(Duration duration) {
    return '${duration.inMilliseconds}ms';
  }
}

class _StartupTimingEntry {
  const _StartupTimingEntry(this.label, this.elapsed);

  final String label;
  final Duration elapsed;
}

class _AndroidStartPayload {
  const _AndroidStartPayload({
    required this.core,
    required this.configJson,
    required this.profileName,
    required this.serverAddress,
    required this.serverCountryCode,
    required this.language,
    required this.tunIpMode,
    required this.splitTunnelSettings,
  });

  final String core;
  final String configJson;
  final String profileName;
  final String serverAddress;
  final String? serverCountryCode;
  final AppLanguage language;
  final TunIpMode tunIpMode;
  final SplitTunnelSettings splitTunnelSettings;
}

class _SplitTunnelExpansionCacheEntry {
  const _SplitTunnelExpansionCacheEntry({
    required this.key,
    required this.settings,
    required this.createdAt,
    required this.addedAppCount,
  });

  final String key;
  final SplitTunnelSettings settings;
  final DateTime createdAt;
  final int addedAppCount;
}
