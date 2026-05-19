import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/vpn_profile.dart';
import '../models/dns_settings.dart';
import '../models/split_tunnel.dart';
import 'android_vpn_bridge.dart';
import 'app_update_service.dart';
import 'core_config_builder.dart';
import 'core_runtime_service_windows_helpers.dart';
import 'core_runtime_service_windows_types.dart';
import 'geo_ip_service.dart';
import 'system_proxy_service.dart';

part 'core_runtime_service_android.dart';
part 'core_runtime_service_lifecycle.dart';
part 'core_runtime_service_config_io.dart';
part 'core_runtime_service_process.dart';
part 'core_runtime_service_diagnostics.dart';
part 'core_runtime_service_windows.dart';
part 'core_runtime_service_windows_process.dart';
part 'core_runtime_service_windows_service.dart';
part 'core_runtime_service_windows_temporary_routes.dart';
part 'core_runtime_service_linux.dart';

class CoreRuntimeService {
  CoreRuntimeService({
    CoreConfigBuilder? configBuilder,
    GeoIpService? geoIpService,
    SystemProxyService? systemProxyService,
  }) : _configBuilder = configBuilder ?? CoreConfigBuilder(),
       _geoIpService = geoIpService ?? GeoIpService.shared;

  static const int _maxRecentLogs = 400;
  static const Duration _splitTunnelExpansionCacheTtl = Duration(seconds: 30);
  static const MethodChannel _windowsTunChannel = MethodChannel(
    'entropy_vpn/windows_tun',
  );
  static const MethodChannel _windowsRuntimeChannel = MethodChannel(
    'entropy_vpn/windows_runtime',
  );
  static const EventChannel _windowsRuntimeEventsChannel = EventChannel(
    'entropy_vpn/windows_runtime_events',
  );

  final CoreConfigBuilder _configBuilder;
  final GeoIpService _geoIpService;
  final Queue<String> _recentLogs = Queue<String>();
  final AndroidVpnBridge? _androidBridge = Platform.isAndroid
      ? AndroidVpnBridge()
      : null;

  Process? _process;
  WindowsServiceCoreProcess? _windowsServiceProcess;
  StreamSubscription<dynamic>? _windowsNativeRuntimeEventsSubscription;
  bool _windowsNativeRuntimeRunning = false;
  int _windowsNativeRuntimePid = 0;
  bool? _cachedWindowsElevation;
  bool _windowsTunServiceReady = false;
  _SplitTunnelExpansionCacheEntry? _splitTunnelExpansionCache;
  Future<void>? _pendingStopCleanup;
  List<WindowsHostRoute> _temporaryServerRoutes = const <WindowsHostRoute>[];

  void Function(String? error)? onProcessExit;
  void Function()? onLogUpdated;

  bool get isRunning => Platform.isAndroid
      ? (_androidBridge?.isRunning ?? false)
      : (_process != null ||
            _windowsServiceProcess != null ||
            _windowsNativeRuntimeRunning);
  String? get androidPhase => Platform.isAndroid ? _androidBridge?.phase : null;
  String? get lastLogLine => Platform.isAndroid
      ? _androidBridge?.lastLogLine
      : (_recentLogs.isEmpty ? null : _recentLogs.last);
  List<String> get recentLogs => Platform.isAndroid
      ? (_androidBridge?.recentLogs ?? const <String>[])
      : List<String>.unmodifiable(_recentLogs);
  DateTime? get connectedAt =>
      Platform.isAndroid ? _androidBridge?.connectedAt : null;

  Future<void> synchronizeState() => _synchronizeAndroidState();

  Future<T> withTcpPingBypassRoutes<T>({
    required Iterable<ParsedVpnProfile> profiles,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required Future<T> Function() action,
  }) async {
    if (!Platform.isWindows || trafficMode != TrafficMode.tun || !isRunning) {
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
    final existingRouteKeys = _temporaryServerRoutes
        .map(windowsHostRouteKey)
        .toSet();
    final pingRoutes = <WindowsHostRoute>[];
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
          .where(
            (route) => !existingRouteKeys.contains(windowsHostRouteKey(route)),
          )
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
    DnsSettings dnsSettings = const DnsSettings(),
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
  }) {
    return _saveAndroidStartPayload(
      core: core,
      profile: profile,
      language: language,
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
    );
  }

  Future<void> start({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TrafficMode trafficMode,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    DnsSettings dnsSettings = const DnsSettings(),
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
        dnsSettings: dnsSettings,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
      );
      return;
    }

    if (Platform.isWindows) {
      await _startOnWindowsNativeRuntime(
        core: core,
        profile: profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        dnsSettings: dnsSettings,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
      );
      return;
    }

    if (Platform.isLinux) {
      await _startOnLinux(
        core: core,
        profile: profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        dnsSettings: dnsSettings,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
      );
      return;
    }

    throw UnsupportedError(
      'EntropyVPN runtime is only supported on Android, Windows, and Linux.',
    );
  }

  Future<void> stop({bool waitForCleanup = false}) async {
    if (Platform.isAndroid) {
      await _stopOnAndroid();
      return;
    }
    if (Platform.isWindows) {
      await _stopWindowsNativeRuntime(waitForCleanup: waitForCleanup);
      return;
    }
    if (Platform.isLinux) {
      await _stopOnLinux();
      return;
    }
    // Other platforms (macOS): nothing to tear down yet.
  }

  // Pushes the user's killswitch preference down to the native layer, which
  // owns the full state machine: auto-engages on unexpected core exit and
  // auto-disengages on user-initiated start/stop. Best-effort; failures are
  // logged but never thrown.
  Future<void> setKillswitchPreference(bool enabled) async {
    if (Platform.isAndroid) {
      await _setKillswitchPreferenceOnAndroid(enabled);
      return;
    }
    if (Platform.isWindows) {
      await _setKillswitchPreferenceOnWindows(enabled);
      return;
    }
  }

  void dispose() => _disposeRuntime();
}
