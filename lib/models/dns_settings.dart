import 'dart:io';

import 'vpn_profile.dart';

final RegExp _kDnsLabelPattern = RegExp(
  r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
);

enum DnsMode {
  classic,
  doh,
  dot;

  static DnsMode fromName(String? name, {DnsMode fallback = DnsMode.classic}) {
    for (final mode in DnsMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return fallback;
  }
}

class DnsSettings {
  const DnsSettings({
    this.mode = DnsMode.classic,
    this.ipv4Servers = defaultIpv4Servers,
    this.ipv6Servers = defaultIpv6Servers,
    this.dohServers = defaultDohServers,
    this.dotServers = defaultDotServers,
  });

  static const List<String> defaultIpv4Servers = <String>['1.1.1.1', '8.8.8.8'];
  static const List<String> defaultIpv6Servers = <String>[
    '2606:4700:4700::1111',
    '2001:4860:4860::8888',
  ];
  static const List<String> defaultDohServers = <String>[
    'https://1.1.1.1/dns-query',
    'https://8.8.8.8/dns-query',
  ];
  static const List<String> defaultDotServers = <String>[
    '1.1.1.1',
    '8.8.8.8',
  ];

  final DnsMode mode;
  final List<String> ipv4Servers;
  final List<String> ipv6Servers;
  final List<String> dohServers;
  final List<String> dotServers;

  DnsSettings get normalized {
    return DnsSettings(
      mode: mode,
      ipv4Servers: _normalizeIpServers(
        ipv4Servers,
        InternetAddressType.IPv4,
        defaultIpv4Servers,
      ),
      ipv6Servers: _normalizeIpServers(
        ipv6Servers,
        InternetAddressType.IPv6,
        defaultIpv6Servers,
      ),
      dohServers: _firstOnly(
        _normalizeStringServers(
          dohServers,
          _isValidDohServer,
          defaultDohServers,
        ),
      ),
      dotServers: _firstOnly(
        _normalizeStringServers(
          dotServers,
          _isValidDotServer,
          defaultDotServers,
        ),
      ),
    );
  }

  List<String> serversFor(TunIpMode tunIpMode) {
    final settings = normalized;
    return switch (settings.mode) {
      DnsMode.classic => switch (tunIpMode) {
        TunIpMode.ipv4 => settings.ipv4Servers,
        TunIpMode.ipv6 => settings.ipv6Servers,
        TunIpMode.dualStack => <String>[
          ...settings.ipv4Servers,
          ...settings.ipv6Servers,
        ],
      },
      DnsMode.doh => settings.dohServers,
      DnsMode.dot => settings.dotServers,
    };
  }

  // Adapter/OS-level DNS configuration only accepts IP literals (e.g. Windows
  // SetInterfaceDnsSettings, Android VpnService.Builder.addDnsServer). DoH/DoT
  // is applied inside the core's config, so the adapter always gets the
  // plain IPv4/IPv6 fallback list regardless of mode.
  List<String> adapterDnsServersFor(TunIpMode tunIpMode) {
    final settings = normalized;
    return switch (tunIpMode) {
      TunIpMode.ipv4 => settings.ipv4Servers,
      TunIpMode.ipv6 => settings.ipv6Servers,
      TunIpMode.dualStack => <String>[
        ...settings.ipv4Servers,
        ...settings.ipv6Servers,
      ],
    };
  }

  String displayFor(TunIpMode tunIpMode) {
    return serversFor(tunIpMode).join(', ');
  }

  String get ipv4InputText => normalized.ipv4Servers.join(', ');
  String get ipv6InputText => normalized.ipv6Servers.join(', ');
  String get dohInputText => normalized.dohServers.join(', ');
  String get dotInputText => normalized.dotServers.join(', ');

