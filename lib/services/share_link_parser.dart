import 'dart:convert';

import '../models/vpn_profile.dart';

class ShareLinkParser {
  ParsedVpnProfile parse(String rawInput) {
    final raw = _normalizeInput(rawInput);
    if (raw.isEmpty) {
      throw const FormatException('Connection link is empty.');
    }

    final schemeSeparator = raw.indexOf('://');
    if (schemeSeparator <= 0) {
      throw const FormatException('Unsupported link format.');
    }

    final scheme = raw.substring(0, schemeSeparator).toLowerCase();
    return switch (scheme) {
      'vless' => _parseVless(raw),
      'vmess' => _parseVmess(raw),
      'trojan' => _parseTrojan(raw),
      'ss' => _parseShadowsocks(raw),
      'hysteria' => _parseHysteria(raw),
      'hysteria2' || 'hy2' => _parseHysteria2(raw),
      _ => throw FormatException('Unsupported protocol: $scheme'),
    };
  }

  ParsedVpnProfile? tryParse(String rawInput) {
    try {
      return parse(rawInput);
    } on FormatException {
      return null;
    }
  }

  String _normalizeInput(String rawInput) {
    return rawInput
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  }

  ParsedVpnProfile _parseVless(String link) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty || uri.port == 0 || uri.userInfo.isEmpty) {
      throw const FormatException('VLESS link is incomplete.');
    }
    final query = uri.queryParameters;
    final transport = _parseTransport(query['type'] ?? query['net']);
    return ParsedVpnProfile(
      protocol: LinkProtocol.vless,
      server: uri.host,
      port: uri.port,
      transport: transport,
      tlsMode: _parseTlsMode(query['security']),
      remark: _decodeFragment(uri.fragment),
      userId: Uri.decodeComponent(uri.userInfo),
      security: _emptyToNull(query['encryption']) ?? 'none',
      flow: _emptyToNull(query['flow']),
      sni: _emptyToNull(query['sni']) ?? _emptyToNull(query['servername']),
      alpn: _splitList(query['alpn']),
      host: _emptyToNull(query['host']),
      path: _normalizePath(query['path']),
      serviceName: _resolveServiceName(transport, query),
      authority:
          _emptyToNull(query['authority']) ?? _emptyToNull(query['host']),
      fingerprint: _emptyToNull(query['fp']),
      publicKey: _emptyToNull(query['pbk']),
      shortId: _emptyToNull(query['sid']),
      spiderX: _emptyToNull(query['spx']),
      allowInsecure: _toBool(query['allowinsecure'] ?? query['insecure']),
    );
  }

  ParsedVpnProfile _parseVmess(String link) {
    final payload = link.substring('vmess://'.length).trim();
    final decodedBytes = _decodeBase64(payload);
    final decoded = utf8.decode(decodedBytes);
    final json = jsonDecode(decoded);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('VMess payload is not a valid JSON object.');
    }

    final server = _requireString(json, 'add');
    final port = _requireInt(json, 'port');
    final userId = _requireString(json, 'id');
    final transport = _parseTransport(
      _stringValue(json['net']) ?? _stringValue(json['type']),
    );
    final path = _normalizePath(_stringValue(json['path']));
    final security =
        _stringValue(json['scy']) ?? _stringValue(json['security']) ?? 'auto';
    final tlsFlag =
        (_stringValue(json['tls']) ?? _stringValue(json['security']) ?? '')
            .toLowerCase();

    return ParsedVpnProfile(
      protocol: LinkProtocol.vmess,
      server: server,
      port: port,
      transport: transport,
      tlsMode: tlsFlag == 'tls'
          ? TlsMode.tls
          : tlsFlag == 'reality'
          ? TlsMode.reality
          : TlsMode.none,
      remark: _stringValue(json['ps']),
      userId: userId,
      security: security,
      alterId: int.tryParse((_stringValue(json['aid']) ?? '0')) ?? 0,
      sni: _stringValue(json['sni']),
      alpn: _splitList(_stringValue(json['alpn'])),
      host: _stringValue(json['host']),
      path: path,
      serviceName: transport == TransportMode.grpc
          ? _grpcServiceName(
              _stringValue(json['serviceName']) ?? _stringValue(json['path']),
            )
          : null,
      authority: _stringValue(json['authority']) ?? _stringValue(json['host']),
      fingerprint: _stringValue(json['fp']),
      allowInsecure: _toBool(
        _stringValue(json['allowInsecure']) ?? _stringValue(json['insecure']),
      ),
    );
  }

  ParsedVpnProfile _parseTrojan(String link) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty || uri.port == 0 || uri.userInfo.isEmpty) {
      throw const FormatException('Trojan link is incomplete.');
    }
    final query = uri.queryParameters;
    final transport = _parseTransport(query['type'] ?? query['net']);
    return ParsedVpnProfile(
      protocol: LinkProtocol.trojan,
      server: uri.host,
      port: uri.port,
      transport: transport,
      tlsMode: _parseTlsMode(query['security'] ?? 'tls'),
      remark: _decodeFragment(uri.fragment),
      password: Uri.decodeComponent(uri.userInfo),
      sni: _emptyToNull(query['sni']) ?? _emptyToNull(query['servername']),
      alpn: _splitList(query['alpn']),
      host: _emptyToNull(query['host']),
      path: _normalizePath(query['path']),
      serviceName: _resolveServiceName(transport, query),
      authority:
          _emptyToNull(query['authority']) ?? _emptyToNull(query['host']),
      fingerprint: _emptyToNull(query['fp']),
      publicKey: _emptyToNull(query['pbk']),
      shortId: _emptyToNull(query['sid']),
      spiderX: _emptyToNull(query['spx']),
      allowInsecure: _toBool(query['allowinsecure'] ?? query['insecure']),
    );
  }

  ParsedVpnProfile _parseShadowsocks(String link) {
    final withoutScheme = link.substring('ss://'.length);
    final hashIndex = withoutScheme.indexOf('#');
    final encodedPart = hashIndex >= 0
        ? withoutScheme.substring(0, hashIndex)
        : withoutScheme;
    final remark = hashIndex >= 0
        ? _decodeFragment(withoutScheme.substring(hashIndex + 1))
        : null;

    final queryIndex = encodedPart.indexOf('?');
    final mainPart = queryIndex >= 0
        ? encodedPart.substring(0, queryIndex)
        : encodedPart;
    final queryString = queryIndex >= 0
        ? encodedPart.substring(queryIndex + 1)
        : '';
    final query = Uri.splitQueryString(queryString);

    late final String method;
    late final String password;
    late final String server;
    late final int port;

    if (mainPart.contains('@')) {
      final atIndex = mainPart.lastIndexOf('@');
      var credentials = mainPart.substring(0, atIndex);
      final serverPart = mainPart.substring(atIndex + 1);
      if (!credentials.contains(':')) {
        credentials = utf8.decode(_decodeBase64(credentials));
      }
      final separatorIndex = credentials.indexOf(':');
      if (separatorIndex <= 0) {
        throw const FormatException('Shadowsocks credentials are invalid.');
      }
      method = credentials.substring(0, separatorIndex);
      password = credentials.substring(separatorIndex + 1);

      final endpoint = Uri.parse('ss://placeholder@$serverPart');
      server = endpoint.host;
      port = endpoint.port;
    } else {
      final decoded = utf8.decode(_decodeBase64(mainPart));
      final endpoint = Uri.parse('ss://$decoded');
      final separatorIndex = endpoint.userInfo.indexOf(':');
      if (separatorIndex <= 0 || endpoint.host.isEmpty || endpoint.port == 0) {
        throw const FormatException('Shadowsocks link is incomplete.');
      }
      method = endpoint.userInfo.substring(0, separatorIndex);
      password = endpoint.userInfo.substring(separatorIndex + 1);
      server = endpoint.host;
      port = endpoint.port;
    }

    final pluginRaw = _emptyToNull(query['plugin']);
    String? plugin;
    String? pluginOpts;
    if (pluginRaw != null) {
      final pluginParts = pluginRaw.split(';');
      plugin = pluginParts.first;
      if (pluginParts.length > 1) {
        pluginOpts = pluginParts.sublist(1).join(';');
      }
    }

    return ParsedVpnProfile(
      protocol: LinkProtocol.shadowsocks,
      server: server,
      port: port,
      transport: TransportMode.raw,
      tlsMode: TlsMode.none,
      remark: remark,
      password: password,
      method: method,
      plugin: plugin,
      pluginOpts: pluginOpts,
    );
  }

  ParsedVpnProfile _parseHysteria(String link) {
    final parts = _parseServerLink(link, defaultPort: null);
    if (parts.host.isEmpty || parts.port <= 0) {
      throw const FormatException('Hysteria link is incomplete.');
    }

    final upMbps = _requirePositiveInt(parts.query, 'upmbps');
    final downMbps = _requirePositiveInt(parts.query, 'downmbps');
    final network = _normalizeHysteriaNetwork(parts.query['protocol']);
    final obfsPassword =
        _emptyToNull(parts.query['obfsParam']) ??
        _emptyToNull(parts.query['obfs-param']) ??
        _emptyToNull(parts.query['obfs-password']);

    return ParsedVpnProfile(
      protocol: LinkProtocol.hysteria,
      server: parts.host,
      port: parts.port,
      transport: TransportMode.quic,
      tlsMode: TlsMode.tls,
      remark: _decodeFragment(parts.fragment),
      password: _emptyToNull(parts.query['auth']),
      sni:
          _emptyToNull(parts.query['peer']) ?? _emptyToNull(parts.query['sni']),
      alpn: _splitList(parts.query['alpn']),
      allowInsecure: _toBool(parts.query['insecure']),
      uploadMbps: upMbps,
      downloadMbps: downMbps,
      hysteriaNetwork: network,
      obfs: _emptyToNull(parts.query['obfs']),
      obfsPassword: obfsPassword,
    );
  }

  ParsedVpnProfile _parseHysteria2(String link) {
    final parts = _parseServerLink(link, defaultPort: 443);
    if (parts.host.isEmpty) {
      throw const FormatException('Hysteria2 link is incomplete.');
    }

    final auth = Uri.decodeComponent(parts.userInfo);
    final obfs = _emptyToNull(parts.query['obfs']);
    final obfsPassword =
        _emptyToNull(parts.query['obfs-password']) ??
        _emptyToNull(parts.query['obfsPassword']) ??
        _emptyToNull(parts.query['obfs-param']) ??
        _emptyToNull(parts.query['obfsParam']);

    return ParsedVpnProfile(
      protocol: LinkProtocol.hysteria2,
      server: parts.host,
      port: parts.port,
      transport: TransportMode.quic,
      tlsMode: TlsMode.tls,
      remark: _decodeFragment(parts.fragment),
      password: auth.isEmpty ? null : auth,
      sni: _emptyToNull(parts.query['sni']),
      allowInsecure: _toBool(parts.query['insecure']),
      serverPorts: parts.serverPorts,
      uploadMbps: _positiveInt(parts.query['upmbps']),
      downloadMbps: _positiveInt(parts.query['downmbps']),
      hysteriaNetwork: _normalizeHysteriaNetwork(parts.query['network']),
      obfs: obfs,
      obfsPassword: obfsPassword,
    );
  }

  TransportMode _parseTransport(String? rawTransport) {
    final normalized = (rawTransport ?? '').trim().toLowerCase();
    return switch (normalized) {
      '' || 'tcp' || 'raw' => TransportMode.raw,
      'ws' => TransportMode.ws,
      'grpc' => TransportMode.grpc,
      'h2' || 'http' => TransportMode.http,
      'httpupgrade' || 'http-upgrade' => TransportMode.httpUpgrade,
      'quic' => TransportMode.quic,
      'xhttp' || 'splithttp' || 'split-http' => TransportMode.xhttp,
      _ => throw FormatException('Unsupported transport: $normalized'),
    };
  }

  TlsMode _parseTlsMode(String? rawSecurity) {
    final normalized = (rawSecurity ?? '').trim().toLowerCase();
    return switch (normalized) {
      '' || 'none' => TlsMode.none,
      'tls' || 'xtls' => TlsMode.tls,
      'reality' => TlsMode.reality,
      _ => TlsMode.none,
    };
  }

  String? _resolveServiceName(
    TransportMode transport,
    Map<String, String> query,
  ) {
    if (transport != TransportMode.grpc) {
      return null;
    }
    return _grpcServiceName(
      query['servicename'] ?? query['serviceName'] ?? query['path'],
    );
  }

  String? _grpcServiceName(String? rawValue) {
    final value = _emptyToNull(rawValue);
    if (value == null) {
      return null;
    }
    if (value.startsWith('/')) {
      return value;
    }
    return value;
  }

  String? _normalizePath(String? rawPath) {
    final value = _emptyToNull(rawPath);
    if (value == null) {
      return null;
    }
    return value.startsWith('/') ? value : '/$value';
  }

  String _requireString(Map<String, dynamic> json, String key) {
    final value = _stringValue(json[key]);
    if (value == null || value.isEmpty) {
      throw FormatException('Missing field: $key');
    }
    return value;
  }

  int _requireInt(Map<String, dynamic> json, String key) {
    final value = _stringValue(json[key]);
    final parsed = int.tryParse(value ?? '');
    if (parsed == null) {
      throw FormatException('Field $key must be an integer.');
    }
    return parsed;
  }

  String? _stringValue(Object? value) {
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  String? _decodeFragment(String fragment) {
    return fragment.isEmpty ? null : Uri.decodeComponent(fragment);
  }

  String? _emptyToNull(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  List<String> _splitList(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <String>[];
    }
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  bool _toBool(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    return normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on';
  }

  int _requirePositiveInt(Map<String, String> query, String key) {
    final parsed = _positiveInt(query[key]);
    if (parsed == null) {
      throw FormatException('Field $key must be a positive integer.');
    }
    return parsed;
  }

  int? _positiveInt(String? raw) {
    final value = int.tryParse(raw?.trim() ?? '');
    if (value == null || value <= 0) {
      return null;
    }
    return value;
  }

  String? _normalizeHysteriaNetwork(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    return switch (normalized) {
      'tcp' => 'tcp',
      'udp' => 'udp',
      _ => null,
    };
  }

  _ParsedServerLink _parseServerLink(String link, {required int? defaultPort}) {
    final schemeSeparator = link.indexOf('://');
    if (schemeSeparator <= 0) {
      throw const FormatException('Unsupported link format.');
    }

    var remainder = link.substring(schemeSeparator + 3);
    var fragment = '';
    final fragmentIndex = remainder.indexOf('#');
    if (fragmentIndex >= 0) {
      fragment = remainder.substring(fragmentIndex + 1);
      remainder = remainder.substring(0, fragmentIndex);
    }

    var query = const <String, String>{};
    final queryIndex = remainder.indexOf('?');
    if (queryIndex >= 0) {
      query = Uri.splitQueryString(remainder.substring(queryIndex + 1));
      remainder = remainder.substring(0, queryIndex);
    }

    final pathIndex = remainder.indexOf('/');
    if (pathIndex >= 0) {
      remainder = remainder.substring(0, pathIndex);
    }

    var userInfo = '';
    final atIndex = remainder.lastIndexOf('@');
    if (atIndex >= 0) {
      userInfo = remainder.substring(0, atIndex);
      remainder = remainder.substring(atIndex + 1);
    }

    final endpoint = _parseEndpoint(remainder, defaultPort: defaultPort);
    return _ParsedServerLink(
      host: endpoint.host,
      port: endpoint.port,
      serverPorts: endpoint.serverPorts,
      userInfo: userInfo,
      query: query,
      fragment: fragment,
    );
  }

  _ParsedEndpoint _parseEndpoint(String raw, {required int? defaultPort}) {
    final value = raw.trim();
    if (value.isEmpty) {
      return const _ParsedEndpoint(host: '', port: 0);
    }

    late final String host;
    String? portText;
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end <= 1) {
        throw const FormatException('IPv6 endpoint is invalid.');
      }
      host = value.substring(1, end);
      final rest = value.substring(end + 1);
      if (rest.startsWith(':')) {
        portText = rest.substring(1);
      }
    } else {
      final colon = value.lastIndexOf(':');
      if (colon > 0) {
        host = value.substring(0, colon);
        portText = value.substring(colon + 1);
      } else {
        host = value;
      }
    }

    final parsedPorts = _parseServerPorts(portText);
    final serverPorts = _isServerPortRange(portText)
        ? parsedPorts
        : const <String>[];
    final port = _firstServerPort(parsedPorts) ?? defaultPort ?? 0;
    return _ParsedEndpoint(
      host: Uri.decodeComponent(host),
      port: port,
      serverPorts: serverPorts,
    );
  }

  List<String> _parseServerPorts(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) {
      return const <String>[];
    }
    return value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  bool _isServerPortRange(String? raw) {
    final value = raw?.trim();
    return value != null && (value.contains(',') || value.contains('-'));
  }

  int? _firstServerPort(List<String> ports) {
    for (final item in ports) {
      final first = item.split('-').first.trim();
      final parsed = int.tryParse(first);
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
    return null;
  }

  List<int> _decodeBase64(String rawValue) {
    final normalized = rawValue
        .trim()
        .replaceAll('\n', '')
        .replaceAll('\r', '');
    final remainder = normalized.length % 4;
    final padded = remainder == 0
        ? normalized
        : normalized.padRight(normalized.length + (4 - remainder), '=');
    try {
      return base64.decode(padded);
    } on FormatException {
      return base64Url.decode(padded);
    }
  }
}

class _ParsedServerLink {
  const _ParsedServerLink({
    required this.host,
    required this.port,
    required this.serverPorts,
    required this.userInfo,
    required this.query,
    required this.fragment,
  });

  final String host;
  final int port;
  final List<String> serverPorts;
  final String userInfo;
  final Map<String, String> query;
  final String fragment;
}

class _ParsedEndpoint {
  const _ParsedEndpoint({
    required this.host,
    required this.port,
    this.serverPorts = const <String>[],
  });

  final String host;
  final int port;
  final List<String> serverPorts;
}
