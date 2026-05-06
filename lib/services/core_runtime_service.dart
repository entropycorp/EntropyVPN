import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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
  Future<void>? _pendingStopCleanup;
  final Set<String> _sweptWindowsTunCorePaths = <String>{};
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
    await _waitForPendingStopCleanupBeforeStart();
    _recentLogs.clear();
    _rememberAppLog(
      'Starting ${core.name} in ${trafficMode.name} mode for ${profile.server}:${profile.port}.',
    );
    final startupTiming = _StartupTiming()..start();
    Directory? runtimeDirectory;

    try {
      final effectiveSplitTunnelSettings = await startupTiming.time(
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
          'Split tunneling: ${effectiveSplitTunnelSettings.mode.name}, selected apps: ${effectiveSplitTunnelSettings.apps.length}.',
        );
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
        final sweepKey = p.normalize(binaryPath).toLowerCase();
        if (!_sweptWindowsTunCorePaths.contains(sweepKey)) {
          await startupTiming.time(
            'stale_core_sweep',
            () => _stopStaleWindowsTunCoreProcesses(binaryPath),
          );
          _sweptWindowsTunCorePaths.add(sweepKey);
        }
      }
      final tunInterfaceName = Platform.isWindows && requiresTunPrerequisites
          ? _buildWindowsTunInterfaceName()
          : null;
      if (tunInterfaceName != null) {
        _rememberAppLog('Selected TUN interface name: $tunInterfaceName.');
      }
      final tunRouting = await startupTiming.time(
        'server_routing',
        () async => profile.isNativeConfig
            ? null
            : await _prepareTunServerRouting(
                profile,
                trafficMode: trafficMode,
                tunIpMode: tunIpMode,
              ),
      );
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

  Future<void> stop() async {
    if (Platform.isAndroid) {
      _androidBridge?.onProcessExit = onProcessExit;
      _androidBridge?.onLogUpdated = onLogUpdated;
      await _androidBridge?.stop();
      return;
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

      _scheduleStopCleanup(
        tunRoutes: tunRoutes,
        serverRoutes: serverRoutes,
        proxySnapshot: proxySnapshot,
        runtimeDirectory: runtimeDirectory,
      );
    } finally {
      stopTiming.stop();
      _rememberAppLog('Stop timing: ${stopTiming.summary()}.');
    }
  }

  Future<void> _waitForPendingStopCleanupBeforeStart() async {
    final cleanup = _pendingStopCleanup;
    if (cleanup == null) {
      return;
    }

    _rememberAppLog('Waiting for previous stop cleanup before reconnecting...');
    await cleanup;
  }

  void _scheduleStopCleanup({
    required List<_WindowsTunRoute> tunRoutes,
    required List<_WindowsHostRoute> serverRoutes,
    required SystemProxySnapshot? proxySnapshot,
    required Directory? runtimeDirectory,
  }) {
    if (tunRoutes.isEmpty &&
        serverRoutes.isEmpty &&
        proxySnapshot == null &&
        runtimeDirectory == null) {
      return;
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
    final process = await Process.start(
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
      pathLookup = await Process.run('where.exe', <String>[fileName]);
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
    final result = await Process.run(
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
    var taskkillStarted = false;
    try {
      taskkillStarted = true;
      final result = await Process.run('taskkill.exe', <String>[
        '/PID',
        process.pid.toString(),
        '/T',
        '/F',
      ]).timeout(const Duration(seconds: 2));
      if (result.exitCode != 0 && !await _hasProcessExited(process)) {
        _rememberAppLog(
          'taskkill failed for PID ${process.pid}: ${_describeError(result.stderr)}',
        );
      }
    } catch (error) {
      _rememberAppLog(
        'taskkill failed for PID ${process.pid}: ${_describeError(error)}',
      );
    } finally {
      if (!taskkillStarted || !await _hasProcessExited(process)) {
        process.kill(ProcessSignal.sigkill);
      }
    }

    try {
      await process.exitCode.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      _rememberAppLog(
        'Process PID ${process.pid} still did not report exit after taskkill.',
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

  String _buildWindowsTunInterfaceName() {
    return 'EntropyVPN TUN';
  }

  Future<bool> _relaunchAsAdministrator() async {
    const script = r'''
param(
  [string]$FilePath,
  [string]$WorkingDirectory
)
try {
  Start-Process `
    -FilePath $FilePath `
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
        namedArgs: <String, String>{
          'FilePath': executable,
          'WorkingDirectory': p.dirname(executable),
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

    final serverIp = InternetAddress.tryParse(profile.server.trim());
    if (serverIp == null) {
      final fallback = await _findPreferredHardwareDefaultRoute();
      if (fallback != null) {
        final serverAddressOverride = await _installDomainBypassRoutes(
          host: profile.server.trim(),
          route: fallback,
          tunIpMode: tunIpMode,
        );
        _rememberAppLog(
          'VPN server is a domain name; using hardware default interface ${fallback.interfaceAlias} for TUN outbounds and host-route bypasses.',
        );
        return _TunRoutingPreparation(
          outboundBindInterface: fallback.interfaceAlias,
          serverAddressOverride: serverAddressOverride,
        );
      }
      _rememberAppLog(
        'Could not resolve a hardware default interface for domain server; using core defaults.',
      );
      return null;
    }

    final route = await _findRouteForRemoteAddress(serverIp.address);
    if (route == null) {
      _rememberAppLog(
        'Could not resolve Windows route for ${serverIp.address}; using core defaults.',
      );
      return null;
    }

    _rememberAppLog(
      'Windows route to ${serverIp.address}: interface=${route.interfaceAlias}, source=${route.sourceAddress}, nextHop=${route.nextHop}, hardware=${route.hardwareInterface}, virtual=${route.virtual}.',
    );

    _WindowsHostRoute? pinnedRoute;
    if (route.interfaceIndex != null &&
        route.nextHop != null &&
        route.nextHop!.trim().isNotEmpty &&
        route.hardwareInterface != false &&
        route.virtual != true) {
      _rememberAppLog(
        'Installing explicit host route for VPN server via ${route.interfaceAlias} (${route.nextHop}) to keep upstream traffic outside TUN...',
      );
      pinnedRoute = _WindowsHostRoute(
        destinationPrefix: serverIp.type == InternetAddressType.IPv6
            ? '${serverIp.address}/128'
            : '${serverIp.address}/32',
        interfaceAlias: route.interfaceAlias,
        interfaceIndex: route.interfaceIndex!,
        nextHop: route.nextHop!,
      );
    } else {
      final fallback = await _findPreferredHardwareDefaultRoute();
      if (fallback != null && fallback.nextHop != null) {
        _rememberAppLog(
          'Detected virtual route to VPN server. Installing direct host route via ${fallback.interfaceAlias} (${fallback.nextHop})...',
        );
        pinnedRoute = _WindowsHostRoute(
          destinationPrefix: serverIp.type == InternetAddressType.IPv6
              ? '${serverIp.address}/128'
              : '${serverIp.address}/32',
          interfaceAlias: fallback.interfaceAlias,
          interfaceIndex: fallback.interfaceIndex,
          nextHop: fallback.nextHop!,
        );
      } else {
        _rememberAppLog(
          'No suitable hardware default route found for VPN server bypass; continuing with ${route.interfaceAlias}.',
        );
      }
    }

    if (pinnedRoute != null) {
      final installed = await _installTemporaryServerRoute(pinnedRoute);
      if (installed) {
        return _TunRoutingPreparation(
          outboundBindInterface: pinnedRoute.interfaceAlias,
          serverAddressOverride: null,
        );
      }
    }

    return _TunRoutingPreparation(
      outboundBindInterface: route.interfaceAlias,
      serverAddressOverride: null,
    );
  }

  Future<String?> _installDomainBypassRoutes({
    required String host,
    required _WindowsDefaultRouteInfo route,
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
        return null;
      }

      _rememberAppLog(
        'Resolved VPN server $host for host-route bypass: ${uniqueAddresses.map((address) => address.address).join(', ')}.',
      );
      await _installTemporaryServerRoutes(
        uniqueAddresses
            .map(
              (address) => _hostRouteForAddress(
                address,
                interfaceAlias: route.interfaceAlias,
                interfaceIndex: route.interfaceIndex,
                nextHop: route.nextHop,
              ),
            )
            .toList(growable: false),
      );
      return uniqueAddresses.first.address;
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

  _WindowsHostRoute _hostRouteForAddress(
    InternetAddress address, {
    required String interfaceAlias,
    required int interfaceIndex,
    required String? nextHop,
  }) {
    return _WindowsHostRoute(
      destinationPrefix: address.type == InternetAddressType.IPv6
          ? '${address.address}/128'
          : '${address.address}/32',
      interfaceAlias: interfaceAlias,
      interfaceIndex: interfaceIndex,
      nextHop:
          nextHop ??
          (address.type == InternetAddressType.IPv6 ? '::' : '0.0.0.0'),
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

    final descendants = await _findRunningDescendantApps(normalized.apps);
    if (descendants.isEmpty) {
      return normalized;
    }

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
    _rememberAppLog(
      'Split tunneling added ${expanded.apps.length - normalized.apps.length} running child process paths.',
    );
    return expanded;
  }

  Future<List<SplitTunnelApp>> _findRunningDescendantApps(
    List<SplitTunnelApp> selectedApps,
  ) async {
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

  $processes = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath })
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

  Future<_WindowsRouteInfo?> _findRouteForRemoteAddress(
    String remoteAddress,
  ) async {
    const script = r'''
param([string]$RemoteAddress)
try {
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

  [PSCustomObject]@{
    InterfaceAlias = [string]$route.InterfaceAlias
    InterfaceIndex = [int]$route.InterfaceIndex
    SourceAddress = if ($null -eq $ip) { '' } else { [string]$ip.IPAddress }
    NextHop = [string]$route.NextHop
    HardwareInterface = if ($null -eq $adapter) { $null } else { [bool]$adapter.HardwareInterface }
    Virtual = if ($null -eq $adapter) { $null } else { [bool]$adapter.Virtual }
  } | ConvertTo-Json -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final result = await _runPowerShellScript(
        script,
        namedArgs: <String, String>{'RemoteAddress': remoteAddress},
      );

      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to resolve Windows route for $remoteAddress: ${_describeError(result.stderr)}',
        );
        return null;
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        return null;
      }

      final json = jsonDecode(output);
      if (json is! Map<String, dynamic>) {
        _rememberAppLog(
          'Failed to resolve Windows route for $remoteAddress: unexpected output "$output".',
        );
        return null;
      }

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
    } catch (error) {
      _rememberAppLog(
        'Failed to resolve Windows route for $remoteAddress: ${_describeError(error)}',
      );
      return null;
    }
  }

  Future<_WindowsDefaultRouteInfo?> _findPreferredHardwareDefaultRoute() async {
    const script = r'''
try {
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

  $selected = $candidates | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
  if ($null -eq $selected) {
    exit 0
  }

  $selected | ConvertTo-Json -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final result = await _runPowerShellScript(script);

      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to resolve hardware default route: ${_describeError(result.stderr)}',
        );
        return null;
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        return null;
      }

      final json = jsonDecode(output);
      if (json is! Map<String, dynamic>) {
        _rememberAppLog(
          'Failed to resolve hardware default route: unexpected output "$output".',
        );
        return null;
      }

      final alias = json['InterfaceAlias']?.toString().trim();
      final index = (json['InterfaceIndex'] as num?)?.toInt();
      final nextHop = json['NextHop']?.toString().trim();
      if (alias == null || alias.isEmpty || index == null || nextHop == null) {
        return null;
      }

      _rememberAppLog(
        'Preferred hardware default route: interface=$alias, nextHop=$nextHop, metric=${json['InterfaceMetric']}.',
      );
      return _WindowsDefaultRouteInfo(
        interfaceAlias: alias,
        interfaceIndex: index,
        nextHop: nextHop,
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to resolve hardware default route: ${_describeError(error)}',
      );
      return null;
    }
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

    final setup = await _prepareWindowsXrayTunAdapterAndRoutes(
      interfaceAlias: interfaceAlias,
      tunIpMode: tunIpMode,
    );
    if (setup == null) {
      throw StateError('Failed to prepare Xray TUN adapter and routes.');
    }

    _temporaryTunRoutes = List<_WindowsTunRoute>.unmodifiable(setup.routes);
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

  Future<bool> _installTemporaryServerRoute(_WindowsHostRoute route) {
    return _installTemporaryServerRoutes(<_WindowsHostRoute>[route]);
  }

  Future<bool> _installTemporaryServerRoutes(
    List<_WindowsHostRoute> routes,
  ) async {
    if (routes.isEmpty) {
      return true;
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
  $results = foreach ($route in $routes) {
    $destinationPrefix = [string]$route.destinationPrefix
    $interfaceIndex = [int]$route.interfaceIndex
    $nextHop = [string]$route.nextHop
    $existing = Get-NetRoute -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
      Where-Object {
        $_.InterfaceIndex -eq $interfaceIndex -and
        $_.NextHop -eq $nextHop
      } |
      Select-Object -First 1

    if ($null -eq $existing) {
      New-NetRoute `
        -DestinationPrefix $destinationPrefix `
        -InterfaceIndex $interfaceIndex `
        -NextHop $nextHop `
        -PolicyStore ActiveStore | Out-Null
      [PSCustomObject]@{
        DestinationPrefix = $destinationPrefix
        Status = 'created'
      }
    } else {
      [PSCustomObject]@{
        DestinationPrefix = $destinationPrefix
        Status = 'exists'
      }
    }
  }
  @($results) | ConvertTo-Json -Depth 4 -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final result = await _runPowerShellScript(
        script,
        namedArgs: <String, String>{
          'RoutesBase64': base64Encode(utf8.encode(_hostRoutesJson(routes))),
        },
      );

      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to install temporary host routes: ${_describeError(result.stderr)}',
        );
        return false;
      }

      _temporaryServerRoutes = List<_WindowsHostRoute>.unmodifiable(
        <_WindowsHostRoute>[..._temporaryServerRoutes, ...routes],
      );
      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        for (final route in routes) {
          _rememberAppLog(
            'Temporary host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) installed.',
          );
        }
        return true;
      }
      final decoded = jsonDecode(output);
      final items = decoded is List ? decoded : <dynamic>[decoded];
      for (final item in items) {
        if (item is! Map) {
          continue;
        }
        final destinationPrefix = item['DestinationPrefix']?.toString();
        final route = routes.firstWhere(
          (candidate) => candidate.destinationPrefix == destinationPrefix,
          orElse: () => routes.first,
        );
        final status = item['Status']?.toString();
        _rememberAppLog(
          'Temporary host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) ${status == 'created' ? 'created' : 'already existed'}.',
        );
      }
      return true;
    } catch (error) {
      _rememberAppLog(
        'Failed to install temporary host routes: ${_describeError(error)}',
      );
      return false;
    }
  }

  Future<void> _removeTemporaryServerRoute({
    List<_WindowsHostRoute>? routes,
  }) async {
    final routesToRemove = routes ?? _temporaryServerRoutes;
    if (routes == null) {
      _temporaryServerRoutes = const <_WindowsHostRoute>[];
    }
    if (routesToRemove.isEmpty) {
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
        namedArgs: <String, String>{
          'RoutesBase64': base64Encode(
            utf8.encode(_hostRoutesJson(routesToRemove)),
          ),
        },
      );
      for (final route in routesToRemove.reversed) {
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
        namedArgs: <String, String>{
          'RoutesBase64': base64Encode(
            utf8.encode(_tunRoutesJson(routesToRemove)),
          ),
        },
      );
      for (final route in routesToRemove) {
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

    const script = r'''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
[Console]::Out.Write($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
''';

    try {
      final result = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);
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
    Map<String, String> namedArgs = const <String, String>{},
  }) {
    return Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      _buildPowerShellInvocation(script, namedArgs: namedArgs),
    ]);
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

class _WindowsDefaultRouteInfo {
  const _WindowsDefaultRouteInfo({
    required this.interfaceAlias,
    required this.interfaceIndex,
    this.nextHop,
  });

  final String interfaceAlias;
  final int interfaceIndex;
  final String? nextHop;
}

class _TunRoutingPreparation {
  const _TunRoutingPreparation({
    this.outboundBindInterface,
    this.serverAddressOverride,
  });

  final String? outboundBindInterface;
  final String? serverAddressOverride;
}

class _WindowsTunSetup {
  const _WindowsTunSetup({required this.routes, required this.networkChanged});

  final List<_WindowsTunRoute> routes;
  final bool networkChanged;
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
  });

  final String destinationPrefix;
  final String interfaceAlias;
  final int interfaceIndex;
  final String nextHop;
}
