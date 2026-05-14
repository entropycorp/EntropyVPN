part of 'core_runtime_service.dart';

extension CoreRuntimeServiceWindowsServerRouting on CoreRuntimeService {
  Future<TunRoutingPreparation?> _prepareTunServerRouting(
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

  Future<TunRoutingPreparation?> _prepareDomainTunServerRouting(
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

    if (_windowsTunServiceReady) {
      final serviceRouting = await _prepareServiceDomainTunServerRouting(
        host,
        uniqueAddresses,
      );
      if (serviceRouting != null) {
        return serviceRouting;
      }
    }

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
            utf8.encode(serverBypassPrefixesJson(uniqueAddresses)),
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
      return TunRoutingPreparation(
        outboundBindInterface: alias,
        serverAddressOverride: uniqueAddresses.first.address,
        hasHostRoute: routes.isNotEmpty,
        hostRoutes: routes,
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to prepare domain host-route bypass: ${_describeError(error)}',
      );
      return null;
    }
  }

  Future<TunRoutingPreparation?> _prepareServiceDomainTunServerRouting(
    String host,
    List<InternetAddress> addresses,
  ) async {
    final ipv4Addresses = addresses
        .where((address) => address.type == InternetAddressType.IPv4)
        .toList(growable: false);
    if (ipv4Addresses.isEmpty) {
      return null;
    }

    final routes = <WindowsHostRoute>[];
    String? outboundBindInterface;
    for (final address in ipv4Addresses) {
      final routing = await _prepareIpTunServerRouting(address);
      if (routing == null) {
        continue;
      }
      outboundBindInterface ??= routing.outboundBindInterface;
      routes.addAll(routing.hostRoutes);
    }

    if (outboundBindInterface == null) {
      _rememberAppLog(
        'Service-assisted domain host-route bypass could not select a hardware default interface for $host.',
      );
      return null;
    }

    _rememberAppLog(
      'VPN server is a domain name; service-assisted host-route bypass will connect to ${ipv4Addresses.first.address}.',
    );
    return TunRoutingPreparation(
      outboundBindInterface: outboundBindInterface,
      serverAddressOverride: ipv4Addresses.first.address,
      hasHostRoute: routes.isNotEmpty,
      hostRoutes: routes,
    );
  }

