part of 'core_runtime_service.dart';

extension CoreRuntimeServiceLifecycle on CoreRuntimeService {
  Future<void> _startOnDesktop({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) async {
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

  Future<void> _stopOnDesktop({required bool waitForCleanup}) async {
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
    _temporaryTunRoutes = const <WindowsTunRoute>[];
    _temporaryServerRoutes = const <WindowsHostRoute>[];
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
    required List<WindowsTunRoute> tunRoutes,
    required List<WindowsHostRoute> serverRoutes,
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
    required List<WindowsTunRoute> tunRoutes,
    required List<WindowsHostRoute> serverRoutes,
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

  void _disposeRuntime() {
    unawaited(_androidBridge?.dispose() ?? Future<void>.value());
    if (!Platform.isAndroid) {
      unawaited(stop());
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
}
