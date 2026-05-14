part of 'core_runtime_service.dart';

extension CoreRuntimeServiceWindowsTemporaryRoutes on CoreRuntimeService {
  Future<void> _removeTemporaryServerRoute({
    List<WindowsHostRoute>? routes,
  }) async {
    final rawRoutesToRemove = routes ?? _temporaryServerRoutes;
    if (routes == null) {
      _temporaryServerRoutes = const <WindowsHostRoute>[];
    }
    final routesToRemove = rawRoutesToRemove
        .where((route) => route.removeWhenUnused)
        .toList(growable: false);
    if (routesToRemove.isEmpty) {
      return;
    }

    final nativeRoutes = routesToRemove
        .where(
          (route) => canRemoveWithNativeIpv4RouteApi(
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
        windowsRouteRemovalKey(
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
            windowsRouteRemovalKey(
              destinationPrefix: route.destinationPrefix,
              interfaceIndex: route.interfaceIndex,
              nextHop: route.nextHop,
            ),
          ),
        )
        .toList(growable: false);

    final routeExeRoutes = routesForFallback
        .where((route) => route.removalTool == WindowsRouteRemovalTool.routeExe)
        .toList(growable: false);
    if (routeExeRoutes.isNotEmpty) {
      await _removeRouteExeServerRoutes(routeExeRoutes);
    }

    final powerShellRoutes = routesForFallback
        .where(
          (route) => route.removalTool == WindowsRouteRemovalTool.powerShell,
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
            utf8.encode(windowsHostRoutesJson(powerShellRoutes)),
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
      rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('removeIpv4Routes', <String, Object?>{
            'routes': routes
                .map(
                  (route) => <String, Object?>{
                    'destinationPrefix': route.destinationPrefix,
                    'interfaceIndex': route.interfaceIndex,
                    'nextHop': route.nextHop,
                  },
                )
                .toList(growable: false),
          });
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
          windowsRouteRemovalKey(
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

  Future<void> _removeRouteExeServerRoutes(
    List<WindowsHostRoute> routes,
  ) async {
    for (final route in routes.reversed) {
      final parts = routeExeIpv4DestinationParts(route.destinationPrefix);
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

  Future<void> _removeTemporaryTunRoutes({
    List<WindowsTunRoute>? routes,
  }) async {
    final routesToRemove = routes ?? _temporaryTunRoutes;
    if (routes == null) {
      _temporaryTunRoutes = const <WindowsTunRoute>[];
    }
    if (routesToRemove.isEmpty) {
      return;
    }

    final nativeRoutes = routesToRemove
        .where(
          (route) => canRemoveWithNativeIpv4RouteApi(
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
        windowsRouteRemovalKey(
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
            windowsRouteRemovalKey(
              destinationPrefix: route.destinationPrefix,
              interfaceIndex: route.interfaceIndex,
              nextHop: route.nextHop,
            ),
          ),
        )
        .toList(growable: false);
    final routeExeRoutes = routesForFallback
        .where(
          (route) =>
              routeExeIpv4DestinationParts(route.destinationPrefix) != null,
        )
        .toList(growable: false);
    if (routeExeRoutes.isNotEmpty) {
      await _removeRouteExeTunRoutes(routeExeRoutes);
    }

    final powerShellRoutes = routesForFallback
        .where(
          (route) => !routeExeRoutes.any(
            (routeExeRoute) =>
                windowsRouteRemovalKey(
                  destinationPrefix: routeExeRoute.destinationPrefix,
                  interfaceIndex: routeExeRoute.interfaceIndex,
                  nextHop: routeExeRoute.nextHop,
                ) ==
                windowsRouteRemovalKey(
                  destinationPrefix: route.destinationPrefix,
                  interfaceIndex: route.interfaceIndex,
                  nextHop: route.nextHop,
                ),
          ),
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
        label: 'remove_xray_tun_routes',
        namedArgs: <String, String>{
          'RoutesBase64': base64Encode(
            utf8.encode(windowsTunRoutesJson(powerShellRoutes)),
          ),
        },
      );
      for (final route in powerShellRoutes) {
        _rememberAppLog('Xray TUN route ${route.destinationPrefix} removed.');
      }
    } catch (error) {
      _rememberAppLog(
        'Failed to remove Xray TUN routes: ${_describeError(error)}',
      );
    }
  }

  Future<void> _removeRouteExeTunRoutes(List<WindowsTunRoute> routes) async {
    for (final route in routes.reversed) {
      final parts = routeExeIpv4DestinationParts(route.destinationPrefix);
      if (parts == null) {
        continue;
      }
      try {
        final result = await _runTimedProcess(
          'route_delete_xray_tun',
          'route.exe',
          <String>['DELETE', parts.address, 'MASK', parts.mask, route.nextHop],
        );
        if (result.exitCode != 0) {
          _rememberAppLog(
            'Failed to remove Xray TUN route ${route.destinationPrefix}: ${_describeError(result.stderr)}',
          );
          continue;
        }
        _rememberAppLog('Xray TUN route ${route.destinationPrefix} removed.');
      } catch (error) {
        _rememberAppLog(
          'Failed to remove Xray TUN route ${route.destinationPrefix}: ${_describeError(error)}',
        );
      }
    }
  }
}