  Future<TunRoutingPreparation?> _prepareIpTunServerRouting(
    InternetAddress serverIp,
  ) async {
    if (serverIp.type == InternetAddressType.IPv4) {
      if (_windowsTunServiceReady) {
        final serviceRouting = await _prepareServiceIpv4TunServerRouting(
          serverIp,
        );
        if (serviceRouting != null) {
          return serviceRouting;
        }
      } else {
        final nativeRouting = await _prepareNativeIpv4TunServerRouting(
          serverIp,
        );
        if (nativeRouting != null) {
          return nativeRouting;
        }
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

      final route = decodeWindowsRouteInfo(decoded['Route']);
      if (route == null) {
        _rememberAppLog(
          'Could not resolve Windows route for ${serverIp.address}; using core defaults.',
        );
        return null;
      }

      _rememberAppLog(
        'Windows route to ${serverIp.address}: interface=${route.interfaceAlias}, source=${route.sourceAddress}, nextHop=${route.nextHop}, hardware=${route.hardwareInterface}, virtual=${route.virtual}.',
      );

      final pinnedRoute = decodeWindowsRouteInfo(decoded['PinnedRoute']);
      final pinReason = decoded['PinReason']?.toString();
      if (pinnedRoute == null || pinnedRoute.interfaceIndex == null) {
        _rememberAppLog(
          'No suitable hardware default route found for VPN server bypass; continuing with ${route.interfaceAlias}.',
        );
        return TunRoutingPreparation(
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
      return TunRoutingPreparation(
        outboundBindInterface: routes.isEmpty
            ? route.interfaceAlias
            : pinnedRoute.interfaceAlias,
        serverAddressOverride: null,
        hasHostRoute: routes.isNotEmpty,
        hostRoutes: routes,
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to resolve Windows route for ${serverIp.address}: ${_describeError(error)}',
      );
      return null;
    }
  }

  Future<TunRoutingPreparation?> _prepareServiceIpv4TunServerRouting(
    InternetAddress serverIp,
  ) async {
    Map<String, String> response;
    try {
      response = await _runWindowsServiceHelper(
        <String>[
          'prepare-ipv4-server-route',
          '--remote-address',
          serverIp.address,
        ],
        timeout: const Duration(seconds: 5),
        timingLabel: 'ipv4_server_route',
      );
    } catch (error) {
      _rememberAppLog(
        'Service IPv4 server route path unavailable: ${_describeError(error)}',
      );
      return null;
    }

    final elapsedMs = response['elapsedMs'];
    if (response['resultOk'] != '1') {
      final failedStep = response['failedStep'] ?? 'unknown';
      final error = _decodeWindowsServiceText(response, 'errorB64').trim();
      final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
      _rememberAppLog(
        'Service IPv4 server route path unavailable: $failedStep failed$elapsed: ${error.isEmpty ? 'unknown error' : error}',
      );
      return null;
    }

    final interfaceAlias = _decodeWindowsServiceText(
      response,
      'interfaceAliasB64',
    ).trim();
    final sourceAddress = response['sourceAddress']?.trim();
    final nextHop = response['nextHop']?.trim();
    final destinationPrefix = response['destinationPrefix']?.trim();
    final interfaceIndex = int.tryParse(response['interfaceIndex'] ?? '');
    if (interfaceAlias.isEmpty ||
        nextHop == null ||
        nextHop.isEmpty ||
        destinationPrefix == null ||
        destinationPrefix.isEmpty ||
        interfaceIndex == null) {
      _rememberAppLog(
        'Service IPv4 server route path unavailable: helper returned incomplete route details.',
      );
      return null;
    }

    final createdRoute = response['routeStatus'] == 'created';
    final route = WindowsHostRoute(
      destinationPrefix: destinationPrefix,
      interfaceAlias: interfaceAlias,
      interfaceIndex: interfaceIndex,
      nextHop: nextHop,
      removalTool: WindowsRouteRemovalTool.routeExe,
      removeWhenUnused: createdRoute,
    );
    _trackTemporaryServerRoutes(<WindowsHostRoute>[route]);
    _rememberAppLog(
      'Service IPv4 server route setup${elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms'}.',
    );
    _rememberAppLog(
      'Windows route to ${serverIp.address}: interface=$interfaceAlias, source=${_orDash(sourceAddress)}, nextHop=$nextHop, hardware=${response['hardwareInterface'] == '1'}, virtual=${response['virtual'] == '1'}.',
    );
    _rememberAppLog(
      'Service IPv4 host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) ${createdRoute ? 'created' : 'already existed'}.',
    );
    return TunRoutingPreparation(
      outboundBindInterface: interfaceAlias,
      serverAddressOverride: null,
      hasHostRoute: true,
      hostRoutes: <WindowsHostRoute>[route],
    );
  }

  Future<TunRoutingPreparation?> _prepareNativeIpv4TunServerRouting(
    InternetAddress serverIp,
  ) async {
    Object? rawResult;
    try {
      rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('prepareIpv4ServerRoute', <String, Object?>{
            'remoteAddress': serverIp.address,
          });
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
    final route = WindowsHostRoute(
      destinationPrefix: destinationPrefix,
      interfaceAlias: interfaceAlias,
      interfaceIndex: interfaceIndex,
      nextHop: nextHop,
      removalTool: WindowsRouteRemovalTool.routeExe,
      removeWhenUnused: createdRoute,
    );
    _trackTemporaryServerRoutes(<WindowsHostRoute>[route]);
    _rememberAppLog(
      'Native IPv4 server route setup${elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms'}.',
    );
    _rememberAppLog(
      'Windows route to ${serverIp.address}: interface=$interfaceAlias, source=${_orDash(sourceAddress)}, nextHop=$nextHop, hardware=${result['hardwareInterface']}, virtual=${result['virtual']}.',
    );
    _rememberAppLog(
      'Native IPv4 host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) ${createdRoute ? 'created' : 'already existed'}.',
    );
    return TunRoutingPreparation(
      outboundBindInterface: interfaceAlias,
      serverAddressOverride: null,
      hasHostRoute: true,
      hostRoutes: <WindowsHostRoute>[route],
    );
  }

  Future<TunRoutingPreparation?> _prepareFastIpv4TunServerRouting(
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

      final defaultRoute = parseWindowsDefaultIpv4Route(
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
      if (looksVirtualInterfaceAlias(interfaceAlias)) {
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
            !routeOutputSaysAlreadyExists(addResult.stdout, addResult.stderr)) {
          _rememberAppLog(
            'Fast IPv4 route path unavailable: route add failed with exit ${addResult.exitCode}: ${_describeError(addResult.stderr)}',
          );
          return null;
        }
      }

      final route = WindowsHostRoute(
        destinationPrefix: destinationPrefix,
        interfaceAlias: interfaceAlias,
        interfaceIndex: 0,
        nextHop: defaultRoute.gateway,
        removalTool: WindowsRouteRemovalTool.routeExe,
        removeWhenUnused: !routeExists,
      );
      _trackTemporaryServerRoutes(<WindowsHostRoute>[route]);
      _rememberAppLog(
        'Windows route to ${serverIp.address}: interface=$interfaceAlias, source=${defaultRoute.interfaceAddress}, nextHop=${defaultRoute.gateway}, hardware=true, virtual=false.',
      );
      _rememberAppLog(
        'Fast IPv4 host route ${route.destinationPrefix} via ${route.interfaceAlias} (${route.nextHop}) ${routeExists ? 'already existed' : 'created'}.',
      );
      return TunRoutingPreparation(
        outboundBindInterface: interfaceAlias,
        serverAddressOverride: null,
        hasHostRoute: true,
        hostRoutes: <WindowsHostRoute>[route],
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
          if (windowsAddressMatchesTunIpMode(address, tunIpMode))
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

  Future<String?> _resolveIpv4InterfaceAlias(String interfaceAddress) async {
    final result = await _runTimedProcess(
      'netsh_ipv4_addresses',
      'netsh.exe',
      <String>['interface', 'ipv4', 'show', 'addresses'],
    );
    if (result.exitCode != 0) {
      return null;
    }
    return parseNetshInterfaceAliasForAddress(
      result.stdout.toString(),
      interfaceAddress,
    );
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
    return routePrintHasIpv4HostRoute(
      result.stdout.toString(),
      address,
      nextHop: nextHop,
    );
  }

  List<WindowsHostRoute> _decodeHostRouteResults(
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
      final status = item['Status']?.toString();
      final route = WindowsHostRoute(
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
}