  DnsSettings copyWith({
    DnsMode? mode,
    List<String>? ipv4Servers,
    List<String>? ipv6Servers,
    List<String>? dohServers,
    List<String>? dotServers,
  }) {
    return DnsSettings(
      mode: mode ?? this.mode,
      ipv4Servers: ipv4Servers ?? this.ipv4Servers,
      ipv6Servers: ipv6Servers ?? this.ipv6Servers,
      dohServers: dohServers ?? this.dohServers,
      dotServers: dotServers ?? this.dotServers,
    );
  }

  Map<String, Object?> toJson() {
    final settings = normalized;
    return <String, Object?>{
      'mode': settings.mode.name,
      'ipv4Servers': settings.ipv4Servers,
      'ipv6Servers': settings.ipv6Servers,
      'dohServers': settings.dohServers,
      'dotServers': settings.dotServers,
    };
  }

  factory DnsSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const DnsSettings();
    }
    return DnsSettings(
      mode: DnsMode.fromName(json['mode'] as String?),
      ipv4Servers: _normalizeIpServers(
        _readStringList(json['ipv4Servers'] ?? json['ipv4']),
        InternetAddressType.IPv4,
        defaultIpv4Servers,
      ),
      ipv6Servers: _normalizeIpServers(
        _readStringList(json['ipv6Servers'] ?? json['ipv6']),
        InternetAddressType.IPv6,
        defaultIpv6Servers,
      ),
      dohServers: _normalizeStringServers(
        _readStringList(json['dohServers']),
        _isValidDohServer,
        defaultDohServers,
      ),
      dotServers: _normalizeStringServers(
        _readStringList(json['dotServers']),
        _isValidDotServer,
        defaultDotServers,
      ),
    );
  }

  factory DnsSettings.fromInput({
    DnsMode mode = DnsMode.classic,
    String ipv4Input = '',
    String ipv6Input = '',
    String dohInput = '',
    String dotInput = '',
  }) {
    return DnsSettings(
      mode: mode,
      ipv4Servers: _normalizeIpServers(
        _splitInput(ipv4Input),
        InternetAddressType.IPv4,
        defaultIpv4Servers,
      ),
      ipv6Servers: _normalizeIpServers(
        _splitInput(ipv6Input),
        InternetAddressType.IPv6,
        defaultIpv6Servers,
      ),
      dohServers: _normalizeStringServers(
        _splitInput(dohInput),
        _isValidDohServer,
        defaultDohServers,
      ),
      dotServers: _normalizeStringServers(
        _splitInput(dotInput),
        _isValidDotServer,
        defaultDotServers,
      ),
    );
  }

  static bool isValidDohServer(String value) => _isValidDohServer(value);
  static bool isValidDotServer(String value) => _isValidDotServer(value);

  static List<String> invalidIpv4Input(String input) {
    return _invalidIpServers(_splitInput(input), InternetAddressType.IPv4);
  }

  static List<String> invalidIpv6Input(String input) {
    return _invalidIpServers(_splitInput(input), InternetAddressType.IPv6);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! DnsSettings) {
      return false;
    }
    final a = normalized;
    final b = other.normalized;
    return a.mode == b.mode &&
        _listEquals(a.ipv4Servers, b.ipv4Servers) &&
        _listEquals(a.ipv6Servers, b.ipv6Servers) &&
        _listEquals(a.dohServers, b.dohServers) &&
        _listEquals(a.dotServers, b.dotServers);
  }

  @override
  int get hashCode {
    final settings = normalized;
    return Object.hash(
      settings.mode,
      Object.hashAll(settings.ipv4Servers),
      Object.hashAll(settings.ipv6Servers),
      Object.hashAll(settings.dohServers),
      Object.hashAll(settings.dotServers),
    );
  }
}

