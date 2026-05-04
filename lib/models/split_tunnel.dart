import 'package:path/path.dart' as p;

enum SplitTunnelMode { off, whitelist, blacklist }

class SplitTunnelApp {
  const SplitTunnelApp({
    required this.id,
    required this.name,
    required this.path,
  });

  factory SplitTunnelApp.fromPath({
    required String name,
    required String path,
  }) {
    final normalizedPath = path.trim();
    final normalizedName = name.trim().isEmpty
        ? p.basenameWithoutExtension(normalizedPath)
        : name.trim();
    return SplitTunnelApp(
      id: normalizedPath.toLowerCase(),
      name: normalizedName,
      path: normalizedPath,
    );
  }

  final String id;
  final String name;
  final String path;

  String get processName => p.basename(path);

  SplitTunnelApp get normalized =>
      SplitTunnelApp.fromPath(name: name, path: path);

  Map<String, Object?> toJson() {
    return <String, Object?>{'id': id, 'name': name, 'path': path};
  }

  factory SplitTunnelApp.fromJson(Map<String, dynamic> json) {
    return SplitTunnelApp.fromPath(
      name: (json['name'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
    );
  }
}

class SplitTunnelSettings {
  const SplitTunnelSettings({
    this.mode = SplitTunnelMode.off,
    this.apps = const <SplitTunnelApp>[],
  });

  final SplitTunnelMode mode;
  final List<SplitTunnelApp> apps;

  bool get isEnabled => mode != SplitTunnelMode.off;
  bool get hasSelectedApps => apps.isNotEmpty;

  SplitTunnelSettings get normalized {
    final normalizedApps = <SplitTunnelApp>[];
    final seen = <String>{};
    for (final app in apps) {
      final normalized = app.normalized;
      if (normalized.path.isEmpty || !seen.add(normalized.id)) {
        continue;
      }
      normalizedApps.add(normalized);
    }
    normalizedApps.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return SplitTunnelSettings(mode: mode, apps: normalizedApps);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'mode': mode.name,
      'apps': apps.map((app) => app.toJson()).toList(growable: false),
    };
  }

  factory SplitTunnelSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const SplitTunnelSettings();
    }

    return SplitTunnelSettings(
      mode: _splitTunnelModeByName(json['mode'] as String?),
      apps: ((json['apps'] as List<dynamic>?) ?? const <dynamic>[])
          .map((item) {
            if (item is Map<String, dynamic>) {
              return SplitTunnelApp.fromJson(item);
            }
            if (item is Map) {
              return SplitTunnelApp.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              );
            }
            return null;
          })
          .whereType<SplitTunnelApp>()
          .toList(growable: false),
    ).normalized;
  }
}

SplitTunnelMode _splitTunnelModeByName(String? name) {
  for (final mode in SplitTunnelMode.values) {
    if (mode.name == name) {
      return mode;
    }
  }
  return SplitTunnelMode.off;
}
