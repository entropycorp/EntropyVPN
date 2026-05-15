import 'dart:io';

import 'package:flutter/services.dart';

import '../models/split_tunnel.dart';

class WindowsAppCatalogService {
  static const MethodChannel _androidControlChannel = MethodChannel(
    'entropy_vpn/control',
  );
  static const MethodChannel _windowsAppCatalogChannel = MethodChannel(
    'entropy_vpn/windows_app_catalog',
  );

  List<SplitTunnelApp>? _cachedApplications;
  Future<List<SplitTunnelApp>>? _loadingApplications;

  Future<List<SplitTunnelApp>> loadApplications({bool refresh = false}) {
    final cachedApplications = _cachedApplications;
    if (!refresh && cachedApplications != null) {
      return Future<List<SplitTunnelApp>>.value(cachedApplications);
    }

    final loadingApplications = _loadingApplications;
    if (loadingApplications != null) {
      return loadingApplications;
    }

    final future = _loadApplications()
        .then((applications) {
          final cached = List<SplitTunnelApp>.unmodifiable(applications);
          _cachedApplications = cached;
          return cached;
        })
        .whenComplete(() {
          _loadingApplications = null;
        });
    _loadingApplications = future;
    return future;
  }

  Future<List<SplitTunnelApp>> _loadApplications() async {
    if (Platform.isAndroid) {
      return _loadAndroidApplications();
    }

    if (!Platform.isWindows) {
      return const <SplitTunnelApp>[];
    }

    return _loadWindowsApplicationsNative();
  }

  Future<List<SplitTunnelApp>> _loadWindowsApplicationsNative() async {
    try {
      final rawItems = await _windowsAppCatalogChannel
          .invokeListMethod<dynamic>('listApplications');
      return _decodeApplications(rawItems ?? const <dynamic>[]);
    } on MissingPluginException {
      return const <SplitTunnelApp>[];
    } on PlatformException {
      return const <SplitTunnelApp>[];
    }
  }

  Future<List<SplitTunnelApp>> _loadAndroidApplications() async {
    try {
      final rawItems = await _androidControlChannel.invokeListMethod<dynamic>(
        'listInstalledApps',
      );
      return _decodeApplications(rawItems ?? const <dynamic>[]);
    } catch (_) {
      return const <SplitTunnelApp>[];
    }
  }

  List<SplitTunnelApp> _decodeApplications(dynamic decoded) {
    final rawItems = decoded is List
        ? decoded
        : decoded is Map
        ? <dynamic>[decoded]
        : const <dynamic>[];
    final apps = <SplitTunnelApp>[];
    final seen = <String>{};

    for (final item in rawItems) {
      if (item is! Map) {
        continue;
      }
      final name = item['name']?.toString() ?? '';
      final path = item['path']?.toString() ?? '';
      final app = SplitTunnelApp.fromPath(name: name, path: path);
      if (app.path.isEmpty || !seen.add(app.id)) {
        continue;
      }
      apps.add(app);
    }

    apps.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return apps;
  }
}