List<String> _readStringList(Object? value) {
  if (value is String) {
    return _splitInput(value);
  }
  if (value is List) {
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

List<String> _splitInput(String input) {
  return input
      .replaceAll('﻿', '')
      .split(RegExp(r'[\s,;]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

List<String> _normalizeIpServers(
  List<String> rawServers,
  InternetAddressType type,
  List<String> fallback,
) {
  final servers = <String>[];
  final seen = <String>{};
  for (final rawServer in rawServers) {
    final server = rawServer.trim();
    final parsed = InternetAddress.tryParse(server);
    if (parsed == null || parsed.type != type) {
      continue;
    }
    final key = server.toLowerCase();
    if (seen.add(key)) {
      servers.add(server);
    }
  }
  if (servers.isEmpty) {
    return List<String>.unmodifiable(fallback);
  }
  return List<String>.unmodifiable(servers);
}

List<String> _firstOnly(List<String> servers) {
  if (servers.isEmpty) {
    return const <String>[];
  }
  return List<String>.unmodifiable(<String>[servers.first]);
}

List<String> _normalizeStringServers(
  List<String> rawServers,
  bool Function(String) isValid,
  List<String> fallback,
) {
  final servers = <String>[];
  final seen = <String>{};
  for (final rawServer in rawServers) {
    final server = rawServer.trim();
    if (!isValid(server)) {
      continue;
    }
    final key = server.toLowerCase();
    if (seen.add(key)) {
      servers.add(server);
    }
  }
  if (servers.isEmpty) {
    return List<String>.unmodifiable(fallback);
  }
  return List<String>.unmodifiable(servers);
}

List<String> _invalidIpServers(
  List<String> rawServers,
  InternetAddressType type,
) {
  final invalid = <String>[];
  for (final rawServer in rawServers) {
    final server = rawServer.trim();
    if (server.isEmpty) {
      continue;
    }
    final parsed = InternetAddress.tryParse(server);
    if (parsed == null || parsed.type != type) {
      invalid.add(server);
    }
  }
  return invalid;
}

bool _isValidDohServer(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme.toLowerCase() != 'https') {
    return false;
  }
  final host = uri.host;
  if (host.isEmpty) {
    return false;
  }
  return _isValidDnsHost(host) || InternetAddress.tryParse(host) != null;
}

bool _isValidDotServer(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  var host = trimmed;
  var port = 853;
  // Allow `tls://host[:port]` shorthand.
  if (host.toLowerCase().startsWith('tls://')) {
    host = host.substring(6);
  }
  // IPv6 literal form: `[::1]:853` or `[::1]`.
  if (host.startsWith('[')) {
    final end = host.indexOf(']');
    if (end < 0) {
      return false;
    }
    final inner = host.substring(1, end);
    final remainder = host.substring(end + 1);
    if (remainder.isNotEmpty) {
      if (!remainder.startsWith(':')) {
        return false;
      }
      final parsed = int.tryParse(remainder.substring(1));
      if (parsed == null || parsed < 1 || parsed > 65535) {
        return false;
      }
      port = parsed;
    }
    final ip = InternetAddress.tryParse(inner);
    return port > 0 && ip != null && ip.type == InternetAddressType.IPv6;
  }
  // host[:port] (port allowed only when host is hostname or IPv4).
  final colonCount = host.split(':').length - 1;
  if (colonCount == 1) {
    final parts = host.split(':');
    host = parts[0];
    final parsed = int.tryParse(parts[1]);
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return false;
    }
    port = parsed;
  } else if (colonCount > 1) {
    // Treat as a raw IPv6 address with no port.
    final ip = InternetAddress.tryParse(host);
    return ip != null && ip.type == InternetAddressType.IPv6;
  }
  if (host.isEmpty || port < 1 || port > 65535) {
    return false;
  }
  if (InternetAddress.tryParse(host) != null) {
    return true;
  }
  return _isValidDnsHost(host);
}

bool _isValidDnsHost(String host) {
  if (host.isEmpty || host.length > 253) {
    return false;
  }
  final labels = host.split('.');
  if (labels.isEmpty) {
    return false;
  }
  for (final label in labels) {
    if (!_kDnsLabelPattern.hasMatch(label)) {
      return false;
    }
  }
  // Require at least one dot to avoid bare single-label hosts like "router".
  return labels.length >= 2;
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
