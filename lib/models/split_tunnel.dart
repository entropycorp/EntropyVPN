import 'dart:io';

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

class SplitTunnelDomain {
  const SplitTunnelDomain({
    required this.id,
    required this.value,
    required this.matchSuffix,
  });

  factory SplitTunnelDomain.fromInput(String input) {
    final parsed = _parseDomainInput(input);
    return SplitTunnelDomain(
      id: parsed.matchSuffix,
      value: parsed.displayValue,
      matchSuffix: parsed.matchSuffix,
    );
  }

  final String id;
  final String value;
  final String matchSuffix;

  SplitTunnelDomain get normalized => SplitTunnelDomain.fromInput(value);

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'value': value,
      'matchSuffix': matchSuffix,
    };
  }

  factory SplitTunnelDomain.fromJson(Map<String, dynamic> json) {
    return SplitTunnelDomain.fromInput(
      (json['value'] ?? json['domain'] ?? json['matchSuffix'] ?? '').toString(),
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

class DomainSplitTunnelSettings {
  const DomainSplitTunnelSettings({
    this.mode = SplitTunnelMode.off,
    this.domains = const <SplitTunnelDomain>[],
  });

  final SplitTunnelMode mode;
  final List<SplitTunnelDomain> domains;

  bool get isEnabled => mode != SplitTunnelMode.off;
  bool get hasSelectedDomains => domains.isNotEmpty;

  DomainSplitTunnelSettings get normalized {
    final normalizedDomains = <SplitTunnelDomain>[];
    final seen = <String>{};
    for (final domain in domains) {
      try {
        final normalized = domain.normalized;
        if (normalized.matchSuffix.isEmpty || !seen.add(normalized.id)) {
          continue;
        }
        normalizedDomains.add(normalized);
      } on FormatException {
        continue;
      }
    }
    normalizedDomains.sort(
      (left, right) => left.matchSuffix.toLowerCase().compareTo(
        right.matchSuffix.toLowerCase(),
      ),
    );
    return DomainSplitTunnelSettings(mode: mode, domains: normalizedDomains);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'mode': mode.name,
      'domains': domains
          .map((domain) => domain.toJson())
          .toList(growable: false),
    };
  }

  factory DomainSplitTunnelSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const DomainSplitTunnelSettings();
    }

    return DomainSplitTunnelSettings(
      mode: _splitTunnelModeByName(json['mode'] as String?),
      domains: ((json['domains'] as List<dynamic>?) ?? const <dynamic>[])
          .map((item) {
            try {
              if (item is String) {
                return SplitTunnelDomain.fromInput(item);
              }
              if (item is Map<String, dynamic>) {
                return SplitTunnelDomain.fromJson(item);
              }
              if (item is Map) {
                return SplitTunnelDomain.fromJson(
                  item.map((key, value) => MapEntry(key.toString(), value)),
                );
              }
            } on FormatException {
              return null;
            }
            return null;
          })
          .whereType<SplitTunnelDomain>()
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

_ParsedDomainInput _parseDomainInput(String input) {
  var value = input
      .trim()
      .replaceAll('\uFEFF', '')
      .replaceAll(RegExp(r'\s+'), '')
      .toLowerCase();
  if (value.isEmpty) {
    throw const FormatException('Domain is empty.');
  }

  final uriHost = _tryParseDomainUriHost(value);
  if (uriHost != null) {
    value = uriHost;
  } else {
    final delimiterIndex = value.indexOf(RegExp(r'[/#?]'));
    if (delimiterIndex >= 0) {
      value = value.substring(0, delimiterIndex);
    }
    final userInfoIndex = value.lastIndexOf('@');
    if (userInfoIndex >= 0) {
      value = value.substring(userInfoIndex + 1);
    }
    value = _stripPort(value);
  }

  var wildcard = false;
  if (value.startsWith('*.')) {
    wildcard = true;
    value = value.substring(2);
  } else if (value.startsWith('.')) {
    wildcard = true;
    value = value.substring(1);
  }

  value = value.replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (!wildcard && value.startsWith('www.')) {
    final withoutWww = value.substring(4);
    if (withoutWww.contains('.')) {
      value = withoutWww;
    }
  }

  value = value.replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (value.isEmpty || value.contains('..')) {
    throw const FormatException('Domain is invalid.');
  }
  if (RegExp(r'[\s/:?#@\[\]]').hasMatch(value)) {
    throw const FormatException('Domain is invalid.');
  }
  if (InternetAddress.tryParse(value) != null) {
    throw const FormatException('Domain split tunneling expects domains.');
  }

  return _ParsedDomainInput(
    displayValue: wildcard ? '*.$value' : value,
    matchSuffix: value,
  );
}

String? _tryParseDomainUriHost(String value) {
  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme && uri.host.trim().isNotEmpty) {
    return uri.host.trim().toLowerCase();
  }

  final schemeRelativeUri = Uri.tryParse('https:$value');
  if (value.startsWith('//') &&
      schemeRelativeUri != null &&
      schemeRelativeUri.host.trim().isNotEmpty) {
    return schemeRelativeUri.host.trim().toLowerCase();
  }
  return null;
}

String _stripPort(String value) {
  if (value.startsWith('[')) {
    final end = value.indexOf(']');
    if (end > 0) {
      return value.substring(1, end);
    }
  }

  final colonCount = ':'.allMatches(value).length;
  if (colonCount == 1) {
    final colonIndex = value.lastIndexOf(':');
    final port = value.substring(colonIndex + 1);
    if (RegExp(r'^\d+$').hasMatch(port)) {
      return value.substring(0, colonIndex);
    }
  }
  return value;
}

class _ParsedDomainInput {
  const _ParsedDomainInput({
    required this.displayValue,
    required this.matchSuffix,
  });

  final String displayValue;
  final String matchSuffix;
}
