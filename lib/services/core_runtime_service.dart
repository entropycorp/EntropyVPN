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
    final failedTargets = <String>[];
    for (final profile in targets) {
      final routing = await _prepareTunServerRouting(
        profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
      );
      if (routing?.hasHostRoute != true) {
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
    return action();
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

  Future<void> _ensureWindowsTunPrerequisites(String binaryPath) async {
    if (!Platform.isWindows) {
      return;
    }

    final wintunPath = p.join(p.dirname(binaryPath), 'wintun.dll');
    if (!File(wintunPath).existsSync()) {
      final executableName = p.basename(binaryPath);
      throw StateError(
        'wintun.dll was not found next to $executableName. Windows TUN mode requires wintun.dll in ${p.dirname(binaryPath)}.',
      );
    }

    if (!await ensureWindowsTunPrivileges()) {
      throw StateError(
        'Administrator privileges are required for Windows TUN mode.',
      );
    }
  }

  Future<bool> ensureWindowsTunPrivileges() async {
    if (!Platform.isWindows) {
      return true;
    }

    final elevated = await _isRunningAsAdministrator();
    if (elevated == false) {
      _rememberAppLog(
        'Windows TUN mode requires Administrator privileges; relaunching EntropyVPN elevated...',
      );
      final relaunched = await _relaunchAsAdministrator();
      if (relaunched) {
        _rememberAppLog(
          'Elevated instance was launched. Exiting unelevated instance.',
        );
        exit(0);
      }
      return false;
    }

    if (elevated == null) {
      _rememberAppLog(
        'Could not determine whether EntropyVPN is elevated; continuing and letting the core report any permission error.',
      );
    }

    return true;
  }

  Future<void> _stopStaleWindowsTunCoreProcesses(String binaryPath) async {
    if (!Platform.isWindows) {
      return;
    }

    if (_stopStaleWindowsTunCoreProcessesWithToolhelp(binaryPath)) {
      return;
    }

    const script = r'''
param(
  [string]$ExecutablePath,
  [string]$ExecutableName,
  [int]$CurrentProcessId
)
try {
  $targetPath = [System.IO.Path]::GetFullPath($ExecutablePath)
  $processes = Get-CimInstance Win32_Process -Filter "Name = '$ExecutableName'" |
    Where-Object {
      $_.ProcessId -ne $CurrentProcessId -and
      -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
      [System.IO.Path]::GetFullPath([string]$_.ExecutablePath) -ieq $targetPath
    }

  $stopped = foreach ($process in $processes) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    [string]$process.ProcessId
  }

  if ($stopped) {
    [Console]::Out.Write(($stopped -join ','))
  }
} catch {
  Write-Error -Message ([string]$_.Exception.Message)
  exit 1
}
''';

    try {
      final executableName = p.basename(binaryPath);
      final result = await _runPowerShellScript(
        script,
        label: 'stale_core_sweep',
        namedArgs: <String, String>{
          'ExecutablePath': binaryPath,
          'ExecutableName': executableName,
          'CurrentProcessId': pid.toString(),
        },
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to stop stale $executableName processes before TUN start: ${_describeError(result.stderr)}',
        );
        return;
      }

      final stoppedPids = result.stdout.toString().trim();
      if (stoppedPids.isNotEmpty) {
        _rememberAppLog(
          'Stopped stale $executableName process(es) before TUN start: $stoppedPids.',
        );
      }
    } catch (error) {
      final executableName = p.basename(binaryPath);
      _rememberAppLog(
        'Failed to stop stale $executableName processes before TUN start: ${_describeError(error)}',
      );
    }
  }

  bool _stopStaleWindowsTunCoreProcessesWithToolhelp(String binaryPath) {
    final stopwatch = Stopwatch()..start();
    try {
      final targetPathKey = _windowsPathKey(binaryPath);
      final staleProcesses = _snapshotWindowsProcesses()
          .where(
            (process) =>
                process.pid != pid &&
                process.path != null &&
                _windowsPathKey(process.path!) == targetPathKey,
          )
          .toList(growable: false);

      final stoppedPids = <String>[];
      final failedPids = <String>[];
      for (final process in staleProcesses) {
        if (_terminateWindowsProcessByPid(process.pid)) {
          stoppedPids.add(process.pid.toString());
        } else {
          failedPids.add(process.pid.toString());
        }
      }

      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:stale_core_sweep elapsed=${stopwatch.elapsedMilliseconds}ms exit=0.',
      );
      if (failedPids.isNotEmpty) {
        _rememberAppLog(
          'Fast stale core sweep could not stop PID(s) ${failedPids.join(',')}; falling back to PowerShell.',
        );
        return false;
      }
      if (stoppedPids.isNotEmpty) {
        _rememberAppLog(
          'Stopped stale ${p.basename(binaryPath)} process(es) before TUN start: ${stoppedPids.join(',')}.',
        );
      }
      return true;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:stale_core_sweep elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      _rememberAppLog(
        'Fast stale core sweep unavailable; falling back to PowerShell.',
      );
      return false;
    }
  }

  bool _terminateWindowsProcessByPid(
    int processId, {
    String? timingLabel,
    Duration waitTimeout = const Duration(milliseconds: 500),
  }) {
    final stopwatch = timingLabel == null ? null : (Stopwatch()..start());
    var success = false;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final openProcess = kernel32
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
      final terminateProcess = kernel32
          .lookupFunction<_TerminateProcessNative, _TerminateProcessDart>(
            'TerminateProcess',
          );
      final waitForSingleObject = kernel32
          .lookupFunction<_WaitForSingleObjectNative, _WaitForSingleObjectDart>(
            'WaitForSingleObject',
          );
      final closeHandle = kernel32
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

      final handle = openProcess(
        _processTerminate | _synchronize,
        0,
        processId,
      );
      if (handle == 0) {
        success = Process.killPid(processId, ProcessSignal.sigkill);
        return success;
      }

      try {
        success = terminateProcess(handle, 1) != 0;
        if (success) {
          waitForSingleObject(handle, waitTimeout.inMilliseconds);
        }
        return success;
      } finally {
        closeHandle(handle);
      }
    } finally {
      stopwatch?.stop();
      if (timingLabel != null) {
        _rememberAppLog(
          'Process timing: $timingLabel elapsed=${stopwatch!.elapsedMilliseconds}ms exit=${success ? 0 : 1}.',
        );
      }
    }
  }

  String _buildWindowsTunInterfaceName() {
    return 'EntropyVPN TUN';
  }

  Future<bool> _relaunchAsAdministrator() async {
    const script = r'''
param(
  [string]$FilePath,
  [string]$WorkingDirectory,
  [string]$RelaunchArgument
)
try {
  Start-Process `
    -FilePath $FilePath `
    -ArgumentList $RelaunchArgument `
    -WorkingDirectory $WorkingDirectory `
    -Verb RunAs | Out-Null
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final executable = Platform.resolvedExecutable;
      final result = await _runPowerShellScript(
        script,
        label: 'relaunch_as_administrator',
        namedArgs: <String, String>{
          'FilePath': executable,
          'WorkingDirectory': p.dirname(executable),
          'RelaunchArgument': '--entropyvpn-elevated-relaunch',
        },
      );
      if (result.exitCode == 0) {
        return true;
      }
      _rememberAppLog(
        'Failed to relaunch as Administrator: ${_describeError(result.stderr)}',
      );
      return false;
    } catch (error) {
      _rememberAppLog(
        'Failed to relaunch as Administrator: ${_describeError(error)}',
      );
      return false;
    }
  }

  Future<_TunRoutingPreparation?> _prepareTunServerRouting(
    ParsedVpnProfile profile, {
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
  }) async {
    if (!Platform.isWindows || trafficMode != TrafficMode.tun) {
      return null;
    }

    final server = profile.server.trim();
    final serverIp = InternetAddress.tryParse(server);
    if (serverIp != null) {
      return _prepareIpTunServerRouting(serverIp);
    }
    return _prepareDomainTunServerRouting(server, tunIpMode: tunIpMode);
  }

  Future<_TunRoutingPreparation?> _prepareDomainTunServerRouting(
    String host, {
    required TunIpMode tunIpMode,
  }) async {
    final uniqueAddresses = await _resolveServerAddressesForBypass(
      host,
      tunIpMode: tunIpMode,
    );
    if (uniqueAddresses == null || uniqueAddresses.isEmpty) {
      return null;
    }

    _rememberAppLog(
      'Resolved VPN server $host for host-route bypass: ${uniqueAddresses.map((address) => address.address).join(', ')}.',
    );

    const script = r'''
param([string]$RoutesBase64)
try {
  function Select-HardwareDefaultRoute {
    $routes = Get-NetRoute `
      -AddressFamily IPv4 `
      -DestinationPrefix '0.0.0.0/0' `
      -ErrorAction SilentlyContinue |
      Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.NextHop) -and
        [string]$_.NextHop -ne '0.0.0.0'
      }
    $candidates = foreach ($route in $routes) {
      $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
      if ($null -eq $adapter) {
        continue
      }
      if (-not $adapter.HardwareInterface) {
        continue
      }

      [PSCustomObject]@{
        InterfaceAlias = [string]$route.InterfaceAlias
        InterfaceIndex = [int]$route.InterfaceIndex
        NextHop = [string]$route.NextHop
        InterfaceMetric = if ($null -eq $route.InterfaceMetric) { [int]::MaxValue } else { [int]$route.InterfaceMetric }
        RouteMetric = if ($null -eq $route.RouteMetric) { [int]::MaxValue } else { [int]$route.RouteMetric }
      }
    }
    $candidates | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
  }

  $selected = Select-HardwareDefaultRoute
  if ($null -eq $selected) {
    exit 0
  }

  $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($RoutesBase64))
  $routes = $json | ConvertFrom-Json
  if ($null -eq $routes) {
    $routes = @()
  } elseif ($routes -isnot [System.Array]) {
    $routes = @($routes)
  }

  $routeResults = New-Object System.Collections.Generic.List[object]
  foreach ($route in $routes) {
    $destinationPrefix = [string]$route.destinationPrefix
    $nextHop = [string]$selected.NextHop
    try {
      $existing = Get-NetRoute -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
        Where-Object {
          $_.InterfaceIndex -eq [int]$selected.InterfaceIndex -and
          $_.NextHop -eq $nextHop
        } |
        Select-Object -First 1

      $status = 'exists'
      if ($null -eq $existing) {
        New-NetRoute `
          -DestinationPrefix $destinationPrefix `
          -InterfaceIndex ([int]$selected.InterfaceIndex) `
          -NextHop $nextHop `
          -PolicyStore ActiveStore | Out-Null
        $status = 'created'
      }
      $routeResults.Add([PSCustomObject]@{
        DestinationPrefix = $destinationPrefix
        NextHop = $nextHop
        Status = $status
      })
    } catch {
      $routeResults.Add([PSCustomObject]@{
        DestinationPrefix = $destinationPrefix
        NextHop = $nextHop
        Status = 'failed'
        Error = [string]$_.Exception.Message
      })
    }
  }

  [PSCustomObject]@{
    DefaultRoute = $selected
    Routes = $routeResults.ToArray()
  } | ConvertTo-Json -Depth 4 -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final result = await _runPowerShellScript(
        script,
        label: 'domain_server_routing',
        namedArgs: <String, String>{
          'RoutesBase64': base64Encode(
            utf8.encode(_serverBypassPrefixesJson(uniqueAddresses)),
          ),
        },
      );

      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to prepare domain host-route bypass: ${_describeError(result.stderr)}',
        );
        return null;
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        _rememberAppLog(
          'Could not resolve a hardware default interface for domain server; using core defaults.',
        );
        return null;
      }

      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic>) {
        _rememberAppLog(
          'Failed to prepare domain host-route bypass: unexpected output "$output".',
        );
        return null;
      }

      final defaultRoute = (decoded['DefaultRoute'] as Map?)
          ?.cast<String, dynamic>();
      final alias = defaultRoute?['InterfaceAlias']?.toString().trim();
      final index = (defaultRoute?['InterfaceIndex'] as num?)?.toInt();
      final nextHop = defaultRoute?['NextHop']?.toString().trim();
      if (alias == null ||
          alias.isEmpty ||
          index == null ||
          nextHop == null ||
          nextHop.isEmpty) {
        _rememberAppLog(
          'Failed to prepare domain host-route bypass: default route details were incomplete.',
        );
        return null;
      }

      final routes = _decodeHostRouteResults(
        decoded['Routes'],
        interfaceAlias: alias,
        interfaceIndex: index,
      );
      _trackTemporaryServerRoutes(routes);
      _rememberAppLog(
        'VPN server is a domain name; using hardware default interface $alias for TUN outbounds and host-route bypasses.',
      );
      return _TunRoutingPreparation(
        outboundBindInterface: alias,
        serverAddressOverride: uniqueAddresses.first.address,
        hasHostRoute: routes.isNotEmpty,
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to prepare domain host-route bypass: ${_describeError(error)}',
      );
      return null;
    }
  }

  Future<_TunRoutingPreparation?> _prepareIpTunServerRouting(
    InternetAddress serverIp,
  ) async {
    if (serverIp.type == InternetAddressType.IPv4) {
      final nativeRouting = await _prepareNativeIpv4TunServerRouting(serverIp);
      if (nativeRouting != null) {
        return nativeRouting;
      }
      final fastRouting = await _prepareFastIpv4TunServerRouting(serverIp);
      if (fastRouting != null) {
        return fastRouting;
      }
    }

    const script = r'''
param(
  [string]$RemoteAddress,
  [string]$DestinationPrefix
)
try {
  function Select-HardwareDefaultRoute {
    $routes = Get-NetRoute `
      -AddressFamily IPv4 `
      -DestinationPrefix '0.0.0.0/0' `
      -ErrorAction SilentlyContinue |
      Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.NextHop) -and
        [string]$_.NextHop -ne '0.0.0.0'
      }
    $candidates = foreach ($route in $routes) {
      $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
      if ($null -eq $adapter) {
        continue
      }
      if (-not $adapter.HardwareInterface) {
        continue
      }

      [PSCustomObject]@{
        InterfaceAlias = [string]$route.InterfaceAlias
        InterfaceIndex = [int]$route.InterfaceIndex
        NextHop = [string]$route.NextHop
        SourceAddress = ''
        HardwareInterface = $true
        Virtual = $false
        InterfaceMetric = if ($null -eq $route.InterfaceMetric) { [int]::MaxValue } else { [int]$route.InterfaceMetric }
        RouteMetric = if ($null -eq $route.RouteMetric) { [int]::MaxValue } else { [int]$route.RouteMetric }
      }
    }
    $candidates | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
  }

  $entries = @(Find-NetRoute -RemoteIPAddress $RemoteAddress)
  $route = $entries |
    Where-Object {
      $_.CimClass.CimClassName -eq 'MSFT_NetRoute' -and
      -not [string]::IsNullOrWhiteSpace([string]$_.NextHop)
    } |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1
  if ($null -eq $route) {
    exit 0
  }

  $ip = $entries |
    Where-Object {
      $_.CimClass.CimClassName -eq 'MSFT_NetIPAddress' -and
      $_.InterfaceIndex -eq $route.InterfaceIndex
    } |
    Select-Object -First 1
  $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
  $hardware = if ($null -eq $adapter) { $null } else { [bool]$adapter.HardwareInterface }
  $virtual = if ($null -eq $adapter) { $null } else { [bool]$adapter.Virtual }
  $primary = [PSCustomObject]@{
    InterfaceAlias = [string]$route.InterfaceAlias
    InterfaceIndex = [int]$route.InterfaceIndex
    SourceAddress = if ($null -eq $ip) { '' } else { [string]$ip.IPAddress }
    NextHop = [string]$route.NextHop
    HardwareInterface = $hardware
    Virtual = $virtual
  }

  $pinned = $null
  $pinReason = 'none'
  if (-not [string]::IsNullOrWhiteSpace([string]$primary.NextHop) -and
      $primary.HardwareInterface -ne $false -and
      $primary.Virtual -ne $true) {
    $pinned = $primary
    $pinReason = 'route'
  } else {
    $fallback = Select-HardwareDefaultRoute
    if ($null -ne $fallback -and -not [string]::IsNullOrWhiteSpace([string]$fallback.NextHop)) {
      $pinned = $fallback
      $pinReason = 'fallback'
    }
  }

  $routeResult = $null
  if ($null -ne $pinned) {
    $nextHop = [string]$pinned.NextHop
    try {
      $existing = Get-NetRoute -DestinationPrefix $DestinationPrefix -ErrorAction SilentlyContinue |
        Where-Object {
          $_.InterfaceIndex -eq [int]$pinned.InterfaceIndex -and
          $_.NextHop -eq $nextHop
        } |
        Select-Object -First 1

      $status = 'exists'
      if ($null -eq $existing) {
        New-NetRoute `
          -DestinationPrefix $DestinationPrefix `
          -InterfaceIndex ([int]$pinned.InterfaceIndex) `
          -NextHop $nextHop `
          -PolicyStore ActiveStore | Out-Null
        $status = 'created'
      }
      $routeResult = [PSCustomObject]@{
        DestinationPrefix = $DestinationPrefix
        NextHop = $nextHop
        Status = $status
      }
    } catch {
      $routeResult = [PSCustomObject]@{
        DestinationPrefix = $DestinationPrefix
        NextHop = $nextHop
        Status = 'failed'
        Error = [string]$_.Exception.Message
      }
    }
  }

  [PSCustomObject]@{
    Route = $primary
    PinnedRoute = $pinned
    PinReason = $pinReason
    RouteResult = $routeResult
  } | ConvertTo-Json -Depth 4 -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    final destinationPrefix = serverIp.type == InternetAddressType.IPv6
        ? '${serverIp.address}/128'
        : '${serverIp.address}/32';

    try {
      final result = await _runPowerShellScript(
        script,
        label: 'ip_server_routing',
        namedArgs: <String, String>{
          'RemoteAddress': serverIp.address,
          'DestinationPrefix': destinationPrefix,
        },
      );

      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to resolve Windows route for ${serverIp.address}: ${_describeError(result.stderr)}',
        );
        return null;
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        _rememberAppLog(
          'Could not resolve Windows route for ${serverIp.address}; using core defaults.',
        );
        return null;
      }

      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic>) {
        _rememberAppLog(
          'Failed to resolve Windows route for ${serverIp.address}: unexpected output "$output".',
        );
        return null;
      }

      final route = _decodeWindowsRouteInfo(decoded['Route']);
      if (route == null) {
        _rememberAppLog(
          'Could not resolve Windows route for ${serverIp.address}; using core defaults.',
        );
        return null;
      }

      _rememberAppLog(
        'Windows route to ${serverIp.address}: interface=${route.interfaceAlias}, source=${route.sourceAddress}, nextHop=${route.nextHop}, hardware=${route.hardwareInterface}, virtual=${route.virtual}.',
      );

      final pinnedRoute = _decodeWindowsRouteInfo(decoded['PinnedRoute']);
      final pinReason = decoded['PinReason']?.toString();
      if (pinnedRoute == null || pinnedRoute.interfaceIndex == null) {
        _rememberAppLog(
          'No suitable hardware default route found for VPN server bypass; continuing with ${route.interfaceAlias}.',
        );
        return _TunRoutingPreparation(
          outboundBindInterface: route.interfaceAlias,
          serverAddressOverride: null,
          hasHostRoute: false,
        );
      }

      if (pinReason == 'fallback') {
        _rememberAppLog(
          'Detected virtual route to VPN server. Installing direct host route via ${pinnedRoute.interfaceAlias} (${pinnedRoute.nextHop})...',
        );
      } else {
        _rememberAppLog(
          'Installing explicit host route for VPN server via ${pinnedRoute.interfaceAlias} (${pinnedRoute.nextHop}) to keep upstream traffic outside TUN...',
        );
      }

      final routes = _decodeHostRouteResults(
        decoded['RouteResult'],
        interfaceAlias: pinnedRoute.interfaceAlias,
        interfaceIndex: pinnedRoute.interfaceIndex!,
      );
      _trackTemporaryServerRoutes(routes);
      return _TunRoutingPreparation(
        outboundBindInterface: routes.isEmpty
            ? route.interfaceAlias
            : pinnedRoute.interfaceAlias,
        serverAddressOverride: null,
        hasHostRoute: routes.isNotEmpty,
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to resolve Windows route for ${serverIp.address}: ${_describeError(error)}',
      );
      return null;
    }
  }

  Future<_TunRoutingPreparation?> _prepareNativeIpv4TunServerRouting(
    InternetAddress serverIp,
  ) async {
    Object? rawResult;
    try {
      rawResult = await _windowsTunChannel.invokeMethod<Object?>(
        'prepareIpv4ServerRoute',
        <String, Object?>{'remoteAddress': serverIp.address},
      );
    } on MissingPluginException {
      _rememberAppLog(
        'Native IPv4 server route path unavailable: Windows runner channel is not registered.',
      );
      return null;
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Native IPv4 server route path unavailable: ${error.message ?? error.code}',
      );
      return null;
    } catch (error) {
      _rememberAppLog(
        'Native IPv4 server route path unavailable: ${_describeError(error)}',
      );
      return null;
    }

    if (rawResult is! Map) {
      _rememberAppLog(
        'Native IPv4 server route path unavailable: runner returned unexpected result.',
      );
      return null;
    }

    final result = rawResult.cast<Object?, Object?>();
    final elapsedMs = result['elapsedMs']?.toString();
    if (result['ok'] != true) {
      final failedStep = result['failedStep']?.toString() ?? 'unknown';
      final error = result['error']?.toString() ?? 'unknown error';
      final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
      _rememberAppLog(
        'Native IPv4 server route path unavailable: $failedStep failed$elapsed: $error',
      );
      return null;
    }

    final interfaceAlias = result['interfaceAlias']?.toString().trim();
    final sourceAddress = result['sourceAddress']?.toString().trim();
    final nextHop = result['nextHop']?.toString().trim();
    final destinationPrefix = result['destinationPrefix']?.toString().trim();
    final interfaceIndex = (result['interfaceIndex'] as num?)?.toInt();
    if (interfaceAlias == null ||
        interfaceAlias.isEmpty ||
        nextHop == null ||
        nextHop.isEmpty ||
        destinationPrefix == null ||
        destinationPrefix.isEmpty ||
        interfaceIndex == null) {
      _rememberAppLog(
        'Native IPv4 server route path unavailable: runner returned incomplete route details.',
      );
      return null;
    }

    final createdRoute = result['routeStatus']?.toString() == 'created';
    final route = _WindowsHostRoute(
      destinationPrefix: destinationPrefix,
      interfaceAlias: interfaceAlias,
      interfaceIndex: interfaceIndex,
      nextHop: nextHop,
      removalTool: _WindowsRouteRemovalTool.routeExe,
      removeWhenUnused: createdRoute,
    );
    _trackTemporaryServerRoutes(<_WindowsHostRoute>[route]);
    _rememberAppLog(
      'Native IPv4 server route setup${elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms'}.',
    );
    _rememberAppLog(
      'Windows route to ${serverIp.address}: interface=$interfaceAlias, source=${_orDash(sourceAddress)}, nextHop=$nextHop, hardware=${result['hardwareInterface']}, virtual=${result['virtual']}.',
    );
    _rememberAppLog(
      'Native IPv4 host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) ${createdRoute ? 'created' : 'already existed'}.',
    );
    return _TunRoutingPreparation(
      outboundBindInterface: interfaceAlias,
      serverAddressOverride: null,
      hasHostRoute: true,
    );
  }

  Future<_TunRoutingPreparation?> _prepareFastIpv4TunServerRouting(
    InternetAddress serverIp,
  ) async {
    try {
      final defaultRouteResult = await _runTimedProcess(
        'route_print_ipv4_default',
        'route.exe',
        <String>['PRINT', '-4', '0.0.0.0'],
      );
      if (defaultRouteResult.exitCode != 0) {
        _rememberAppLog(
          'Fast IPv4 route path unavailable: route print failed with exit ${defaultRouteResult.exitCode}.',
        );
        return null;
      }

      final defaultRoute = _parseDefaultIpv4Route(
        defaultRouteResult.stdout.toString(),
      );
      if (defaultRoute == null) {
        _rememberAppLog(
          'Fast IPv4 route path unavailable: default IPv4 gateway was not found.',
        );
        return null;
      }

      final interfaceAlias = await _resolveIpv4InterfaceAlias(
        defaultRoute.interfaceAddress,
      );
      if (interfaceAlias == null || interfaceAlias.isEmpty) {
        _rememberAppLog(
          'Fast IPv4 route path unavailable: interface alias for ${defaultRoute.interfaceAddress} was not found.',
        );
        return null;
      }
      if (_looksVirtualInterfaceAlias(interfaceAlias)) {
        _rememberAppLog(
          'Fast IPv4 route path unavailable: default interface $interfaceAlias looks virtual.',
        );
        return null;
      }

      final destinationPrefix = '${serverIp.address}/32';
      final routeExists = await _fastIpv4HostRouteExists(
        serverIp.address,
        nextHop: defaultRoute.gateway,
      );
      if (!routeExists) {
        final addResult = await _runTimedProcess(
          'route_add_ipv4_server',
          'route.exe',
          <String>[
            'ADD',
            serverIp.address,
            'MASK',
            '255.255.255.255',
            defaultRoute.gateway,
            'METRIC',
            '1',
          ],
        );
        if (addResult.exitCode != 0 &&
            !_routeOutputSaysAlreadyExists(
              addResult.stdout,
              addResult.stderr,
            )) {
          _rememberAppLog(
            'Fast IPv4 route path unavailable: route add failed with exit ${addResult.exitCode}: ${_describeError(addResult.stderr)}',
          );
          return null;
        }
      }

      final route = _WindowsHostRoute(
        destinationPrefix: destinationPrefix,
        interfaceAlias: interfaceAlias,
        interfaceIndex: 0,
        nextHop: defaultRoute.gateway,
        removalTool: _WindowsRouteRemovalTool.routeExe,
        removeWhenUnused: !routeExists,
      );
      _trackTemporaryServerRoutes(<_WindowsHostRoute>[route]);
      _rememberAppLog(
        'Windows route to ${serverIp.address}: interface=$interfaceAlias, source=${defaultRoute.interfaceAddress}, nextHop=${defaultRoute.gateway}, hardware=true, virtual=false.',
      );
      _rememberAppLog(
        'Fast IPv4 host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) ${routeExists ? 'already existed' : 'created'}.',
      );
      return _TunRoutingPreparation(
        outboundBindInterface: interfaceAlias,
        serverAddressOverride: null,
        hasHostRoute: true,
      );
    } catch (error) {
      _rememberAppLog(
        'Fast IPv4 route path unavailable: ${_describeError(error)}',
      );
      return null;
    }
  }

  Future<List<InternetAddress>?> _resolveServerAddressesForBypass(
    String host, {
    required TunIpMode tunIpMode,
  }) async {
    try {
      final addresses = await InternetAddress.lookup(host);
      final uniqueAddresses = <String, InternetAddress>{
        for (final address in addresses)
          if (_addressMatchesTunIpMode(address, tunIpMode))
            address.address: address,
      }.values.toList(growable: false);
      if (uniqueAddresses.isEmpty) {
        _rememberAppLog(
          'No addresses returned while resolving VPN server $host for host-route bypass.',
        );
      }
      return uniqueAddresses;
    } catch (error) {
      _rememberAppLog(
        'Failed to resolve VPN server $host for host-route bypass: ${_describeError(error)}',
      );
      return null;
    }
  }

  bool _addressMatchesTunIpMode(InternetAddress address, TunIpMode tunIpMode) {
    return switch (tunIpMode) {
      TunIpMode.ipv4 => address.type == InternetAddressType.IPv4,
      TunIpMode.ipv6 => address.type == InternetAddressType.IPv6,
      TunIpMode.dualStack => true,
    };
  }

  _Ipv4DefaultRoute? _parseDefaultIpv4Route(String routePrintOutput) {
    final candidates = <_Ipv4DefaultRoute>[];
    final linePattern = RegExp(
      r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\S+)\s+(\S+)\s+(\d+)\s*$',
      caseSensitive: false,
    );
    for (final line in const LineSplitter().convert(routePrintOutput)) {
      final match = linePattern.firstMatch(line);
      if (match == null) {
        continue;
      }
      final gateway = match.group(1) ?? '';
      final interfaceAddress = match.group(2) ?? '';
      final metric = int.tryParse(match.group(3) ?? '');
      if (gateway.toLowerCase() == 'on-link' ||
          InternetAddress.tryParse(gateway)?.type != InternetAddressType.IPv4 ||
          InternetAddress.tryParse(interfaceAddress)?.type !=
              InternetAddressType.IPv4 ||
          metric == null) {
        continue;
      }
      candidates.add(
        _Ipv4DefaultRoute(
          gateway: gateway,
          interfaceAddress: interfaceAddress,
          metric: metric,
        ),
      );
    }
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((left, right) => left.metric.compareTo(right.metric));
    return candidates.first;
  }

  Future<String?> _resolveIpv4InterfaceAlias(String interfaceAddress) async {
    final result = await _runTimedProcess(
      'netsh_ipv4_addresses',
      'netsh.exe',
      <String>['interface', 'ipv4', 'show', 'addresses'],
    );
    if (result.exitCode != 0) {
      return null;
    }
    return _parseNetshInterfaceAliasForAddress(
      result.stdout.toString(),
      interfaceAddress,
    );
  }

  String? _parseNetshInterfaceAliasForAddress(
    String netshOutput,
    String interfaceAddress,
  ) {
    String? currentAlias;
    final interfacePattern = RegExp(r'interface\s+"([^"]+)"');
    for (final line in const LineSplitter().convert(netshOutput)) {
      final interfaceMatch = interfacePattern.firstMatch(line);
      if (interfaceMatch != null) {
        currentAlias = interfaceMatch.group(1)?.trim();
        continue;
      }
      if (currentAlias != null && line.contains(interfaceAddress)) {
        return currentAlias;
      }
    }
    return null;
  }

  bool _looksVirtualInterfaceAlias(String interfaceAlias) {
    final alias = interfaceAlias.toLowerCase();
    return alias.contains('vpn') ||
        alias.contains('tun') ||
        alias.contains('tap') ||
        alias.contains('wintun') ||
        alias.contains('wireguard') ||
        alias.contains('loopback') ||
        alias.contains('virtual');
  }

  Future<bool> _fastIpv4HostRouteExists(
    String address, {
    required String nextHop,
  }) async {
    final result = await _runTimedProcess(
      'route_print_ipv4_server',
      'route.exe',
      <String>['PRINT', '-4', address],
    );
    if (result.exitCode != 0) {
      return false;
    }
    return _routePrintHasIpv4HostRoute(
      result.stdout.toString(),
      address,
      nextHop: nextHop,
    );
  }

  bool _routePrintHasIpv4HostRoute(
    String routePrintOutput,
    String address, {
    required String nextHop,
  }) {
    final escapedAddress = RegExp.escape(address);
    final escapedNextHop = RegExp.escape(nextHop);
    final linePattern = RegExp(
      r'^\s*' +
          escapedAddress +
          r'\s+255\.255\.255\.255\s+' +
          escapedNextHop +
          r'\s+\S+\s+\d+\s*$',
      caseSensitive: false,
    );
    return const LineSplitter()
        .convert(routePrintOutput)
        .any(linePattern.hasMatch);
  }

  bool _routeOutputSaysAlreadyExists(Object stdout, Object stderr) {
    final output = '${stdout.toString()}\n${stderr.toString()}'.toLowerCase();
    return output.contains('already exists') ||
        output.contains('object already exists');
  }

  String _serverBypassPrefixesJson(List<InternetAddress> addresses) {
    return jsonEncode(
      addresses
          .map(
            (address) => <String, dynamic>{
              'destinationPrefix': address.type == InternetAddressType.IPv6
                  ? '${address.address}/128'
                  : '${address.address}/32',
            },
          )
          .toList(growable: false),
    );
  }

  _WindowsRouteInfo? _decodeWindowsRouteInfo(dynamic decoded) {
    if (decoded is! Map) {
      return null;
    }
    final json = decoded.cast<String, dynamic>();
    final alias = json['InterfaceAlias']?.toString().trim();
    if (alias == null || alias.isEmpty) {
      return null;
    }
    return _WindowsRouteInfo(
      interfaceAlias: alias,
      interfaceIndex: (json['InterfaceIndex'] as num?)?.toInt(),
      sourceAddress: json['SourceAddress']?.toString().trim(),
      nextHop: json['NextHop']?.toString().trim(),
      hardwareInterface: json['HardwareInterface'] as bool?,
      virtual: json['Virtual'] as bool?,
    );
  }

  List<_WindowsHostRoute> _decodeHostRouteResults(
    dynamic decoded, {
    required String interfaceAlias,
    required int interfaceIndex,
  }) {
    final routeItems = decoded is List
        ? decoded
        : decoded == null
        ? const <dynamic>[]
        : <dynamic>[decoded];
    final routes = <_WindowsHostRoute>[];
    for (final item in routeItems) {
      if (item is! Map) {
        continue;
      }
      final destinationPrefix = item['DestinationPrefix']?.toString().trim();
      final nextHop = item['NextHop']?.toString().trim();
      if (destinationPrefix == null ||
          destinationPrefix.isEmpty ||
          nextHop == null ||
          nextHop.isEmpty) {
        continue;
      }
      final status = item['Status']?.toString();
      final route = _WindowsHostRoute(
        destinationPrefix: destinationPrefix,
        interfaceAlias: interfaceAlias,
        interfaceIndex: interfaceIndex,
        nextHop: nextHop,
        removeWhenUnused: status == 'created',
      );
      if (status != 'failed') {
        routes.add(route);
      }
      _rememberAppLog(
        'Temporary host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) ${status == 'created'
            ? 'created'
            : status == 'failed'
            ? 'could not be installed'
            : 'already existed'}.',
      );
    }
    return routes;
  }

  void _trackTemporaryServerRoutes(List<_WindowsHostRoute> routes) {
    if (routes.isEmpty) {
      return;
    }
    final routesByKey = <String, _WindowsHostRoute>{
      for (final route in _temporaryServerRoutes) _hostRouteKey(route): route,
    };
    for (final route in routes) {
      routesByKey.putIfAbsent(_hostRouteKey(route), () => route);
    }
    _temporaryServerRoutes = List<_WindowsHostRoute>.unmodifiable(
      routesByKey.values,
    );
  }

  String _hostRouteKey(_WindowsHostRoute route) {
    return _routeRemovalKey(
      destinationPrefix: route.destinationPrefix,
      interfaceIndex: route.interfaceIndex,
      nextHop: route.nextHop,
    );
  }

  Future<SplitTunnelSettings> _expandSplitTunnelSettings(
    SplitTunnelSettings settings,
  ) async {
    final normalized = settings.normalized;
    if (!Platform.isWindows ||
        !normalized.isEnabled ||
        normalized.apps.isEmpty) {
      return normalized;
    }

    final cacheKey = _splitTunnelExpansionCacheKey(normalized);
    final cached = _splitTunnelExpansionCache;
    final now = DateTime.now();
    if (cached != null &&
        cached.key == cacheKey &&
        now.difference(cached.createdAt) <= _splitTunnelExpansionCacheTtl) {
      _rememberAppLog(
        'Split tunneling reused cached process tree expansion (${cached.addedAppCount} child process paths).',
      );
      return cached.settings;
    }

    final descendants = await _findRunningDescendantApps(normalized.apps);

    final appsById = <String, SplitTunnelApp>{
      for (final app in normalized.apps) app.id: app,
    };
    for (final app in descendants) {
      appsById[app.id] = app;
    }
    final expanded = SplitTunnelSettings(
      mode: normalized.mode,
      apps: appsById.values.toList(growable: false),
    ).normalized;
    final addedAppCount = expanded.apps.length - normalized.apps.length;
    _splitTunnelExpansionCache = _SplitTunnelExpansionCacheEntry(
      key: cacheKey,
      settings: expanded,
      createdAt: now,
      addedAppCount: addedAppCount,
    );
    if (addedAppCount > 0) {
      _rememberAppLog(
        'Split tunneling added $addedAppCount running child process paths.',
      );
    }
    return expanded;
  }

  String _splitTunnelExpansionCacheKey(SplitTunnelSettings settings) {
    final normalized = settings.normalized;
    final appKeys =
        normalized.apps
            .map((app) => app.id)
            .where((id) => id.trim().isNotEmpty)
            .toList(growable: false)
          ..sort();
    return '${normalized.mode.name}|${appKeys.join('\n')}';
  }

  Future<List<SplitTunnelApp>> _findRunningDescendantApps(
    List<SplitTunnelApp> selectedApps,
  ) async {
    final toolhelpDescendants = _findRunningDescendantAppsWithToolhelp(
      selectedApps,
    );
    if (toolhelpDescendants != null) {
      return toolhelpDescendants;
    }

    final selectedPaths = selectedApps
        .map((app) => app.path.trim())
        .where((path) => path.isNotEmpty)
        .join('\n');
    if (selectedPaths.isEmpty) {
      return const <SplitTunnelApp>[];
    }

    const script = r'''
param([string]$SelectedPathsBase64)
try {
  $selectedText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($SelectedPathsBase64))
  $selected = @{}
  $selectedText -split "`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $selected[$_.ToLowerInvariant()] = $true }

  $processes = @(Get-CimInstance -Query "SELECT ProcessId, ParentProcessId, ExecutablePath FROM Win32_Process WHERE ExecutablePath IS NOT NULL")
  $byParent = @{}
  foreach ($process in $processes) {
    $parent = [int]$process.ParentProcessId
    if (-not $byParent.ContainsKey($parent)) {
      $byParent[$parent] = New-Object System.Collections.Generic.List[object]
    }
    $byParent[$parent].Add($process)
  }

  $queue = New-Object System.Collections.Generic.Queue[int]
  foreach ($process in $processes) {
    $path = ([string]$process.ExecutablePath).Trim()
    if ($selected.ContainsKey($path.ToLowerInvariant())) {
      $queue.Enqueue([int]$process.ProcessId)
    }
  }

  $found = @{}
  while ($queue.Count -gt 0) {
    $parentId = $queue.Dequeue()
    if (-not $byParent.ContainsKey($parentId)) {
      continue
    }
    foreach ($child in $byParent[$parentId]) {
      $childPath = ([string]$child.ExecutablePath).Trim()
      if ([string]::IsNullOrWhiteSpace($childPath)) {
        continue
      }
      $key = $childPath.ToLowerInvariant()
      if (-not $selected.ContainsKey($key) -and -not $found.ContainsKey($key)) {
        $found[$key] = $childPath
      }
      $queue.Enqueue([int]$child.ProcessId)
    }
  }

  $found.Values |
    Sort-Object |
    ForEach-Object {
      [PSCustomObject]@{
        name = [System.IO.Path]::GetFileNameWithoutExtension($_)
        path = $_
      }
    } |
    ConvertTo-Json -Depth 3 -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final result = await _runPowerShellScript(
        script,
        label: 'expand_split_tunnel_process_tree',
        namedArgs: <String, String>{
          'SelectedPathsBase64': base64Encode(utf8.encode(selectedPaths)),
        },
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to expand split tunnel process tree: ${_describeError(result.stderr)}',
        );
        return const <SplitTunnelApp>[];
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        return const <SplitTunnelApp>[];
      }
      final decoded = jsonDecode(output);
      final rawItems = decoded is List
          ? decoded
          : decoded is Map
          ? <dynamic>[decoded]
          : const <dynamic>[];
      return rawItems
          .map((item) {
            if (item is! Map) {
              return null;
            }
            return SplitTunnelApp.fromPath(
              name: item['name']?.toString() ?? '',
              path: item['path']?.toString() ?? '',
            );
          })
          .whereType<SplitTunnelApp>()
          .toList(growable: false);
    } catch (error) {
      _rememberAppLog(
        'Failed to expand split tunnel process tree: ${_describeError(error)}',
      );
      return const <SplitTunnelApp>[];
    }
  }

  List<SplitTunnelApp>? _findRunningDescendantAppsWithToolhelp(
    List<SplitTunnelApp> selectedApps,
  ) {
    if (!Platform.isWindows) {
      return null;
    }

    final selectedPathKeys = selectedApps
        .map((app) => _windowsPathKey(app.path))
        .where((path) => path.isNotEmpty)
        .toSet();
    if (selectedPathKeys.isEmpty) {
      return const <SplitTunnelApp>[];
    }

    final stopwatch = Stopwatch()..start();
    try {
      final processes = _snapshotWindowsProcesses();
      final childrenByParent = <int, List<_WindowsProcessInfo>>{};
      for (final process in processes) {
        childrenByParent
            .putIfAbsent(process.parentPid, () => <_WindowsProcessInfo>[])
            .add(process);
      }

      final queue = Queue<int>();
      for (final process in processes) {
        final path = process.path;
        if (path != null && selectedPathKeys.contains(_windowsPathKey(path))) {
          queue.add(process.pid);
        }
      }

      final descendantsByPath = <String, String>{};
      while (queue.isNotEmpty) {
        final parentPid = queue.removeFirst();
        final children = childrenByParent[parentPid];
        if (children == null) {
          continue;
        }
        for (final child in children) {
          final childPath = child.path;
          if (childPath != null && childPath.trim().isNotEmpty) {
            final childPathKey = _windowsPathKey(childPath);
            if (!selectedPathKeys.contains(childPathKey) &&
                !descendantsByPath.containsKey(childPathKey)) {
              descendantsByPath[childPathKey] = childPath;
            }
          }
          queue.add(child.pid);
        }
      }

      final descendants =
          descendantsByPath.values
              .map(
                (path) => SplitTunnelApp.fromPath(
                  name: p.basenameWithoutExtension(path),
                  path: path,
                ),
              )
              .toList(growable: false)
            ..sort(
              (left, right) =>
                  left.name.toLowerCase().compareTo(right.name.toLowerCase()),
            );
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:expand_split_tunnel_process_tree elapsed=${stopwatch.elapsedMilliseconds}ms exit=0.',
      );
      return descendants;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:expand_split_tunnel_process_tree elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      _rememberAppLog(
        'Fast split tunnel process tree expansion unavailable; falling back to PowerShell.',
      );
      return null;
    }
  }

  List<_WindowsProcessInfo> _snapshotWindowsProcesses() {
    final cached = _windowsProcessSnapshotCache;
    final now = DateTime.now();
    if (cached != null &&
        now.difference(cached.createdAt) <= _windowsProcessSnapshotCacheTtl) {
      return cached.processes;
    }

    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createToolhelp32Snapshot = kernel32
        .lookupFunction<
          _CreateToolhelp32SnapshotNative,
          _CreateToolhelp32SnapshotDart
        >('CreateToolhelp32Snapshot');
    final process32First = kernel32
        .lookupFunction<_Process32Native, _Process32Dart>('Process32FirstW');
    final process32Next = kernel32
        .lookupFunction<_Process32Native, _Process32Dart>('Process32NextW');
    final closeHandle = kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    final openProcess = kernel32
        .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
    final queryFullProcessImageName = kernel32
        .lookupFunction<
          _QueryFullProcessImageNameNative,
          _QueryFullProcessImageNameDart
        >('QueryFullProcessImageNameW');

    final snapshot = createToolhelp32Snapshot(_th32csSnapProcess, 0);
    if (snapshot == _invalidHandleValue) {
      throw StateError('CreateToolhelp32Snapshot failed');
    }

    final entry = calloc<_ProcessEntry32W>();
    try {
      entry.ref.dwSize = sizeOf<_ProcessEntry32W>();
      if (process32First(snapshot, entry) == 0) {
        return const <_WindowsProcessInfo>[];
      }

      final processes = <_WindowsProcessInfo>[];
      do {
        final pid = entry.ref.th32ProcessID;
        processes.add(
          _WindowsProcessInfo(
            pid: pid,
            parentPid: entry.ref.th32ParentProcessID,
            path: _queryWindowsProcessImagePath(
              pid,
              openProcess: openProcess,
              queryFullProcessImageName: queryFullProcessImageName,
              closeHandle: closeHandle,
            ),
          ),
        );
      } while (process32Next(snapshot, entry) != 0);
      final snapshotProcesses = List<_WindowsProcessInfo>.unmodifiable(
        processes,
      );
      _windowsProcessSnapshotCache = _WindowsProcessSnapshotCacheEntry(
        createdAt: now,
        processes: snapshotProcesses,
      );
      return snapshotProcesses;
    } finally {
      calloc.free(entry);
      closeHandle(snapshot);
    }
  }

  String? _queryWindowsProcessImagePath(
    int pid, {
    required _OpenProcessDart openProcess,
    required _QueryFullProcessImageNameDart queryFullProcessImageName,
    required _CloseHandleDart closeHandle,
  }) {
    if (pid <= 0) {
      return null;
    }

    final process = openProcess(_processQueryLimitedInformation, 0, pid);
    if (process == 0) {
      return null;
    }

    final buffer = calloc<Uint16>(_maxWindowsPathBufferChars);
    final length = calloc<Uint32>();
    try {
      length.value = _maxWindowsPathBufferChars;
      final ok = queryFullProcessImageName(process, 0, buffer, length);
      if (ok == 0 || length.value == 0) {
        return null;
      }
      return String.fromCharCodes(buffer.asTypedList(length.value)).trim();
    } finally {
      calloc.free(length);
      calloc.free(buffer);
      closeHandle(process);
    }
  }

  String _windowsPathKey(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return p.normalize(trimmed).toLowerCase();
  }

  Future<void> _installTemporaryXrayTunRoutes({
    required String interfaceAlias,
    required TunIpMode tunIpMode,
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    if (_temporaryTunRoutes.isNotEmpty) {
      await _removeTemporaryTunRoutes();
    }

    final adapterKey = _xrayTunAdapterKey(interfaceAlias, tunIpMode);
    var setupKind = _WindowsTunSetupKind.full;
    var setup = await _prepareWindowsXrayTunFastRoutes(
      interfaceAlias: interfaceAlias,
      tunIpMode: tunIpMode,
    );
    if (setup != null) {
      setupKind =
          setup.fastConfigureMethod == _WindowsTunFastConfigureMethod.nativeApi
          ? _WindowsTunSetupKind.fastNativeApi
          : _WindowsTunSetupKind.fastNetsh;
    } else {
      setup = _preparedXrayTunAdapterKeys.contains(adapterKey)
          ? await _prepareWindowsXrayTunRoutesOnly(
              interfaceAlias: interfaceAlias,
              tunIpMode: tunIpMode,
            )
          : null;
      if (setup != null) {
        setupKind = _WindowsTunSetupKind.routeOnly;
      }
    }
    setup ??= await _prepareWindowsXrayTunAdapterAndRoutes(
      interfaceAlias: interfaceAlias,
      tunIpMode: tunIpMode,
    );
    if (setup == null) {
      throw StateError('Failed to prepare Xray TUN adapter and routes.');
    }

    switch (setupKind) {
      case _WindowsTunSetupKind.fastNativeApi:
        _rememberAppLog(
          'Xray TUN adapter configured with native Windows API setup.',
        );
      case _WindowsTunSetupKind.fastNetsh:
        _rememberAppLog(
          'Xray TUN adapter configured with fast netsh/route.exe setup.',
        );
      case _WindowsTunSetupKind.routeOnly:
        _rememberAppLog(
          'Xray TUN adapter was previously configured; using route-only setup.',
        );
      case _WindowsTunSetupKind.full:
        break;
    }

    _temporaryTunRoutes = List<_WindowsTunRoute>.unmodifiable(setup.routes);
    _preparedXrayTunAdapterKeys.add(adapterKey);
    if (setup.networkChanged) {
      _rememberAppLog(
        'Xray TUN adapter settings changed; Windows may need a moment to settle.',
      );
    } else {
      _rememberAppLog(
        'Xray TUN adapter was already configured; skipping extra readiness waits.',
      );
    }
  }

  String _xrayTunAdapterKey(String interfaceAlias, TunIpMode tunIpMode) {
    return '${interfaceAlias.trim().toLowerCase()}|${tunIpMode.name}';
  }

  Future<_WindowsTunSetup?> _prepareWindowsXrayTunFastRoutes({
    required String interfaceAlias,
    required TunIpMode tunIpMode,
  }) async {
    if (tunIpMode != TunIpMode.ipv4) {
      return null;
    }
    final nativeSetup = await _prepareWindowsXrayTunIpv4RoutesWithNativeApi(
      interfaceAlias: interfaceAlias,
    );
    if (nativeSetup != null) {
      return nativeSetup;
    }

    final adapter = await _waitForNetshIpv4Interface(
      interfaceAlias,
      timeout: const Duration(milliseconds: 2500),
    );
    if (adapter == null) {
      return null;
    }

    var configureMethod = _WindowsTunFastConfigureMethod.nativeApi;
    var configureStopwatch = Stopwatch()..start();
    var configured = await _configureXrayTunIpv4WithNativeApi(adapter);
    configureStopwatch.stop();
    if (!configured) {
      configureMethod = _WindowsTunFastConfigureMethod.netsh;
      configureStopwatch = Stopwatch()..start();
      configured = await _configureXrayTunIpv4WithNetsh(adapter);
      configureStopwatch.stop();
    }
    if (!configured) {
      return null;
    }

    final routes = <_WindowsTunRoute>[
      _WindowsTunRoute(
        destinationPrefix: '0.0.0.0/1',
        interfaceAlias: adapter.name,
        interfaceIndex: adapter.index,
        nextHop: '0.0.0.0',
      ),
      _WindowsTunRoute(
        destinationPrefix: '128.0.0.0/1',
        interfaceAlias: adapter.name,
        interfaceIndex: adapter.index,
        nextHop: '0.0.0.0',
      ),
    ];

    final stopwatch = Stopwatch()..start();
    for (final route in routes) {
      final parts = _routeExeIpv4DestinationParts(route.destinationPrefix);
      if (parts == null) {
        return null;
      }
      final result =
          await _runTimedProcess('route_add_xray_tun', 'route.exe', <String>[
            'ADD',
            parts.address,
            'MASK',
            parts.mask,
            route.nextHop,
            'METRIC',
            '1',
            'IF',
            adapter.index.toString(),
          ]);
      if (result.exitCode != 0 &&
          !_routeOutputSaysAlreadyExists(result.stdout, result.stderr)) {
        _rememberAppLog(
          'Fast Xray TUN route setup unavailable: route add failed with exit ${result.exitCode}: ${_describeError(result.stderr)}',
        );
        return null;
      }
      _rememberAppLog(
        'Xray TUN route ${route.destinationPrefix} via ${route.interfaceAlias} ${result.exitCode == 0 ? 'created' : 'already existed'}.',
      );
    }
    stopwatch.stop();

    _rememberAppLog(
      'Xray TUN adapter ready: interface=${adapter.name}, ifIndex=${adapter.index}, status=${adapter.status}.',
    );
    _rememberAppLog(
      'Xray TUN adapter setup timing: ${configureMethod.timingLabel}=${configureStopwatch.elapsedMilliseconds}ms, route_exe=${stopwatch.elapsedMilliseconds}ms.',
    );
    _rememberAppLog(
      'Configured Xray TUN adapter DNS/IP settings: ipv4-address=172.19.0.1/30, ipv4-metric=1, dns=1.1.1.1,8.8.8.8.',
    );

    return _WindowsTunSetup(
      routes: routes,
      networkChanged: false,
      fastConfigureMethod: configureMethod,
    );
  }

  Future<_WindowsTunSetup?> _prepareWindowsXrayTunIpv4RoutesWithNativeApi({
    required String interfaceAlias,
  }) async {
    Object? rawResult;
    try {
      rawResult = await _windowsTunChannel
          .invokeMethod<Object?>('prepareXrayTunIpv4Routes', <String, Object?>{
            'interfaceAlias': interfaceAlias,
            'timeoutMs': 2500,
            'address': '172.19.0.1',
            'prefixLength': 30,
            'metric': 1,
            'dnsServers': '1.1.1.1,8.8.8.8',
          });
    } on MissingPluginException {
      _rememberAppLog(
        'Native Xray TUN IPv4 route setup unavailable: Windows runner channel is not registered.',
      );
      return null;
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Native Xray TUN IPv4 route setup unavailable: ${error.message ?? error.code}',
      );
      return null;
    } catch (error) {
      _rememberAppLog(
        'Native Xray TUN IPv4 route setup unavailable: ${_describeError(error)}',
      );
      return null;
    }

    if (rawResult is! Map) {
      _rememberAppLog(
        'Native Xray TUN IPv4 route setup unavailable: runner returned unexpected result.',
      );
      return null;
    }

    final result = rawResult.cast<Object?, Object?>();
    final elapsedMs = result['elapsedMs']?.toString();
    if (result['ok'] != true) {
      final failedStep = result['failedStep']?.toString() ?? 'unknown';
      final routePrefix = result['routePrefix']?.toString();
      final error = result['error']?.toString() ?? 'unknown error';
      final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
      final target = routePrefix == null
          ? failedStep
          : '$failedStep $routePrefix';
      _rememberAppLog(
        'Native Xray TUN IPv4 route setup unavailable: $target failed$elapsed: $error',
      );
      return null;
    }

    final alias = result['interfaceAlias']?.toString().trim();
    final index = (result['interfaceIndex'] as num?)?.toInt();
    if (alias == null || alias.isEmpty || index == null || index <= 0) {
      _rememberAppLog(
        'Native Xray TUN IPv4 route setup unavailable: runner returned incomplete adapter details.',
      );
      return null;
    }

    final routeItems = result['routes'] is List
        ? result['routes'] as List
        : const <dynamic>[];
    final routes = <_WindowsTunRoute>[];
    for (final item in routeItems) {
      if (item is! Map) {
        continue;
      }
      final destinationPrefix = item['DestinationPrefix']?.toString().trim();
      final nextHop = item['NextHop']?.toString().trim();
      if (destinationPrefix == null ||
          destinationPrefix.isEmpty ||
          nextHop == null ||
          nextHop.isEmpty) {
        continue;
      }
      final route = _WindowsTunRoute(
        destinationPrefix: destinationPrefix,
        interfaceAlias: alias,
        interfaceIndex: index,
        nextHop: nextHop,
      );
      routes.add(route);
      final status = item['Status']?.toString();
      _rememberAppLog(
        'Xray TUN route ${route.destinationPrefix} via ${route.interfaceAlias} ${status == 'created' ? 'created' : 'already existed'}.',
      );
    }
    if (routes.isEmpty) {
      _rememberAppLog(
        'Native Xray TUN IPv4 route setup unavailable: runner returned no routes.',
      );
      return null;
    }

    _rememberAppLog(
      'Xray TUN adapter ready: interface=$alias, ifIndex=$index, status=${result['status']}.',
    );
    _rememberAppLog(
      'Xray TUN adapter setup timing: native_prepare=${_orDash(elapsedMs)}ms, wait_adapter=${_orDash(result['waitMs']?.toString())}ms, native_configure=${_orDash(result['configureMs']?.toString())}ms, native_routes=${_orDash(result['routeMs']?.toString())}ms.',
    );
    _rememberAppLog(
      'Configured Xray TUN adapter DNS/IP settings: ipv4-address=172.19.0.1/30 (${result['addressStatus']}), ipv4-metric=1 (${result['metricStatus']}), dns=1.1.1.1,8.8.8.8 (${result['dnsStatus']}).',
    );

    return _WindowsTunSetup(
      routes: routes,
      networkChanged: false,
      fastConfigureMethod: _WindowsTunFastConfigureMethod.nativeApi,
    );
  }

  Future<bool> _configureXrayTunIpv4WithNativeApi(
    _NetshIpv4Interface adapter,
  ) async {
    if (!Platform.isWindows) {
      return false;
    }

    Object? rawResult;
    try {
      rawResult = await _windowsTunChannel
          .invokeMethod<Object?>('configureXrayTunIpv4', <String, Object?>{
            'interfaceIndex': adapter.index,
            'address': '172.19.0.1',
            'prefixLength': 30,
            'metric': 1,
            'dnsServers': '1.1.1.1,8.8.8.8',
          });
    } on MissingPluginException {
      _rememberAppLog(
        'Native Xray TUN IPv4 setup unavailable: Windows runner channel is not registered.',
      );
      return false;
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Native Xray TUN IPv4 setup unavailable: ${error.message ?? error.code}',
      );
      return false;
    } catch (error) {
      _rememberAppLog(
        'Native Xray TUN IPv4 setup unavailable: ${_describeError(error)}',
      );
      return false;
    }

    if (rawResult is! Map) {
      _rememberAppLog(
        'Native Xray TUN IPv4 setup unavailable: runner returned unexpected result.',
      );
      return false;
    }

    final result = rawResult.cast<Object?, Object?>();
    final elapsedMs = result['elapsedMs']?.toString();
    if (result['ok'] != true) {
      final failedStep = result['failedStep']?.toString() ?? 'unknown';
      final error = result['error']?.toString() ?? 'unknown error';
      final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
      _rememberAppLog(
        'Native Xray TUN IPv4 setup unavailable: $failedStep failed$elapsed: $error',
      );
      return false;
    }

    _rememberAppLog(
      'Native Xray TUN IPv4 configure${elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms'}: ipv4-address=${result['addressStatus']}, ipv4-metric=${result['metricStatus']}, dns=${result['dnsStatus']}.',
    );
    return true;
  }

  Future<bool> _configureXrayTunIpv4WithNetsh(
    _NetshIpv4Interface adapter,
  ) async {
    final commands = <({String label, List<String> args})>[
      (
        label: 'netsh_xray_tun_ipv4_set_address',
        args: <String>[
          'interface',
          'ipv4',
          'set',
          'address',
          'name=${adapter.name}',
          'source=static',
          'address=172.19.0.1',
          'mask=255.255.255.252',
          'gateway=none',
          'store=active',
        ],
      ),
      (
        label: 'netsh_xray_tun_ipv4_set_metric',
        args: <String>[
          'interface',
          'ipv4',
          'set',
          'interface',
          'interface=${adapter.name}',
          'metric=1',
          'store=active',
        ],
      ),
      (
        label: 'netsh_xray_tun_ipv4_set_dns',
        args: <String>[
          'interface',
          'ipv4',
          'set',
          'dnsservers',
          'name=${adapter.name}',
          'source=static',
          'address=1.1.1.1',
          'register=none',
          'validate=no',
        ],
      ),
      (
        label: 'netsh_xray_tun_ipv4_add_dns',
        args: <String>[
          'interface',
          'ipv4',
          'add',
          'dnsservers',
          'name=${adapter.name}',
          'address=8.8.8.8',
          'index=2',
          'validate=no',
        ],
      ),
    ];

    for (final command in commands) {
      final result = await _runTimedProcess(
        command.label,
        'netsh.exe',
        command.args,
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Fast Xray TUN route setup unavailable: ${command.label} failed with exit ${result.exitCode}: ${_describeError(result.stderr)}',
        );
        return false;
      }
    }
    return true;
  }

  Future<_NetshIpv4Interface?> _waitForNetshIpv4Interface(
    String interfaceAlias, {
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      final result = await _runTimedProcess(
        'netsh_ipv4_interfaces',
        'netsh.exe',
        <String>['interface', 'ipv4', 'show', 'interfaces'],
      );
      if (result.exitCode == 0) {
        final adapter = _parseNetshIpv4Interface(
          result.stdout.toString(),
          interfaceAlias,
        );
        if (adapter != null) {
          return adapter;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _rememberAppLog(
      'Fast Xray TUN route setup unavailable: adapter $interfaceAlias was not visible through netsh in ${timeout.inMilliseconds}ms.',
    );
    return null;
  }

  _NetshIpv4Interface? _parseNetshIpv4Interface(
    String netshOutput,
    String interfaceAlias,
  ) {
    final target = interfaceAlias.trim().toLowerCase();
    final linePattern = RegExp(
      r'^\s*(\d+)\s+\d+\s+\d+\s+(\S+)\s+(.+?)\s*$',
      caseSensitive: false,
    );
    for (final line in const LineSplitter().convert(netshOutput)) {
      final match = linePattern.firstMatch(line);
      if (match == null) {
        continue;
      }
      final name = match.group(3)?.trim();
      if (name == null || name.toLowerCase() != target) {
        continue;
      }
      final index = int.tryParse(match.group(1) ?? '');
      if (index == null || index <= 0) {
        continue;
      }
      return _NetshIpv4Interface(
        index: index,
        name: name,
        status: match.group(2)?.trim() ?? '',
      );
    }
    return null;
  }

  Future<_WindowsTunSetup?> _prepareWindowsXrayTunRoutesOnly({
    required String interfaceAlias,
    required TunIpMode tunIpMode,
  }) async {
    const script = r'''
param(
  [string]$InterfaceAlias,
  [int]$TimeoutMs,
  [string]$TunIpMode
)
try {
  $timings = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $routeResults = New-Object System.Collections.Generic.List[object]

  $waitTimer = [System.Diagnostics.Stopwatch]::StartNew()
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  $adapter = $null
  do {
    $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue
    if ($null -ne $adapter) {
      break
    }
    Start-Sleep -Milliseconds 25
  } while ((Get-Date) -lt $deadline)
  $waitTimer.Stop()
  $timings.Add("wait_adapter=$($waitTimer.ElapsedMilliseconds)ms")
  if ($null -eq $adapter) {
    Write-Error "adapter not found in time"
    exit 2
  }
  $InterfaceIndex = [int]$adapter.ifIndex

  $routeTimer = [System.Diagnostics.Stopwatch]::StartNew()
  $routes = @()
  if ($TunIpMode -eq 'ipv4' -or $TunIpMode -eq 'dualStack') {
    $routes += [PSCustomObject]@{
      DestinationPrefix = '0.0.0.0/1'
      NextHop = '0.0.0.0'
    }
    $routes += [PSCustomObject]@{
      DestinationPrefix = '128.0.0.0/1'
      NextHop = '0.0.0.0'
    }
  }
  if ($TunIpMode -eq 'ipv6' -or $TunIpMode -eq 'dualStack') {
    $routes += [PSCustomObject]@{
      DestinationPrefix = '::/1'
      NextHop = '::'
    }
    $routes += [PSCustomObject]@{
      DestinationPrefix = '8000::/1'
      NextHop = '::'
    }
  }

  foreach ($route in $routes) {
    try {
      $destinationPrefix = [string]$route.DestinationPrefix
      $nextHop = [string]$route.NextHop
      $existing = Get-NetRoute -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
        Where-Object {
          $_.InterfaceIndex -eq $InterfaceIndex -and
          $_.NextHop -eq $nextHop
        } |
        Select-Object -First 1

      $status = 'exists'
      if ($null -eq $existing) {
        New-NetRoute `
          -DestinationPrefix $destinationPrefix `
          -InterfaceIndex $InterfaceIndex `
          -NextHop $nextHop `
          -RouteMetric 1 `
          -PolicyStore ActiveStore | Out-Null
        $status = 'created'
      }
      $routeResults.Add([PSCustomObject]@{
        DestinationPrefix = $destinationPrefix
        NextHop = $nextHop
        Status = $status
      })
    } catch {
      $warnings.Add("Route $([string]$route.DestinationPrefix): $($_.Exception.Message)")
      $routeResults.Add([PSCustomObject]@{
        DestinationPrefix = [string]$route.DestinationPrefix
        NextHop = [string]$route.NextHop
        Status = 'failed'
      })
    }
  }
  $routeTimer.Stop()
  $timings.Add("install_routes=$($routeTimer.ElapsedMilliseconds)ms")

  [PSCustomObject]@{
    Adapter = [PSCustomObject]@{
      InterfaceAlias = [string]$adapter.Name
      InterfaceIndex = [int]$adapter.ifIndex
      Status = [string]$adapter.Status
    }
    Changes = @('route-only')
    Warnings = $warnings.ToArray()
    NetworkChanged = $false
    Routes = $routeResults.ToArray()
    Timings = $timings.ToArray()
  } | ConvertTo-Json -Depth 4 -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    final result = await _runPowerShellScript(
      script,
      label: 'xray_tun_route_only',
      namedArgs: <String, String>{
        'InterfaceAlias': interfaceAlias,
        'TimeoutMs': '2500',
        'TunIpMode': tunIpMode.name,
      },
    );
    if (result.exitCode != 0) {
      _rememberAppLog(
        'Failed to prepare Xray TUN route-only setup: ${_describeError(result.stderr)}',
      );
      return null;
    }
    return _decodeWindowsXrayTunSetup(
      result.stdout.toString().trim(),
      unexpectedOutputContext: 'Prepared Xray TUN route-only setup',
    );
  }

  _WindowsTunSetup? _decodeWindowsXrayTunSetup(
    String output, {
    required String unexpectedOutputContext,
  }) {
    if (output.isEmpty) {
      _rememberAppLog(
        '$unexpectedOutputContext, but PowerShell returned no details.',
      );
      return null;
    }
    final decoded = jsonDecode(output);
    if (decoded is! Map<String, dynamic>) {
      _rememberAppLog(
        '$unexpectedOutputContext, but output was unexpected: "$output".',
      );
      return null;
    }
    final adapter = (decoded['Adapter'] as Map?)?.cast<String, dynamic>();
    final alias = adapter?['InterfaceAlias']?.toString().trim();
    final index = (adapter?['InterfaceIndex'] as num?)?.toInt();
    if (alias == null || alias.isEmpty || index == null || index <= 0) {
      _rememberAppLog(
        '$unexpectedOutputContext, but adapter details were incomplete: "$output".',
      );
      return null;
    }

    final timings = (decoded['Timings'] as List?)
        ?.map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .join(', ');
    _rememberAppLog(
      'Xray TUN adapter ready: interface=$alias, ifIndex=$index, status=${adapter?['Status']}.',
    );
    if (timings != null && timings.trim().isNotEmpty) {
      _rememberAppLog('Xray TUN adapter setup timing: $timings.');
    }

    final changes = (decoded['Changes'] as List?)
        ?.map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .join(', ');
    final warnings = (decoded['Warnings'] as List?)
        ?.map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .join('; ');
    _rememberAppLog(
      'Configured Xray TUN adapter DNS/IP settings: ${_orDash(changes)}.',
    );
    if (warnings != null && warnings.trim().isNotEmpty) {
      _rememberAppLog(
        'Xray TUN adapter DNS/IP configuration warnings: $warnings',
      );
    }
    final routeItems = decoded['Routes'] is List
        ? decoded['Routes'] as List
        : decoded['Routes'] == null
        ? const <dynamic>[]
        : <dynamic>[decoded['Routes']];
    final routes = <_WindowsTunRoute>[];
    for (final item in routeItems) {
      if (item is! Map) {
        continue;
      }
      final destinationPrefix = item['DestinationPrefix']?.toString().trim();
      final nextHop = item['NextHop']?.toString().trim();
      if (destinationPrefix == null ||
          destinationPrefix.isEmpty ||
          nextHop == null ||
          nextHop.isEmpty) {
        continue;
      }
      final route = _WindowsTunRoute(
        destinationPrefix: destinationPrefix,
        interfaceAlias: alias,
        interfaceIndex: index,
        nextHop: nextHop,
      );
      final status = item['Status']?.toString();
      if (status != 'failed') {
        routes.add(route);
      }
      _rememberAppLog(
        'Xray TUN route ${route.destinationPrefix} via ${route.interfaceAlias} ${status == 'created'
            ? 'created'
            : status == 'failed'
            ? 'could not be installed'
            : 'already existed'}.',
      );
    }

    if (routes.isEmpty) {
      _rememberAppLog(
        'Prepared Xray TUN adapter, but no temporary routes were installed by the app.',
      );
    }

    return _WindowsTunSetup(
      routes: routes,
      networkChanged: decoded['NetworkChanged'] == true,
    );
  }

  Future<_WindowsTunSetup?> _prepareWindowsXrayTunAdapterAndRoutes({
    required String interfaceAlias,
    required TunIpMode tunIpMode,
  }) async {
    const script = r'''
param(
  [string]$InterfaceAlias,
  [int]$TimeoutMs,
  [string]$TunIpMode
)
try {
  $timings = New-Object System.Collections.Generic.List[string]
  $changes = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $routeResults = New-Object System.Collections.Generic.List[object]
  $networkChanged = $false

  $waitTimer = [System.Diagnostics.Stopwatch]::StartNew()
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  $adapter = $null
  do {
    $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue
    if ($null -ne $adapter) {
      break
    }
    Start-Sleep -Milliseconds 50
  } while ((Get-Date) -lt $deadline)
  $waitTimer.Stop()
  $timings.Add("wait_adapter=$($waitTimer.ElapsedMilliseconds)ms")
  if ($null -eq $adapter) {
    Write-Error "adapter not found in time"
    exit 2
  }
  $InterfaceIndex = [int]$adapter.ifIndex

  $configureTimer = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $binding = Get-NetAdapterBinding `
      -Name $adapter.Name `
      -ComponentID ms_tcpip6 `
      -ErrorAction SilentlyContinue
    if ($null -ne $binding -and -not $binding.Enabled) {
      Enable-NetAdapterBinding `
        -Name $adapter.Name `
        -ComponentID ms_tcpip6 `
        -ErrorAction Stop
      $changes.Add('ipv6-binding=re-enabled')
      $networkChanged = $true
    } elseif ($null -ne $binding) {
      $changes.Add('ipv6-binding=enabled')
    }
  } catch {
    $warnings.Add("IPv6 binding: $($_.Exception.Message)")
  }

  if ($TunIpMode -eq 'ipv4' -or $TunIpMode -eq 'dualStack') {
    try {
      $existing = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq '172.19.0.1' })
      if ($existing.Count -eq 0) {
        $usable = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) -and
            [string]$_.IPAddress -notlike '169.254.*'
          })
        if ($usable.Count -eq 0) {
          New-NetIPAddress `
            -InterfaceIndex $InterfaceIndex `
            -IPAddress '172.19.0.1' `
            -PrefixLength 30 `
            -AddressFamily IPv4 `
            -ErrorAction Stop | Out-Null
          $changes.Add('ipv4-address=172.19.0.1/30')
          $networkChanged = $true
        } else {
          $changes.Add('ipv4-address=existing')
        }
      } else {
        $changes.Add('ipv4-address=already-set')
      }
    } catch {
      $warnings.Add("IPv4 address: $($_.Exception.Message)")
    }

    try {
      $ipInterface = Get-NetIPInterface `
        -InterfaceIndex $InterfaceIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
      if ($null -eq $ipInterface -or [int]$ipInterface.InterfaceMetric -ne 1) {
        Set-NetIPInterface `
          -InterfaceIndex $InterfaceIndex `
          -AddressFamily IPv4 `
          -InterfaceMetric 1 `
          -ErrorAction Stop
        $changes.Add('ipv4-metric=1')
        $networkChanged = $true
      } else {
        $changes.Add('ipv4-metric=already-1')
      }
    } catch {
      $warnings.Add("IPv4 metric: $($_.Exception.Message)")
    }
  }

  if ($TunIpMode -eq 'ipv6' -or $TunIpMode -eq 'dualStack') {
    try {
      $existing = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq 'fd7a:115c:a1e0::1' })
      if ($existing.Count -eq 0) {
        New-NetIPAddress `
          -InterfaceIndex $InterfaceIndex `
          -IPAddress 'fd7a:115c:a1e0::1' `
          -PrefixLength 64 `
          -AddressFamily IPv6 `
          -ErrorAction Stop | Out-Null
        $changes.Add('ipv6-address=fd7a:115c:a1e0::1/64')
        $networkChanged = $true
      } else {
        $changes.Add('ipv6-address=already-set')
      }
    } catch {
      $warnings.Add("IPv6 address: $($_.Exception.Message)")
    }

  }

  try {
    $dnsServers = @()
    if ($TunIpMode -eq 'ipv4') {
      $dnsServers = @('1.1.1.1', '8.8.8.8')
    } elseif ($TunIpMode -eq 'dualStack') {
      $dnsServers = @(
        '1.1.1.1',
        '8.8.8.8',
        '2606:4700:4700::1111',
        '2001:4860:4860::8888'
      )
    } else {
      $dnsServers = @('2606:4700:4700::1111', '2001:4860:4860::8888')
    }
    $currentDns = @(
      Get-DnsClientServerAddress `
        -InterfaceIndex $InterfaceIndex `
        -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ServerAddresses } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $currentKey = @($currentDns | Sort-Object) -join '|'
    $targetKey = @($dnsServers | Sort-Object) -join '|'
    if ($currentKey -ne $targetKey) {
      Set-DnsClientServerAddress `
        -InterfaceIndex $InterfaceIndex `
        -ServerAddresses $dnsServers `
        -ErrorAction Stop
      $changes.Add("dns=$($dnsServers -join ',')")
      $networkChanged = $true
    } else {
      $changes.Add('dns=already-set')
    }
  } catch {
    $warnings.Add("DNS servers: $($_.Exception.Message)")
  }

  if ($networkChanged) {
    try {
      Clear-DnsClientCache
      $changes.Add('dns-cache=cleared')
    } catch {
      $warnings.Add("DNS cache: $($_.Exception.Message)")
    }
  }
  $configureTimer.Stop()
  $timings.Add("configure_adapter=$($configureTimer.ElapsedMilliseconds)ms")

  $routeTimer = [System.Diagnostics.Stopwatch]::StartNew()
  $routes = @()
  if ($TunIpMode -eq 'ipv4' -or $TunIpMode -eq 'dualStack') {
    $routes += [PSCustomObject]@{
      DestinationPrefix = '0.0.0.0/1'
      NextHop = '0.0.0.0'
    }
    $routes += [PSCustomObject]@{
      DestinationPrefix = '128.0.0.0/1'
      NextHop = '0.0.0.0'
    }
  }
  if ($TunIpMode -eq 'ipv6' -or $TunIpMode -eq 'dualStack') {
    $routes += [PSCustomObject]@{
      DestinationPrefix = '::/1'
      NextHop = '::'
    }
    $routes += [PSCustomObject]@{
      DestinationPrefix = '8000::/1'
      NextHop = '::'
    }
  }

  foreach ($route in $routes) {
    try {
      $destinationPrefix = [string]$route.DestinationPrefix
      $nextHop = [string]$route.NextHop
      $existing = Get-NetRoute -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
        Where-Object {
          $_.InterfaceIndex -eq $InterfaceIndex -and
          $_.NextHop -eq $nextHop
        } |
        Select-Object -First 1

      $status = 'exists'
      if ($null -eq $existing) {
        New-NetRoute `
          -DestinationPrefix $destinationPrefix `
          -InterfaceIndex $InterfaceIndex `
          -NextHop $nextHop `
          -RouteMetric 1 `
          -PolicyStore ActiveStore | Out-Null
        $status = 'created'
      }
      $routeResults.Add([PSCustomObject]@{
        DestinationPrefix = $destinationPrefix
        NextHop = $nextHop
        Status = $status
      })
    } catch {
      $warnings.Add("Route $([string]$route.DestinationPrefix): $($_.Exception.Message)")
      $routeResults.Add([PSCustomObject]@{
        DestinationPrefix = [string]$route.DestinationPrefix
        NextHop = [string]$route.NextHop
        Status = 'failed'
      })
    }
  }
  $routeTimer.Stop()
  $timings.Add("install_routes=$($routeTimer.ElapsedMilliseconds)ms")

  [PSCustomObject]@{
    Adapter = [PSCustomObject]@{
      InterfaceAlias = [string]$adapter.Name
      InterfaceIndex = [int]$adapter.ifIndex
      Status = [string]$adapter.Status
    }
    Changes = $changes.ToArray()
    Warnings = $warnings.ToArray()
    NetworkChanged = [bool]$networkChanged
    Routes = $routeResults.ToArray()
    Timings = $timings.ToArray()
  } | ConvertTo-Json -Depth 4 -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final result = await _runPowerShellScript(
        script,
        label: 'xray_tun_adapter_routes',
        namedArgs: <String, String>{
          'InterfaceAlias': interfaceAlias,
          'TimeoutMs': '7000',
          'TunIpMode': tunIpMode.name,
        },
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to prepare Xray TUN adapter and routes: ${_describeError(result.stderr)}',
        );
        return null;
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        _rememberAppLog(
          'Prepared Xray TUN adapter and routes, but PowerShell returned no details.',
        );
        return null;
      }
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic>) {
        _rememberAppLog(
          'Prepared Xray TUN adapter and routes, but output was unexpected: "$output".',
        );
        return null;
      }
      final adapter = (decoded['Adapter'] as Map?)?.cast<String, dynamic>();
      final alias = adapter?['InterfaceAlias']?.toString().trim();
      final index = (adapter?['InterfaceIndex'] as num?)?.toInt();
      if (alias == null || alias.isEmpty || index == null || index <= 0) {
        _rememberAppLog(
          'Prepared Xray TUN adapter and routes, but adapter details were incomplete: "$output".',
        );
        return null;
      }

      final timings = (decoded['Timings'] as List?)
          ?.map((value) => value.toString())
          .where((value) => value.trim().isNotEmpty)
          .join(', ');
      _rememberAppLog(
        'Xray TUN adapter ready: interface=$alias, ifIndex=$index, status=${adapter?['Status']}.',
      );
      if (timings != null && timings.trim().isNotEmpty) {
        _rememberAppLog('Xray TUN adapter setup timing: $timings.');
      }

      final changes = (decoded['Changes'] as List?)
          ?.map((value) => value.toString())
          .where((value) => value.trim().isNotEmpty)
          .join(', ');
      final warnings = (decoded['Warnings'] as List?)
          ?.map((value) => value.toString())
          .where((value) => value.trim().isNotEmpty)
          .join('; ');
      _rememberAppLog(
        'Configured Xray TUN adapter DNS/IP settings: ${_orDash(changes)}.',
      );
      if (warnings != null && warnings.trim().isNotEmpty) {
        _rememberAppLog(
          'Xray TUN adapter DNS/IP configuration warnings: $warnings',
        );
      }
      final routeItems = decoded['Routes'] is List
          ? decoded['Routes'] as List
          : decoded['Routes'] == null
          ? const <dynamic>[]
          : <dynamic>[decoded['Routes']];
      final routes = <_WindowsTunRoute>[];
      for (final item in routeItems) {
        if (item is! Map) {
          continue;
        }
        final destinationPrefix = item['DestinationPrefix']?.toString().trim();
        final nextHop = item['NextHop']?.toString().trim();
        if (destinationPrefix == null ||
            destinationPrefix.isEmpty ||
            nextHop == null ||
            nextHop.isEmpty) {
          continue;
        }
        final route = _WindowsTunRoute(
          destinationPrefix: destinationPrefix,
          interfaceAlias: alias,
          interfaceIndex: index,
          nextHop: nextHop,
        );
        final status = item['Status']?.toString();
        if (status != 'failed') {
          routes.add(route);
        }
        _rememberAppLog(
          'Xray TUN route ${route.destinationPrefix} via ${route.interfaceAlias} ${status == 'created'
              ? 'created'
              : status == 'failed'
              ? 'could not be installed'
              : 'already existed'}.',
        );
      }

      if (routes.isEmpty) {
        _rememberAppLog(
          'Prepared Xray TUN adapter, but no temporary routes were installed by the app.',
        );
      }

      return _WindowsTunSetup(
        routes: routes,
        networkChanged: decoded['NetworkChanged'] == true,
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to prepare Xray TUN adapter and routes: ${_describeError(error)}',
      );
      return null;
    }
  }

  Future<void> _removeTemporaryServerRoute({
    List<_WindowsHostRoute>? routes,
  }) async {
    final rawRoutesToRemove = routes ?? _temporaryServerRoutes;
    if (routes == null) {
      _temporaryServerRoutes = const <_WindowsHostRoute>[];
    }
    final routesToRemove = rawRoutesToRemove
        .where((route) => route.removeWhenUnused)
        .toList(growable: false);
    if (routesToRemove.isEmpty) {
      return;
    }

    final nativeRoutes = routesToRemove
        .where(
          (route) => _canRemoveWithNativeIpv4RouteApi(
            destinationPrefix: route.destinationPrefix,
            interfaceIndex: route.interfaceIndex,
            nextHop: route.nextHop,
          ),
        )
        .map(
          (route) => (
            destinationPrefix: route.destinationPrefix,
            interfaceIndex: route.interfaceIndex,
            nextHop: route.nextHop,
          ),
        )
        .toList(growable: false);
    final nativeRemovedKeys = nativeRoutes.isEmpty
        ? <String>{}
        : await _removeNativeIpv4Routes(
                nativeRoutes,
                label: 'remove_server_routes',
              ) ??
              <String>{};
    for (final route in routesToRemove) {
      if (nativeRemovedKeys.contains(
        _routeRemovalKey(
          destinationPrefix: route.destinationPrefix,
          interfaceIndex: route.interfaceIndex,
          nextHop: route.nextHop,
        ),
      )) {
        _rememberAppLog(
          'Temporary host route ${route.destinationPrefix} removed.',
        );
      }
    }

    final routesForFallback = routesToRemove
        .where(
          (route) => !nativeRemovedKeys.contains(
            _routeRemovalKey(
              destinationPrefix: route.destinationPrefix,
              interfaceIndex: route.interfaceIndex,
              nextHop: route.nextHop,
            ),
          ),
        )
        .toList(growable: false);

    final routeExeRoutes = routesForFallback
        .where(
          (route) => route.removalTool == _WindowsRouteRemovalTool.routeExe,
        )
        .toList(growable: false);
    if (routeExeRoutes.isNotEmpty) {
      await _removeRouteExeServerRoutes(routeExeRoutes);
    }

    final powerShellRoutes = routesForFallback
        .where(
          (route) => route.removalTool == _WindowsRouteRemovalTool.powerShell,
        )
        .toList(growable: false);
    if (powerShellRoutes.isEmpty) {
      return;
    }

    const script = r'''
param([string]$RoutesBase64)
try {
  $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($RoutesBase64))
  $routes = $json | ConvertFrom-Json
  if ($null -eq $routes) {
    $routes = @()
  } elseif ($routes -isnot [System.Array]) {
    $routes = @($routes)
  }
  foreach ($route in $routes) {
    $destinationPrefix = [string]$route.destinationPrefix
    $interfaceIndex = [int]$route.interfaceIndex
    $nextHop = [string]$route.nextHop
    Get-NetRoute -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
      Where-Object {
        $_.InterfaceIndex -eq $interfaceIndex -and
        $_.NextHop -eq $nextHop
      } |
      Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  }
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      await _runPowerShellScript(
        script,
        label: 'remove_server_routes',
        namedArgs: <String, String>{
          'RoutesBase64': base64Encode(
            utf8.encode(_hostRoutesJson(powerShellRoutes)),
          ),
        },
      );
      for (final route in powerShellRoutes.reversed) {
        _rememberAppLog(
          'Temporary host route ${route.destinationPrefix} removed.',
        );
      }
    } catch (error) {
      _rememberAppLog(
        'Failed to remove temporary host routes: ${_describeError(error)}',
      );
    }
  }

  Future<Set<String>?> _removeNativeIpv4Routes(
    List<({String destinationPrefix, int interfaceIndex, String nextHop})>
    routes, {
    required String label,
  }) async {
    Object? rawResult;
    try {
      rawResult = await _windowsTunChannel.invokeMethod<Object?>(
        'removeIpv4Routes',
        <String, Object?>{
          'routes': routes
              .map(
                (route) => <String, Object?>{
                  'destinationPrefix': route.destinationPrefix,
                  'interfaceIndex': route.interfaceIndex,
                  'nextHop': route.nextHop,
                },
              )
              .toList(growable: false),
        },
      );
    } on MissingPluginException {
      _rememberAppLog(
        'Native IPv4 route cleanup unavailable: Windows runner channel is not registered.',
      );
      return null;
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Native IPv4 route cleanup unavailable: ${error.message ?? error.code}',
      );
      return null;
    } catch (error) {
      _rememberAppLog(
        'Native IPv4 route cleanup unavailable: ${_describeError(error)}',
      );
      return null;
    }

    if (rawResult is! Map) {
      _rememberAppLog(
        'Native IPv4 route cleanup unavailable: runner returned unexpected result.',
      );
      return null;
    }

    final result = rawResult.cast<Object?, Object?>();
    final elapsedMs = result['elapsedMs']?.toString();
    if (result['ok'] != true) {
      final failedStep = result['failedStep']?.toString() ?? 'unknown';
      final error = result['error']?.toString() ?? 'unknown error';
      final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
      _rememberAppLog(
        'Native IPv4 route cleanup unavailable: $failedStep failed$elapsed: $error',
      );
      return null;
    }

    _rememberAppLog(
      'Native IPv4 route cleanup $label${elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms'}.',
    );
    final handledKeys = <String>{};
    final routeItems = result['routes'] is List
        ? result['routes'] as List
        : const <dynamic>[];
    for (final item in routeItems) {
      if (item is! Map) {
        continue;
      }
      final destinationPrefix = item['DestinationPrefix']?.toString().trim();
      final nextHop = item['NextHop']?.toString().trim();
      final interfaceIndex = (item['InterfaceIndex'] as num?)?.toInt();
      if (destinationPrefix == null ||
          destinationPrefix.isEmpty ||
          nextHop == null ||
          nextHop.isEmpty ||
          interfaceIndex == null) {
        continue;
      }

      final status = item['Status']?.toString();
      if (status == 'removed' || status == 'missing') {
        handledKeys.add(
          _routeRemovalKey(
            destinationPrefix: destinationPrefix,
            interfaceIndex: interfaceIndex,
            nextHop: nextHop,
          ),
        );
      } else if (status == 'failed') {
        _rememberAppLog(
          'Native IPv4 route cleanup could not remove $destinationPrefix: ${_describeError(item['Error'] ?? 'unknown error')}',
        );
      }
    }
    return handledKeys;
  }

  bool _canRemoveWithNativeIpv4RouteApi({
    required String destinationPrefix,
    required int interfaceIndex,
    required String nextHop,
  }) {
    if (!Platform.isWindows || interfaceIndex <= 0) {
      return false;
    }

    final parts = destinationPrefix.split('/');
    if (parts.length != 2) {
      return false;
    }
    final destination = InternetAddress.tryParse(parts[0]);
    final prefixLength = int.tryParse(parts[1]);
    final gateway = InternetAddress.tryParse(nextHop);
    return destination?.type == InternetAddressType.IPv4 &&
        prefixLength != null &&
        prefixLength >= 0 &&
        prefixLength <= 32 &&
        gateway?.type == InternetAddressType.IPv4;
  }

  String _routeRemovalKey({
    required String destinationPrefix,
    required int interfaceIndex,
    required String nextHop,
  }) {
    return '$destinationPrefix\n$interfaceIndex\n$nextHop';
  }

  Future<void> _removeRouteExeServerRoutes(
    List<_WindowsHostRoute> routes,
  ) async {
    for (final route in routes.reversed) {
      final parts = _routeExeIpv4DestinationParts(route.destinationPrefix);
      if (parts == null) {
        _rememberAppLog(
          'Failed to remove temporary host route ${route.destinationPrefix}: route.exe only supports IPv4 /32 routes here.',
        );
        continue;
      }
      try {
        final result = await _runTimedProcess(
          'route_delete_ipv4_server',
          'route.exe',
          <String>['DELETE', parts.address, 'MASK', parts.mask, route.nextHop],
        );
        if (result.exitCode != 0) {
          _rememberAppLog(
            'Failed to remove temporary host route ${route.destinationPrefix}: ${_describeError(result.stderr)}',
          );
          continue;
        }
        _rememberAppLog(
          'Temporary host route ${route.destinationPrefix} removed.',
        );
      } catch (error) {
        _rememberAppLog(
          'Failed to remove temporary host route ${route.destinationPrefix}: ${_describeError(error)}',
        );
      }
    }
  }

  _RouteExeIpv4Destination? _routeExeIpv4DestinationParts(
    String destinationPrefix,
  ) {
    final parts = destinationPrefix.split('/');
    if (parts.length != 2) {
      return null;
    }
    final address = InternetAddress.tryParse(parts[0]);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return null;
    }
    final mask = switch (parts[1]) {
      '1' => '128.0.0.0',
      '32' => '255.255.255.255',
      _ => null,
    };
    if (mask == null) {
      return null;
    }
    return _RouteExeIpv4Destination(address: address.address, mask: mask);
  }

  Future<void> _removeTemporaryTunRoutes({
    List<_WindowsTunRoute>? routes,
  }) async {
    final routesToRemove = routes ?? _temporaryTunRoutes;
    if (routes == null) {
      _temporaryTunRoutes = const <_WindowsTunRoute>[];
    }
    if (routesToRemove.isEmpty) {
      return;
    }

    final nativeRoutes = routesToRemove
        .where(
          (route) => _canRemoveWithNativeIpv4RouteApi(
            destinationPrefix: route.destinationPrefix,
            interfaceIndex: route.interfaceIndex,
            nextHop: route.nextHop,
          ),
        )
        .map(
          (route) => (
            destinationPrefix: route.destinationPrefix,
            interfaceIndex: route.interfaceIndex,
            nextHop: route.nextHop,
          ),
        )
        .toList(growable: false);
    final nativeRemovedKeys = nativeRoutes.isEmpty
        ? <String>{}
        : await _removeNativeIpv4Routes(
                nativeRoutes,
                label: 'remove_xray_tun_routes',
              ) ??
              <String>{};
    for (final route in routesToRemove) {
      if (nativeRemovedKeys.contains(
        _routeRemovalKey(
          destinationPrefix: route.destinationPrefix,
          interfaceIndex: route.interfaceIndex,
          nextHop: route.nextHop,
        ),
      )) {
        _rememberAppLog('Xray TUN route ${route.destinationPrefix} removed.');
      }
    }

    final routesForFallback = routesToRemove
        .where(
          (route) => !nativeRemovedKeys.contains(
            _routeRemovalKey(
              destinationPrefix: route.destinationPrefix,
              interfaceIndex: route.interfaceIndex,
              nextHop: route.nextHop,
            ),
          ),
        )
        .toList(growable: false);
    if (routesForFallback.isEmpty) {
      return;
    }

    const script = r'''
param([string]$RoutesBase64)
try {
  $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($RoutesBase64))
  $routes = $json | ConvertFrom-Json
  if ($null -eq $routes) {
    $routes = @()
  } elseif ($routes -isnot [System.Array]) {
    $routes = @($routes)
  }
  foreach ($route in $routes) {
    $destinationPrefix = [string]$route.destinationPrefix
    $interfaceIndex = [int]$route.interfaceIndex
    $nextHop = [string]$route.nextHop
    Get-NetRoute -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
      Where-Object {
        $_.InterfaceIndex -eq $interfaceIndex -and
        $_.NextHop -eq $nextHop
      } |
      Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  }
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      await _runPowerShellScript(
        script,
        label: 'remove_xray_tun_routes',
        namedArgs: <String, String>{
          'RoutesBase64': base64Encode(
            utf8.encode(_tunRoutesJson(routesForFallback)),
          ),
        },
      );
      for (final route in routesForFallback) {
        _rememberAppLog('Xray TUN route ${route.destinationPrefix} removed.');
      }
    } catch (error) {
      _rememberAppLog(
        'Failed to remove Xray TUN routes: ${_describeError(error)}',
      );
    }
  }

  String _tunRoutesJson(List<_WindowsTunRoute> routes) {
    return jsonEncode(
      routes
          .map(
            (route) => <String, dynamic>{
              'destinationPrefix': route.destinationPrefix,
              'interfaceIndex': route.interfaceIndex,
              'nextHop': route.nextHop,
            },
          )
          .toList(growable: false),
    );
  }

  String _hostRoutesJson(List<_WindowsHostRoute> routes) {
    return jsonEncode(
      routes
          .map(
            (route) => <String, dynamic>{
              'destinationPrefix': route.destinationPrefix,
              'interfaceIndex': route.interfaceIndex,
              'nextHop': route.nextHop,
            },
          )
          .toList(growable: false),
    );
  }

  Future<bool?> _isRunningAsAdministrator() async {
    if (!Platform.isWindows) {
      return null;
    }
    final cached = _cachedWindowsElevation;
    if (cached != null) {
      return cached;
    }

    final fastElevation = _detectWindowsElevationWithToken();
    if (fastElevation != null) {
      _cachedWindowsElevation = fastElevation;
      return fastElevation;
    }

    final fltmcElevation = await _detectWindowsElevationWithFltmc();
    if (fltmcElevation != null) {
      _cachedWindowsElevation = fltmcElevation;
      return fltmcElevation;
    }

    const script = r'''
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  [Console]::Out.Write($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
  ''';

    try {
      final result = await _runPowerShellScript(
        script,
        label: 'detect_elevation',
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to detect elevation: ${_describeError(result.stderr)}',
        );
        return null;
      }

      final output = result.stdout.toString().trim().toLowerCase();
      if (output == 'true') {
        _cachedWindowsElevation = true;
        return true;
      }
      if (output == 'false') {
        _cachedWindowsElevation = false;
        return false;
      }

      _rememberAppLog(
        'Failed to detect elevation: unexpected output "${result.stdout.toString().trim()}".',
      );
      return null;
    } catch (error) {
      _rememberAppLog('Failed to detect elevation: ${_describeError(error)}');
      return null;
    }
  }

  bool? _detectWindowsElevationWithToken() {
    final stopwatch = Stopwatch()..start();
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final advapi32 = DynamicLibrary.open('advapi32.dll');
      final getCurrentProcess = kernel32
          .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
            'GetCurrentProcess',
          );
      final closeHandle = kernel32
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
      final openProcessToken = advapi32
          .lookupFunction<_OpenProcessTokenNative, _OpenProcessTokenDart>(
            'OpenProcessToken',
          );
      final getTokenInformation = advapi32
          .lookupFunction<_GetTokenInformationNative, _GetTokenInformationDart>(
            'GetTokenInformation',
          );

      final tokenHandle = calloc<IntPtr>();
      final elevation = calloc<Uint32>();
      final returnLength = calloc<Uint32>();
      try {
        final opened = openProcessToken(
          getCurrentProcess(),
          _tokenQuery,
          tokenHandle,
        );
        if (opened == 0 || tokenHandle.value == 0) {
          return null;
        }

        final ok = getTokenInformation(
          tokenHandle.value,
          _tokenElevation,
          elevation.cast<Void>(),
          sizeOf<Uint32>(),
          returnLength,
        );
        if (ok == 0) {
          return null;
        }

        return elevation.value != 0;
      } finally {
        if (tokenHandle.value != 0) {
          closeHandle(tokenHandle.value);
        }
        calloc.free(returnLength);
        calloc.free(elevation);
        calloc.free(tokenHandle);
      }
    } catch (error) {
      _rememberAppLog(
        'Fast token elevation probe unavailable: ${_describeError(error)}',
      );
      return null;
    } finally {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: token:detect_elevation elapsed=${stopwatch.elapsedMilliseconds}ms.',
      );
    }
  }

  Future<bool?> _detectWindowsElevationWithFltmc() async {
    try {
      final result = await _runTimedProcess(
        'fltmc:detect_elevation',
        'fltmc.exe',
        const <String>[],
        timeout: const Duration(seconds: 1),
      );
      if (result.exitCode == 0) {
        return true;
      }

      final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
      if (output.contains('0x80070005') ||
          output.contains('access is denied') ||
          output.contains('requires elevation')) {
        return false;
      }

      _rememberAppLog(
        'Fast elevation probe unavailable: fltmc exited with ${result.exitCode}; falling back to PowerShell.',
      );
      return null;
    } catch (error) {
      _rememberAppLog(
        'Fast elevation probe unavailable: ${_describeError(error)}',
      );
      return null;
    }
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

class _WindowsProcessInfo {
  const _WindowsProcessInfo({
    required this.pid,
    required this.parentPid,
    required this.path,
  });

  final int pid;
  final int parentPid;
  final String? path;
}

class _WindowsProcessSnapshotCacheEntry {
  const _WindowsProcessSnapshotCacheEntry({
    required this.createdAt,
    required this.processes,
  });

  final DateTime createdAt;
  final List<_WindowsProcessInfo> processes;
}

class _WindowsRouteInfo {
  const _WindowsRouteInfo({
    required this.interfaceAlias,
    this.interfaceIndex,
    this.sourceAddress,
    this.nextHop,
    this.hardwareInterface,
    this.virtual,
  });

  final String interfaceAlias;
  final int? interfaceIndex;
  final String? sourceAddress;
  final String? nextHop;
  final bool? hardwareInterface;
  final bool? virtual;
}

class _TunRoutingPreparation {
  const _TunRoutingPreparation({
    this.outboundBindInterface,
    this.serverAddressOverride,
    this.hasHostRoute = false,
  });

  final String? outboundBindInterface;
  final String? serverAddressOverride;
  final bool hasHostRoute;
}

class _WindowsTunSetup {
  const _WindowsTunSetup({
    required this.routes,
    required this.networkChanged,
    this.fastConfigureMethod,
  });

  final List<_WindowsTunRoute> routes;
  final bool networkChanged;
  final _WindowsTunFastConfigureMethod? fastConfigureMethod;
}

enum _WindowsTunSetupKind { full, fastNativeApi, fastNetsh, routeOnly }

enum _WindowsTunFastConfigureMethod {
  nativeApi('native_configure'),
  netsh('netsh_configure');

  const _WindowsTunFastConfigureMethod(this.timingLabel);

  final String timingLabel;
}

class _WindowsTunRoute {
  const _WindowsTunRoute({
    required this.destinationPrefix,
    required this.interfaceAlias,
    required this.interfaceIndex,
    required this.nextHop,
  });

  final String destinationPrefix;
  final String interfaceAlias;
  final int interfaceIndex;
  final String nextHop;
}

class _WindowsHostRoute {
  const _WindowsHostRoute({
    required this.destinationPrefix,
    required this.interfaceAlias,
    required this.interfaceIndex,
    required this.nextHop,
    this.removalTool = _WindowsRouteRemovalTool.powerShell,
    this.removeWhenUnused = true,
  });

  final String destinationPrefix;
  final String interfaceAlias;
  final int interfaceIndex;
  final String nextHop;
  final _WindowsRouteRemovalTool removalTool;
  final bool removeWhenUnused;
}

enum _WindowsRouteRemovalTool { powerShell, routeExe }

class _Ipv4DefaultRoute {
  const _Ipv4DefaultRoute({
    required this.gateway,
    required this.interfaceAddress,
    required this.metric,
  });

  final String gateway;
  final String interfaceAddress;
  final int metric;
}

class _RouteExeIpv4Destination {
  const _RouteExeIpv4Destination({required this.address, required this.mask});

  final String address;
  final String mask;
}

class _NetshIpv4Interface {
  const _NetshIpv4Interface({
    required this.index,
    required this.name,
    required this.status,
  });

  final int index;
  final String name;
  final String status;
}

const int _tokenQuery = 0x0008;
const int _tokenElevation = 20;
const int _th32csSnapProcess = 0x00000002;
const int _invalidHandleValue = -1;
const int _processQueryLimitedInformation = 0x1000;
const int _processTerminate = 0x0001;
const int _synchronize = 0x00100000;
const int _maxWindowsPathBufferChars = 32768;

final class _ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;

  @Uint32()
  external int cntUsage;

  @Uint32()
  external int th32ProcessID;

  @IntPtr()
  external int th32DefaultHeapID;

  @Uint32()
  external int th32ModuleID;

  @Uint32()
  external int cntThreads;

  @Uint32()
  external int th32ParentProcessID;

  @Int32()
  external int pcPriClassBase;

  @Uint32()
  external int dwFlags;

  @Array(260)
  external Array<Uint16> szExeFile;
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

typedef _OpenProcessTokenNative =
    Int32 Function(IntPtr processHandle, Uint32 desiredAccess, Pointer<IntPtr>);
typedef _OpenProcessTokenDart =
    int Function(int processHandle, int desiredAccess, Pointer<IntPtr>);

typedef _GetTokenInformationNative =
    Int32 Function(
      IntPtr tokenHandle,
      Int32 tokenInformationClass,
      Pointer<Void> tokenInformation,
      Uint32 tokenInformationLength,
      Pointer<Uint32> returnLength,
    );
typedef _GetTokenInformationDart =
    int Function(
      int tokenHandle,
      int tokenInformationClass,
      Pointer<Void> tokenInformation,
      int tokenInformationLength,
      Pointer<Uint32> returnLength,
    );

typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

typedef _CreateToolhelp32SnapshotNative =
    IntPtr Function(Uint32 flags, Uint32 processId);
typedef _CreateToolhelp32SnapshotDart = int Function(int flags, int processId);

typedef _Process32Native =
    Int32 Function(IntPtr snapshot, Pointer<_ProcessEntry32W> entry);
typedef _Process32Dart =
    int Function(int snapshot, Pointer<_ProcessEntry32W> entry);

typedef _OpenProcessNative =
    IntPtr Function(
      Uint32 desiredAccess,
      Int32 inheritHandle,
      Uint32 processId,
    );
typedef _OpenProcessDart =
    int Function(int desiredAccess, int inheritHandle, int processId);

typedef _QueryFullProcessImageNameNative =
    Int32 Function(
      IntPtr process,
      Uint32 flags,
      Pointer<Uint16> exeName,
      Pointer<Uint32> size,
    );
typedef _QueryFullProcessImageNameDart =
    int Function(
      int process,
      int flags,
      Pointer<Uint16> exeName,
      Pointer<Uint32> size,
    );

typedef _TerminateProcessNative =
    Int32 Function(IntPtr process, Uint32 exitCode);
typedef _TerminateProcessDart = int Function(int process, int exitCode);

typedef _WaitForSingleObjectNative =
    Uint32 Function(IntPtr handle, Uint32 milliseconds);
typedef _WaitForSingleObjectDart = int Function(int handle, int milliseconds);
