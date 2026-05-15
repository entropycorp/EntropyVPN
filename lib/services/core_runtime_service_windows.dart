part of 'core_runtime_service.dart';

class WindowsTunPrivilegeDeniedException implements Exception {
  const WindowsTunPrivilegeDeniedException();

  @override
  String toString() =>
      'Administrator privileges are required for Windows TUN mode.';
}

extension CoreRuntimeServiceWindows on CoreRuntimeService {
  Future<void> _startOnWindowsNativeRuntime({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) async {
    if (!Platform.isWindows) {
      return;
    }

    await _ensureWindowsNativeRuntimeEvents();
    await _stopWindowsNativeRuntime(waitForCleanup: true);
    await _waitForPendingStopCleanup(reason: 'before native Windows start');
    _recentLogs.clear();

    final startupTiming = _StartupTiming()..start();
    try {
      _rememberAppLog(
        'Starting native Windows runtime: core=${core.name}, traffic=${trafficMode.name}, endpoint=${profile.server}:${profile.port}.',
      );

      final effectiveSplitTunnelSettings = trafficMode == TrafficMode.tun
          ? await startupTiming.time(
              'split_tunnel',
              () => _expandSplitTunnelSettings(splitTunnelSettings),
            )
          : splitTunnelSettings.normalized;
      final effectiveDomainSplitTunnelSettings = trafficMode == TrafficMode.tun
          ? domainSplitTunnelSettings.normalized
          : const DomainSplitTunnelSettings();

      final binaryPath = await startupTiming.time(
        'resolve_binary',
        () => _resolveBinary(core),
      );
      final requiresTunPrerequisites =
          (!profile.isNativeConfig && trafficMode == TrafficMode.tun) ||
          _profileConfigHasTunInbound(profile);
      final tunInterfaceName = requiresTunPrerequisites
          ? _buildWindowsTunInterfaceName()
          : null;
      final nativePayload = profile.isNativeConfig
          ? _buildRuntimeConfigPayload(
              core: core,
              profile: profile,
              trafficMode: trafficMode,
              tunIpMode: tunIpMode,
              dnsSettings: dnsSettings,
              splitTunnelSettings: effectiveSplitTunnelSettings,
              domainSplitTunnelSettings: effectiveDomainSplitTunnelSettings,
              tunInterfaceName: tunInterfaceName,
            )
          : null;

      final rawResult = await startupTiming.time(
        'native_runtime_start',
        () => CoreRuntimeService._windowsRuntimeChannel
            .invokeMethod<Object?>('start', <String, Object?>{
              'core': core.name,
              'binaryPath': binaryPath,
              'trafficMode': trafficMode.name,
              'tunIpMode': tunIpMode.name,
              'profileServer': profile.server,
              'profilePort': profile.port,
              'profileJson': jsonEncode(profile.toJson()),
              'optionsJson': _buildWindowsNativeRuntimeOptionsJson(
                core: core,
                trafficMode: trafficMode,
                tunIpMode: tunIpMode,
                dnsSettings: dnsSettings.normalized,
                splitTunnelSettings: effectiveSplitTunnelSettings,
                domainSplitTunnelSettings: effectiveDomainSplitTunnelSettings,
              ),
              'nativeConfigJson': nativePayload?.json,
              'workingDirectory': _resolveConfigWorkingDirectory(profile),
              'dnsServers': dnsSettings.normalized.serversFor(tunIpMode),
              'profileIsNativeConfig': profile.isNativeConfig,
              'requiresTunPrerequisites': requiresTunPrerequisites,
              'skipValidation':
                  nativePayload?.skipValidation ??
                  (core == CoreFlavor.xray && trafficMode == TrafficMode.tun),
            }),
      );
      if (rawResult is! Map) {
        throw StateError('Native Windows runtime returned an invalid result.');
      }
      final result = rawResult.cast<Object?, Object?>();
      if (result['exitRequested'] == true) {
        _rememberAppLog(
          'Elevated instance was launched. Exiting unelevated instance.',
        );
        exit(0);
      }
      if (result['ok'] != true) {
        final failedStep = result['failedStep']?.toString() ?? 'native-start';
        final error = result['error']?.toString() ?? 'unknown error';
        throw StateError('$failedStep failed: $error');
      }

      _windowsNativeRuntimeRunning = true;
      _windowsNativeRuntimePid = (result['pid'] as num?)?.toInt() ?? 0;
      _windowsTunServiceReady = result['useService'] == true;
      final runtimeDirectory = result['runtimeDirectory']?.toString();
      _rememberAppLog(
        'Native Windows runtime started${_windowsNativeRuntimePid > 0 ? ' with PID $_windowsNativeRuntimePid' : ''}${runtimeDirectory == null ? '' : ' in $runtimeDirectory'}.',
      );
    } catch (error) {
      _windowsNativeRuntimeRunning = false;
      _windowsNativeRuntimePid = 0;
      _windowsTunServiceReady = false;
      _rememberAppLog('Native Windows start failed: ${_describeError(error)}');
      rethrow;
    } finally {
      startupTiming.stop();
      _rememberAppLog(
        'Native Windows startup timing: ${startupTiming.summary()}.',
      );
    }
  }

  Future<void> _stopWindowsNativeRuntime({required bool waitForCleanup}) async {
    if (!Platform.isWindows) {
      return;
    }

    final stopTiming = _StartupTiming()..start();
    try {
      await _ensureWindowsNativeRuntimeEvents();
      final rawResult = await stopTiming.time(
        'native_runtime_stop',
        () => CoreRuntimeService._windowsRuntimeChannel.invokeMethod<Object?>(
          'stop',
          <String, Object?>{'waitForCleanup': waitForCleanup},
        ),
      );
      if (rawResult is Map) {
        final result = rawResult.cast<Object?, Object?>();
        if (result['ok'] != true) {
          final failedStep = result['failedStep']?.toString() ?? 'native-stop';
          final error = result['error']?.toString() ?? 'unknown error';
          _rememberAppLog('Native Windows stop failed: $failedStep: $error');
        }
      }
    } on MissingPluginException {
      _rememberAppLog(
        'Native Windows runtime stop skipped: runner channel is not registered.',
      );
    } catch (error) {
      _rememberAppLog('Native Windows stop failed: ${_describeError(error)}');
    } finally {
      _windowsNativeRuntimeRunning = false;
      _windowsNativeRuntimePid = 0;
      _windowsTunServiceReady = false;
      stopTiming.stop();
      _rememberAppLog('Native Windows stop timing: ${stopTiming.summary()}.');
    }
  }

  Future<void> _ensureWindowsNativeRuntimeEvents() async {
    if (!Platform.isWindows ||
        _windowsNativeRuntimeEventsSubscription != null) {
      return;
    }

    try {
      ServicesBinding.instance.defaultBinaryMessenger;
    } catch (error) {
      throw MissingPluginException(error.toString());
    }

    _windowsNativeRuntimeEventsSubscription = CoreRuntimeService
        ._windowsRuntimeEventsChannel
        .receiveBroadcastStream()
        .listen(
          _handleWindowsNativeRuntimeEvent,
          onError: (Object error) {
            _rememberAppLog(
              'Native Windows runtime event stream failed: ${_describeError(error)}',
            );
          },
        );
  }

  void _handleWindowsNativeRuntimeEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    final decoded = event.cast<Object?, Object?>();
    final type = decoded['type']?.toString();
    switch (type) {
      case 'log':
        final line = decoded['line']?.toString().trim();
        if (line != null && line.isNotEmpty) {
          _rememberLog(line);
        }
        break;
      case 'state':
        _windowsNativeRuntimeRunning = decoded['running'] == true;
        _windowsNativeRuntimePid = (decoded['pid'] as num?)?.toInt() ?? 0;
        _windowsTunServiceReady = decoded['useService'] == true;
        onLogUpdated?.call();
        break;
      case 'exit':
        _windowsNativeRuntimeRunning = false;
        _windowsNativeRuntimePid = 0;
        _windowsTunServiceReady = false;
        final message = decoded['error']?.toString().trim();
        onProcessExit?.call(
          message == null || message.isEmpty ? null : message,
        );
        break;
    }
  }

