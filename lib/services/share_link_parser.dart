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
      authority: _emptyToNull(query['authority']) ?? _emptyToNull(query['host']),
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
    final security = _stringValue(json['scy']) ??
        _stringValue(json['security']) ??
        'auto';
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
      authority: _emptyToNull(query['authority']) ?? _emptyToNull(query['host']),
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
    final encodedPart =
        hashIndex >= 0 ? withoutScheme.substring(0, hashIndex) : withoutScheme;
    final remark =
        hashIndex >= 0 ? _decodeFragment(withoutScheme.substring(hashIndex + 1)) : null;

    final queryIndex = encodedPart.indexOf('?');
    final mainPart =
        queryIndex >= 0 ? encodedPart.substring(0, queryIndex) : encodedPart;
    final queryString =
        queryIndex >= 0 ? encodedPart.substring(queryIndex + 1) : '';
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

  TransportMode _parseTransport(String? rawTransport) {
    final normalized = (rawTransport ?? '').trim().toLowerCase();
    return switch (normalized) {
      '' || 'tcp' || 'raw' => TransportMode.raw,
      'ws' => TransportMode.ws,
      'grpc' => TransportMode.grpc,
      'h2' || 'http' => TransportMode.http,
      'httpupgrade' => TransportMode.httpUpgrade,
      'quic' => TransportMode.quic,
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

  List<int> _decodeBase64(String rawValue) {
    final normalized = rawValue.trim().replaceAll('\n', '').replaceAll('\r', '');
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
