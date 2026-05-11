import 'dart:io';

import 'vpn_profile.dart';

class DnsSettings {
  const DnsSettings({
    this.ipv4Servers = defaultIpv4Servers,
    this.ipv6Servers = defaultIpv6Servers,
  });

  static const List<String> defaultIpv4Servers = <String>['1.1.1.1', '8.8.8.8'];
  static const List<String> defaultIpv6Servers = <String>[
    '2606:4700:4700::1111',
    '2001:4860:4860::8888',
  ];

  final List<String> ipv4Servers;
  final List<String> ipv6Servers;

  DnsSettings get normalized {
    return DnsSettings(
      ipv4Servers: _normalizeServers(
        ipv4Servers,
        InternetAddressType.IPv4,
        defaultIpv4Servers,
      ),
      ipv6Servers: _normalizeServers(
        ipv6Servers,
        InternetAddressType.IPv6,
        defaultIpv6Servers,
      ),
    );
  }

  List<String> serversFor(TunIpMode mode) {
    final settings = normalized;
    return switch (mode) {
      TunIpMode.ipv4 => settings.ipv4Servers,
      TunIpMode.dualStack => <String>[
        ...settings.ipv4Servers,
        ...settings.ipv6Servers,
      ],
      TunIpMode.ipv6 => settings.ipv6Servers,
    };
  }

  String displayFor(TunIpMode mode) {
    return serversFor(mode).join(', ');
  }

  String get ipv4InputText => normalized.ipv4Servers.join(', ');
  String get ipv6InputText => normalized.ipv6Servers.join(', ');

  Map<String, Object?> toJson() {
    final settings = normalized;
    return <String, Object?>{
      'ipv4Servers': settings.ipv4Servers,
      'ipv6Servers': settings.ipv6Servers,
    };
  }

  factory DnsSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const DnsSettings();
    }
    return DnsSettings(
      ipv4Servers: _normalizeServers(
        _readStringList(json['ipv4Servers'] ?? json['ipv4']),
        InternetAddressType.IPv4,
        defaultIpv4Servers,
      ),
      ipv6Servers: _normalizeServers(
        _readStringList(json['ipv6Servers'] ?? json['ipv6']),
        InternetAddressType.IPv6,
        defaultIpv6Servers,
      ),
    );
  }

  factory DnsSettings.fromInput({
    required String ipv4Input,
    required String ipv6Input,
  }) {
    return DnsSettings(
      ipv4Servers: _normalizeServers(
        _splitInput(ipv4Input),
        InternetAddressType.IPv4,
        defaultIpv4Servers,
      ),
      ipv6Servers: _normalizeServers(
        _splitInput(ipv6Input),
        InternetAddressType.IPv6,
        defaultIpv6Servers,
      ),
    );
  }

  static List<String> invalidIpv4Input(String input) {
    return _invalidServers(_splitInput(input), InternetAddressType.IPv4);
  }

  static List<String> invalidIpv6Input(String input) {
    return _invalidServers(_splitInput(input), InternetAddressType.IPv6);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DnsSettings &&
            _listEquals(normalized.ipv4Servers, other.normalized.ipv4Servers) &&
            _listEquals(normalized.ipv6Servers, other.normalized.ipv6Servers);
  }

  @override
  int get hashCode {
    final settings = normalized;
    return Object.hash(
      Object.hashAll(settings.ipv4Servers),
      Object.hashAll(settings.ipv6Servers),
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
      .replaceAll('\uFEFF', '')
      .split(RegExp(r'[\s,;]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

List<String> _normalizeServers(
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

List<String> _invalidServers(
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