  String _buildWindowsNativeRuntimeOptionsJson({
    required CoreFlavor core,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) {
    final splitTunnel = splitTunnelSettings.normalized;
    final domainSplitTunnel = domainSplitTunnelSettings.normalized;
    return jsonEncode(<String, Object?>{
      'core': core.name,
      'trafficMode': trafficMode.name,
      'tunIpMode': tunIpMode.name,
      'isAndroid': false,
      'dnsServers': dnsSettings.normalized.serversFor(tunIpMode),
      'splitTunnelMode': splitTunnel.mode.name,
      'splitTunnelAppNames': splitTunnel.apps
          .map((app) => app.name)
          .toList(growable: false),
      'splitTunnelAppPaths': splitTunnel.apps
          .map((app) => app.path)
          .toList(growable: false),
      'domainSplitTunnelMode': domainSplitTunnel.mode.name,
      'domainSplitTunnelDomains': domainSplitTunnel.domains
          .map((domain) => domain.matchSuffix)
          .toList(growable: false),
    });
  }

  Future<void> _ensureWindowsTunPrerequisites(
    String binaryPath, {
    required TunIpMode tunIpMode,
  }) async {
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

    if (!await ensureWindowsTunPrivileges(tunIpMode: tunIpMode)) {
      throw const WindowsTunPrivilegeDeniedException();
    }
  }

  Future<bool> ensureWindowsTunPrivileges({TunIpMode? tunIpMode}) async {
    if (!Platform.isWindows) {
      return true;
    }

    final elevated = await _isRunningAsAdministrator();
    if (elevated == false) {
      if (tunIpMode != null &&
          await _ensureWindowsTunServiceReady(tunIpMode: tunIpMode)) {
        return true;
      }
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

  String _buildWindowsTunInterfaceName() {
    return 'EntropyVPN TUN';
  }

  Future<TunRoutingPreparation?> _prepareTunServerRouting(
    ParsedVpnProfile profile, {
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
  }) async {
    if (!Platform.isWindows || trafficMode != TrafficMode.tun) {
      return null;
    }

    final server = profile.server.trim();
    if (server.isEmpty) {
      return null;
    }

    Object? rawResult;
    try {
      rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('prepareTunServerRouting', <String, Object?>{
            'server': server,
            'tunIpMode': tunIpMode.name,
            'useService': _windowsTunServiceReady,
          });
    } on MissingPluginException {
      _rememberAppLog(
        'Native server route path unavailable: Windows runner channel is not registered.',
      );
      return null;
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Native server route path unavailable: ${error.message ?? error.code}',
      );
      return null;
    } catch (error) {
      _rememberAppLog(
        'Native server route path unavailable: ${_describeError(error)}',
      );
      return null;
    }

    if (rawResult is! Map) {
      _rememberAppLog(
        'Native server route path unavailable: runner returned unexpected result.',
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
        'Native server route path unavailable: $failedStep failed$elapsed: $error',
      );
      return null;
    }

    final interfaceAlias = result['interfaceAlias']?.toString().trim();
    final sourceAddress = result['sourceAddress']?.toString().trim();
    final nextHop = result['nextHop']?.toString().trim();
    final selectedAddress = result['remoteAddress']?.toString().trim();
    final interfaceIndex = (result['interfaceIndex'] as num?)?.toInt();
    if (interfaceAlias == null ||
        interfaceAlias.isEmpty ||
        nextHop == null ||
        nextHop.isEmpty ||
        interfaceIndex == null) {
      _rememberAppLog(
        'Native server route path unavailable: runner returned incomplete route details.',
      );
      return null;
    }

    final routes = _decodeNativeHostRouteResults(
      result['routes'],
      interfaceAlias: interfaceAlias,
      interfaceIndex: interfaceIndex,
    );
    _trackTemporaryServerRoutes(routes);

    final path = result['path']?.toString();
    final target = selectedAddress == null || selectedAddress.isEmpty
        ? server
        : server == selectedAddress
        ? server
        : '$server ($selectedAddress)';
    _rememberAppLog(
      'Windows server route setup for $target${elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms'}${path == null ? '' : ' via $path'}.',
    );
    _rememberAppLog(
      'Windows route to ${selectedAddress ?? server}: interface=$interfaceAlias, source=${_orDash(sourceAddress)}, nextHop=$nextHop, hardware=${result['hardwareInterface']}, virtual=${result['virtual']}.',
    );

    return TunRoutingPreparation(
      outboundBindInterface: interfaceAlias,
      serverAddressOverride: InternetAddress.tryParse(server) == null
          ? selectedAddress
          : null,
      hasHostRoute: routes.isNotEmpty,
      hostRoutes: routes,
    );
  }

  List<WindowsHostRoute> _decodeNativeHostRouteResults(
    dynamic decoded, {
    required String interfaceAlias,
    required int interfaceIndex,
  }) {
    final routeItems = decoded is List
        ? decoded
        : decoded == null
        ? const <dynamic>[]
        : <dynamic>[decoded];
    final routes = <WindowsHostRoute>[];
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
      final routeInterfaceAlias =
          item['InterfaceAlias']?.toString().trim() ?? interfaceAlias;
      final routeInterfaceIndex =
          (item['InterfaceIndex'] as num?)?.toInt() ?? interfaceIndex;
      final status = item['Status']?.toString();
      final route = WindowsHostRoute(
        destinationPrefix: destinationPrefix,
        interfaceAlias: routeInterfaceAlias.isEmpty
            ? interfaceAlias
            : routeInterfaceAlias,
        interfaceIndex: routeInterfaceIndex,
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

  void _trackTemporaryServerRoutes(List<WindowsHostRoute> routes) {
    if (routes.isEmpty) {
      return;
    }
    final routesByKey = <String, WindowsHostRoute>{
      for (final route in _temporaryServerRoutes)
        windowsHostRouteKey(route): route,
    };
    for (final route in routes) {
      routesByKey.putIfAbsent(windowsHostRouteKey(route), () => route);
    }
    _temporaryServerRoutes = List<WindowsHostRoute>.unmodifiable(
      routesByKey.values,
    );
  }

  void _forgetTemporaryServerRoutes(List<WindowsHostRoute> routes) {
    if (routes.isEmpty || _temporaryServerRoutes.isEmpty) {
      return;
    }
    final routeKeys = routes.map(windowsHostRouteKey).toSet();
    _temporaryServerRoutes = List<WindowsHostRoute>.unmodifiable(
      _temporaryServerRoutes.where(
        (route) => !routeKeys.contains(windowsHostRouteKey(route)),
      ),
    );
  }

  Future<void> _installTemporaryXrayTunRoutes({
    required String interfaceAlias,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    if (_temporaryTunRoutes.isNotEmpty) {
      await _removeTemporaryTunRoutes();
    }

    final adapterKey = _xrayTunAdapterKey(
      interfaceAlias,
      tunIpMode,
      dnsSettings,
    );
    final routeOnlyAllowed = _preparedXrayTunAdapterKeys.contains(adapterKey);
    Object? rawResult;
    try {
      rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('prepareXrayTunRoutes', <String, Object?>{
            'interfaceAlias': interfaceAlias,
            'timeoutMs': routeOnlyAllowed ? 2500 : 7000,
            'tunIpMode': tunIpMode.name,
            'address': '172.19.0.1',
            'prefixLength': 30,
            'metric': 1,
            'dnsServers': _xrayTunDnsServersText(dnsSettings, tunIpMode),
            'useService': _windowsTunServiceReady,
            'routeOnlyAllowed': routeOnlyAllowed,
          });
    } on MissingPluginException {
      _rememberAppLog(
        'Native Xray TUN setup unavailable: Windows runner channel is not registered.',
      );
      rawResult = null;
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Native Xray TUN setup unavailable: ${error.message ?? error.code}',
      );
      rawResult = null;
    } catch (error) {
      _rememberAppLog(
        'Native Xray TUN setup unavailable: ${_describeError(error)}',
      );
      rawResult = null;
    }

    final setup = _decodeWindowsXrayTunSetup(rawResult);
    if (setup == null) {
      throw StateError('Failed to prepare Xray TUN adapter and routes.');
    }

    _temporaryTunRoutes = List<WindowsTunRoute>.unmodifiable(setup.routes);
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

  String _xrayTunAdapterKey(
    String interfaceAlias,
    TunIpMode tunIpMode,
    DnsSettings dnsSettings,
  ) {
    final dnsKey = _xrayTunDnsServersText(dnsSettings, tunIpMode);
    return '${interfaceAlias.trim().toLowerCase()}|${tunIpMode.name}|$dnsKey';
  }

  String _xrayTunDnsServersText(DnsSettings dnsSettings, TunIpMode tunIpMode) {
    return dnsSettings.serversFor(tunIpMode).join(',');
  }

  WindowsTunSetup? _decodeWindowsXrayTunSetup(Object? rawResult) {
    if (rawResult is! Map) {
      _rememberAppLog(
        'Prepared Xray TUN adapter and routes, but the native runner returned no usable details.',
      );
      return null;
    }

    final decoded = rawResult.cast<Object?, Object?>();
    final elapsedMs = decoded['elapsedMs']?.toString();
    if (decoded['ok'] != true) {
      final failedStep = decoded['failedStep']?.toString() ?? 'unknown';
      final error = decoded['error']?.toString() ?? 'unknown error';
      final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
      _rememberAppLog(
        'Prepared Xray TUN adapter and routes failed: $failedStep$elapsed: $error',
      );
      return null;
    }

    final adapter = (decoded['Adapter'] as Map?)?.cast<Object?, Object?>();
    final alias =
        decoded['interfaceAlias']?.toString().trim() ??
        adapter?['InterfaceAlias']?.toString().trim();
    final index =
        (decoded['interfaceIndex'] as num?)?.toInt() ??
        (adapter?['InterfaceIndex'] as num?)?.toInt();
    if (alias == null || alias.isEmpty || index == null || index <= 0) {
      _rememberAppLog(
        'Prepared Xray TUN adapter and routes, but adapter details were incomplete: "$rawResult".',
      );
      return null;
    }

    final setupKind = decoded['setupKind']?.toString();
    switch (setupKind) {
      case 'serviceIpv4':
        _rememberAppLog(
          'Xray TUN adapter configured through EntropyVPN Service.',
        );
      case 'fastNativeApi':
        _rememberAppLog(
          'Xray TUN adapter configured with native Windows API setup.',
        );
      case 'routeOnly':
        _rememberAppLog(
          'Xray TUN adapter was previously configured; using route-only setup.',
        );
    }

    final status = decoded['status'] ?? adapter?['Status'];
    _rememberAppLog(
      'Xray TUN adapter ready: interface=$alias, ifIndex=$index, status=$status.',
    );
    _logWindowsXrayTunTiming(decoded);
    _logWindowsXrayTunConfiguration(decoded);

    final routeItems = decoded['routes'] is List
        ? decoded['routes'] as List
        : decoded['Routes'] is List
        ? decoded['Routes'] as List
        : decoded['Routes'] == null
        ? const <dynamic>[]
        : <dynamic>[decoded['Routes']];
    final routes = <WindowsTunRoute>[];
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
      final route = WindowsTunRoute(
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

    return WindowsTunSetup(
      routes: routes,
      networkChanged: decoded['NetworkChanged'] == true,
    );
  }

  void _logWindowsXrayTunTiming(Map<Object?, Object?> decoded) {
    final timings = (decoded['Timings'] as List?)
        ?.map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .join(', ');
    if (timings != null && timings.trim().isNotEmpty) {
      _rememberAppLog('Xray TUN adapter setup timing: $timings.');
      return;
    }

    _rememberAppLog(
      'Xray TUN adapter setup timing: prepare=${_orDash(decoded['elapsedMs']?.toString())}ms, wait_adapter=${_orDash(decoded['waitMs']?.toString())}ms, configure=${_orDash(decoded['configureMs']?.toString())}ms, routes=${_orDash(decoded['routeMs']?.toString())}ms.',
    );
  }

  void _logWindowsXrayTunConfiguration(Map<Object?, Object?> decoded) {
    final changes = (decoded['Changes'] as List?)
        ?.map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .join(', ');
    if (changes != null && changes.trim().isNotEmpty) {
      _rememberAppLog('Configured Xray TUN adapter DNS/IP settings: $changes.');
    } else {
      _rememberAppLog(
        'Configured Xray TUN adapter DNS/IP settings: ipv4-address=172.19.0.1/30 (${decoded['addressStatus']}), ipv4-metric=1 (${decoded['metricStatus']}), dns=${decoded['dnsStatus']}.',
      );
    }

    final warnings = (decoded['Warnings'] as List?)
        ?.map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .join('; ');
    if (warnings != null && warnings.trim().isNotEmpty) {
      _rememberAppLog(
        'Xray TUN adapter DNS/IP configuration warnings: $warnings',
      );
    }
  }
}
