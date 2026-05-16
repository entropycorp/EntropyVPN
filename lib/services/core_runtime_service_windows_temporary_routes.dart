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
        : await _removeNativeRoutes(
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

    final remainingRoutes = routesToRemove
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
    if (remainingRoutes.isEmpty) {
      return;
    }
    for (final route in remainingRoutes) {
      _rememberAppLog(
        'Failed to remove temporary host route ${route.destinationPrefix}: native route cleanup did not remove it.',
      );
    }
  }

  Future<Set<String>?> _removeNativeRoutes(
    List<({String destinationPrefix, int interfaceIndex, String nextHop})>
    routes, {
    required String label,
  }) async {
    Object? rawResult;
    try {
      rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('removeRoutes', <String, Object?>{
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
        'Native route cleanup unavailable: Windows runner channel is not registered.',
      );
      return null;
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Native route cleanup unavailable: ${error.message ?? error.code}',
      );
      return null;
    } catch (error) {
      _rememberAppLog(
        'Native route cleanup unavailable: ${_describeError(error)}',
      );
      return null;
    }

    if (rawResult is! Map) {
      _rememberAppLog(
        'Native route cleanup unavailable: runner returned unexpected result.',
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
        'Native route cleanup unavailable: $failedStep failed$elapsed: $error',
      );
      return null;
    }

    _rememberAppLog(
      'Native route cleanup $label${elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms'}.',
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
          'Native route cleanup could not remove $destinationPrefix: ${_describeError(item['Error'] ?? 'unknown error')}',
        );
      }
    }
    return handledKeys;
  }

}
