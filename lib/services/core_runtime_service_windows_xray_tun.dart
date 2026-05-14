part of 'core_runtime_service.dart';

extension CoreRuntimeServiceWindowsXrayTun on CoreRuntimeService {
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
    var setupKind = WindowsTunSetupKind.full;
    var setup = await _prepareWindowsXrayTunFastRoutes(
      interfaceAlias: interfaceAlias,
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
    );
    if (setup != null) {
      setupKind =
          setup.fastConfigureMethod == WindowsTunFastConfigureMethod.nativeApi
          ? WindowsTunSetupKind.fastNativeApi
          : WindowsTunSetupKind.fastNetsh;
    } else {
      setup = _preparedXrayTunAdapterKeys.contains(adapterKey)
          ? await _prepareWindowsXrayTunRoutesOnly(
              interfaceAlias: interfaceAlias,
              tunIpMode: tunIpMode,
            )
          : null;
      if (setup != null) {
        setupKind = WindowsTunSetupKind.routeOnly;
      }
    }
    setup ??= await _prepareWindowsXrayTunAdapterAndRoutes(
      interfaceAlias: interfaceAlias,
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
    );
    if (setup == null) {
      throw StateError('Failed to prepare Xray TUN adapter and routes.');
    }

    switch (setupKind) {
      case WindowsTunSetupKind.fastNativeApi:
        _rememberAppLog(
          'Xray TUN adapter configured with native Windows API setup.',
        );
      case WindowsTunSetupKind.fastNetsh:
        _rememberAppLog(
          'Xray TUN adapter configured with fast netsh/route.exe setup.',
        );
      case WindowsTunSetupKind.routeOnly:
        _rememberAppLog(
          'Xray TUN adapter was previously configured; using route-only setup.',
        );
      case WindowsTunSetupKind.full:
        break;
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

  Future<WindowsTunSetup?> _prepareWindowsXrayTunFastRoutes({
    required String interfaceAlias,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
  }) async {
    if (tunIpMode != TunIpMode.ipv4) {
      return null;
    }
    if (_windowsTunServiceReady) {
      final serviceSetup = await _prepareWindowsXrayTunIpv4RoutesWithService(
        interfaceAlias: interfaceAlias,
        dnsSettings: dnsSettings,
      );
      if (serviceSetup != null) {
        return serviceSetup;
      }
    } else {
      final nativeSetup = await _prepareWindowsXrayTunIpv4RoutesWithNativeApi(
        interfaceAlias: interfaceAlias,
        dnsSettings: dnsSettings,
      );
      if (nativeSetup != null) {
        return nativeSetup;
      }
    }

    final adapter = await _waitForNetshIpv4Interface(
      interfaceAlias,
      timeout: const Duration(milliseconds: 2500),
    );
    if (adapter == null) {
      return null;
    }

    var configureMethod = WindowsTunFastConfigureMethod.nativeApi;
    var configureStopwatch = Stopwatch()..start();
    var configured = await _configureXrayTunIpv4WithNativeApi(
      adapter,
      dnsSettings: dnsSettings,
    );
    configureStopwatch.stop();
    if (!configured) {
      configureMethod = WindowsTunFastConfigureMethod.netsh;
      configureStopwatch = Stopwatch()..start();
      configured = await _configureXrayTunIpv4WithNetsh(
        adapter,
        dnsSettings: dnsSettings,
      );
      configureStopwatch.stop();
    }
    if (!configured) {
      return null;
    }

    final routes = <WindowsTunRoute>[
      WindowsTunRoute(
        destinationPrefix: '0.0.0.0/1',
        interfaceAlias: adapter.name,
        interfaceIndex: adapter.index,
        nextHop: '0.0.0.0',
      ),
      WindowsTunRoute(
        destinationPrefix: '128.0.0.0/1',
        interfaceAlias: adapter.name,
        interfaceIndex: adapter.index,
        nextHop: '0.0.0.0',
      ),
    ];

    final stopwatch = Stopwatch()..start();
    for (final route in routes) {
      final parts = routeExeIpv4DestinationParts(route.destinationPrefix);
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
          !routeOutputSaysAlreadyExists(result.stdout, result.stderr)) {
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
      'Configured Xray TUN adapter DNS/IP settings: ipv4-address=172.19.0.1/30, ipv4-metric=1, dns=${_xrayTunDnsServersText(dnsSettings, TunIpMode.ipv4)}.',
    );

    return WindowsTunSetup(
      routes: routes,
      networkChanged: false,
      fastConfigureMethod: configureMethod,
    );
  }

  Future<WindowsTunSetup?> _prepareWindowsXrayTunIpv4RoutesWithService({
    required String interfaceAlias,
    required DnsSettings dnsSettings,
  }) async {
    Map<String, String> response;
    try {
      response = await _runWindowsServiceHelper(
        <String>[
          'prepare-xray-tun-ipv4-routes',
          '--interface-alias',
          interfaceAlias,
          '--timeout-ms',
          '2500',
          '--address',
          '172.19.0.1',
          '--prefix-length',
          '30',
          '--metric',
          '1',
          '--dns-servers',
          _xrayTunDnsServersText(dnsSettings, TunIpMode.ipv4),
        ],
        timeout: const Duration(seconds: 8),
        timingLabel: 'xray_tun_ipv4',
      );
    } catch (error) {
      _rememberAppLog(
        'Service Xray TUN IPv4 route setup unavailable: ${_describeError(error)}',
      );
      return null;
    }

    final elapsedMs = response['elapsedMs'];
    if (response['resultOk'] != '1') {
      final failedStep = response['failedStep'] ?? 'unknown';
      final routePrefix = response['routePrefix'];
      final error = _decodeWindowsServiceText(response, 'errorB64').trim();
      final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
      final target = routePrefix == null
          ? failedStep
          : '$failedStep $routePrefix';
      _rememberAppLog(
        'Service Xray TUN IPv4 route setup unavailable: $target failed$elapsed: ${error.isEmpty ? 'unknown error' : error}',
      );
      return null;
    }

    final alias = _decodeWindowsServiceText(
      response,
      'interfaceAliasB64',
    ).trim();
    final index = int.tryParse(response['interfaceIndex'] ?? '');
    if (alias.isEmpty || index == null || index <= 0) {
      _rememberAppLog(
        'Service Xray TUN IPv4 route setup unavailable: helper returned incomplete adapter details.',
      );
      return null;
    }

    final routeCount = int.tryParse(response['routeCount'] ?? '') ?? 0;
    final routes = <WindowsTunRoute>[];
    for (var routeIndex = 0; routeIndex < routeCount; routeIndex += 1) {
      final destinationPrefix = response['route.$routeIndex.destinationPrefix']
          ?.trim();
      final nextHop = response['route.$routeIndex.nextHop']?.trim();
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
      routes.add(route);
      final status = response['route.$routeIndex.status'];
      _rememberAppLog(
        'Xray TUN route ${route.destinationPrefix} via ${route.interfaceAlias} ${status == 'created' ? 'created' : 'already existed'}.',
      );
    }
    if (routes.isEmpty) {
      _rememberAppLog(
        'Service Xray TUN IPv4 route setup unavailable: helper returned no routes.',
      );
      return null;
    }

    _rememberAppLog(
      'Xray TUN adapter ready: interface=$alias, ifIndex=$index, status=${response['status']}.',
    );
    final retryDiagnostics = _windowsServiceXrayTunRetryDiagnostics(response);
    _rememberAppLog(
      'Xray TUN adapter setup timing: service_prepare=${_orDash(elapsedMs)}ms, wait_adapter=${_orDash(response['waitMs'])}ms, native_configure=${_orDash(response['configureMs'])}ms, native_routes=${_orDash(response['routeMs'])}ms$retryDiagnostics.',
    );
    _rememberAppLog(
      'Configured Xray TUN adapter DNS/IP settings: ipv4-address=172.19.0.1/30 (${response['addressStatus']}), ipv4-metric=1 (${response['metricStatus']}), dns=${_xrayTunDnsServersText(dnsSettings, TunIpMode.ipv4)} (${response['dnsStatus']}).',
    );

    return WindowsTunSetup(
      routes: routes,
      networkChanged: false,
      fastConfigureMethod: WindowsTunFastConfigureMethod.nativeApi,
    );
  }

  String _windowsServiceXrayTunRetryDiagnostics(Map<String, String> response) {
    final attempts = response['attempts'];
    final retrySleepMs = response['retrySleepMs'];
    final configureTotalMs = response['configureTotalMs'];
    final routeTotalMs = response['routeTotalMs'];
    final interfaceChangeWaits = response['interfaceChangeWaits'];
    final highResWaits = response['highResWaits'];
    final fallbackSleepWaits = response['fallbackSleepWaits'];
    final yieldWaits = response['yieldWaits'];
    if (attempts == null &&
        retrySleepMs == null &&
        configureTotalMs == null &&
        routeTotalMs == null &&
        interfaceChangeWaits == null &&
        highResWaits == null &&
        fallbackSleepWaits == null &&
        yieldWaits == null) {
      return '';
    }

    final parts = <String>[
      'attempts=${_orDash(attempts)}',
      'retry_sleep=${_orDash(retrySleepMs)}ms',
      'interface_change_waits=${_orDash(interfaceChangeWaits)}',
      'high_res_waits=${_orDash(highResWaits)}',
      'fallback_sleep_waits=${_orDash(fallbackSleepWaits)}',
      'yield_waits=${_orDash(yieldWaits)}',
      'configure_total=${_orDash(configureTotalMs)}ms',
      'route_total=${_orDash(routeTotalMs)}ms',
    ];
    final lastRetryStep = response['lastRetryStep']?.trim();
    if (lastRetryStep != null && lastRetryStep.isNotEmpty) {
      final lastRetryCode = response['lastRetryErrorCode'];
      parts.add('last_retry=$lastRetryStep/${_orDash(lastRetryCode)}');
      final lastRetryWait = response['lastRetryWait']?.trim();
      if (lastRetryWait != null && lastRetryWait.isNotEmpty) {
        parts.add('last_retry_wait=$lastRetryWait');
      }
      final lastRetryRoutePrefix = response['lastRetryRoutePrefix']?.trim();
      if (lastRetryRoutePrefix != null && lastRetryRoutePrefix.isNotEmpty) {
        parts.add('last_retry_route=$lastRetryRoutePrefix');
      }
    }
    return ', ${parts.join(', ')}';
  }

  Future<WindowsTunSetup?> _prepareWindowsXrayTunIpv4RoutesWithNativeApi({
    required String interfaceAlias,
    required DnsSettings dnsSettings,
  }) async {
    Object? rawResult;
    try {
      rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('prepareXrayTunIpv4Routes', <String, Object?>{
            'interfaceAlias': interfaceAlias,
            'timeoutMs': 2500,
            'address': '172.19.0.1',
            'prefixLength': 30,
            'metric': 1,
            'dnsServers': _xrayTunDnsServersText(dnsSettings, TunIpMode.ipv4),
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
      'Configured Xray TUN adapter DNS/IP settings: ipv4-address=172.19.0.1/30 (${result['addressStatus']}), ipv4-metric=1 (${result['metricStatus']}), dns=${_xrayTunDnsServersText(dnsSettings, TunIpMode.ipv4)} (${result['dnsStatus']}).',
    );

    return WindowsTunSetup(
      routes: routes,
      networkChanged: false,
      fastConfigureMethod: WindowsTunFastConfigureMethod.nativeApi,
    );
  }

  Future<bool> _configureXrayTunIpv4WithNativeApi(
    NetshIpv4Interface adapter, {
    required DnsSettings dnsSettings,
  }) async {
    if (!Platform.isWindows) {
      return false;
    }

    Object? rawResult;
    try {
      rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('configureXrayTunIpv4', <String, Object?>{
            'interfaceIndex': adapter.index,
            'address': '172.19.0.1',
            'prefixLength': 30,
            'metric': 1,
            'dnsServers': _xrayTunDnsServersText(dnsSettings, TunIpMode.ipv4),
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
    NetshIpv4Interface adapter, {
    required DnsSettings dnsSettings,
  }) async {
    final dnsServers = dnsSettings.serversFor(TunIpMode.ipv4);
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
      ..._buildNetshIpv4DnsCommands(adapter, dnsServers),
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

  List<({String label, List<String> args})> _buildNetshIpv4DnsCommands(
    NetshIpv4Interface adapter,
    List<String> dnsServers,
  ) {
    if (dnsServers.isEmpty) {
      return const <({String label, List<String> args})>[];
    }
    return <({String label, List<String> args})>[
      (
        label: 'netsh_xray_tun_ipv4_set_dns',
        args: <String>[
          'interface',
          'ipv4',
          'set',
          'dnsservers',
          'name=${adapter.name}',
          'source=static',
          'address=${dnsServers.first}',
          'register=none',
          'validate=no',
        ],
      ),
      for (var index = 1; index < dnsServers.length; index += 1)
        (
          label: 'netsh_xray_tun_ipv4_add_dns',
          args: <String>[
            'interface',
            'ipv4',
            'add',
            'dnsservers',
            'name=${adapter.name}',
            'address=${dnsServers[index]}',
            'index=${index + 1}',
            'validate=no',
          ],
        ),
    ];
  }

  Future<NetshIpv4Interface?> _waitForNetshIpv4Interface(
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
        final adapter = parseNetshIpv4Interface(
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

  Future<WindowsTunSetup?> _prepareWindowsXrayTunRoutesOnly({
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

  WindowsTunSetup? _decodeWindowsXrayTunSetup(
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

  Future<WindowsTunSetup?> _prepareWindowsXrayTunAdapterAndRoutes({
    required String interfaceAlias,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
  }) async {
    const script = r'''
param(
  [string]$InterfaceAlias,
  [int]$TimeoutMs,
  [string]$TunIpMode,
  [string]$DnsServers
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
    $dnsServers = @(
      $DnsServers -split ',' |
        ForEach-Object { [string]$_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($dnsServers.Count -eq 0) {
      throw 'DNS server list is empty.'
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
          'DnsServers': _xrayTunDnsServersText(dnsSettings, tunIpMode),
        },
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to prepare Xray TUN adapter and routes: ${_describeError(result.stderr)}',
        );
        return null;
      }

      return _decodeWindowsXrayTunSetup(
        result.stdout.toString().trim(),
        unexpectedOutputContext: 'Prepared Xray TUN adapter and routes',
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to prepare Xray TUN adapter and routes: ${_describeError(error)}',
      );
      return null;
    }
  }
}
