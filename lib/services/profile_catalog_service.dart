import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/config_source.dart';
import '../models/vpn_profile.dart';
import 'config_source_export.dart';
import 'share_link_parser.dart';

class ResolvedProfileCatalog {
  ResolvedProfileCatalog({
    required List<ParsedVpnProfile> profiles,
    required this.isSubscription,
    this.trafficUsage,
    this.sourceRawInput,
    this.sourceName,
  }) : profiles = List<ParsedVpnProfile>.unmodifiable(profiles);

  final List<ParsedVpnProfile> profiles;
  final bool isSubscription;
  final SubscriptionTrafficUsage? trafficUsage;
  final String? sourceRawInput;
  final String? sourceName;
}

class ProfileCatalogService {
  ProfileCatalogService({
    ShareLinkParser? parser,
    HttpClient Function()? httpClientFactory,
  }) : _parser = parser ?? ShareLinkParser(),
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final ShareLinkParser _parser;
  final HttpClient Function() _httpClientFactory;

  bool looksLikeRemoteSubscription(String rawInput) {
    final line = _primaryLine(rawInput);
    if (line.isEmpty) {
      return false;
    }

    final uri = Uri.tryParse(line);
    if (uri == null || uri.host.isEmpty) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  Future<ResolvedProfileCatalog> resolve(String rawInput) async {
    final singBoxRemoteProfile = _parseSingBoxRemoteProfileImportLink(rawInput);
    if (singBoxRemoteProfile != null) {
      return _resolveRemoteSubscription(
        singBoxRemoteProfile.url,
        sourceLabel: singBoxRemoteProfile.name,
        fallbackSourceLabel: singBoxRemoteProfile.host,
      );
    }

    if (looksLikeRemoteSubscription(rawInput)) {
      return _resolveRemoteSubscription(_primaryLine(rawInput));
    }
    final localFile = _resolveLocalConfigFile(rawInput);
    if (localFile != null) {
      final payload = localFile.readAsStringSync();
      final exportedSource = ConfigSourceExport.tryParse(payload);
      if (exportedSource != null) {
        return _catalogFromExportedSource(exportedSource);
      }
      final profile = _tryParseCoreConfig(
        payload,
        sourceLabel: p.basename(localFile.path),
        configDirectory: localFile.parent.path,
      );
      if (profile != null) {
        return ResolvedProfileCatalog(
          profiles: <ParsedVpnProfile>[profile],
          isSubscription: false,
        );
      }
    }
    return resolveInline(rawInput);
  }

  ResolvedProfileCatalog resolveInline(String rawInput) {
    final text = rawInput.trim();
    if (text.isEmpty) {
      throw const FormatException('Connection link is empty.');
    }

    final exportedSource = ConfigSourceExport.tryParse(text);
    if (exportedSource != null) {
      return _catalogFromExportedSource(exportedSource);
    }

    final coreConfig = _tryParseCoreConfig(text);
    if (coreConfig != null) {
      return ResolvedProfileCatalog(
        profiles: <ParsedVpnProfile>[coreConfig],
        isSubscription: false,
      );
    }

    final directProfiles = _parseProfilesFromText(rawInput);
    if (directProfiles.isNotEmpty) {
      return ResolvedProfileCatalog(
        profiles: directProfiles,
        isSubscription: directProfiles.length > 1,
      );
    }

    final decoded = _tryDecodeBase64Text(rawInput);
    if (decoded != null) {
      final decodedConfig = _tryParseCoreConfig(decoded);
      if (decodedConfig != null) {
        return ResolvedProfileCatalog(
          profiles: <ParsedVpnProfile>[decodedConfig],
          isSubscription: true,
        );
      }
      final decodedProfiles = _parseProfilesFromText(decoded);
      if (decodedProfiles.isNotEmpty) {
        return ResolvedProfileCatalog(
          profiles: decodedProfiles,
          isSubscription: true,
        );
      }
    }

    final lines = _candidateLines(rawInput);
    if (lines.length == 1) {
      _parser.parse(lines.first);
    }

    throw const FormatException('No supported links were found.');
  }

  ResolvedProfileCatalog _catalogFromExportedSource(ConfigSource source) {
    final rawInput = source.rawInput.trim();
    return ResolvedProfileCatalog(
      profiles: source.profiles,
      isSubscription: source.isSubscription,
      trafficUsage: source.trafficUsage,
      sourceRawInput: rawInput.isEmpty ? null : rawInput,
      sourceName: source.displayName,
    );
  }

  Future<ResolvedProfileCatalog> _resolveRemoteSubscription(
    String url, {
    String? sourceLabel,
    String? fallbackSourceLabel,
  }) async {
    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 15);
    client.userAgent = 'EntropyVPN/1.3.1';

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/plain, application/octet-stream, */*',
      );

      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Subscription request failed with status ${response.statusCode}.',
        );
      }

      final bodyBytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) {
          builder.add(chunk);
          return builder;
        },
      );
      final body = _decodeResponseBody(bodyBytes.takeBytes());
      final trafficUsage = _parseSubscriptionTrafficUsage(
        _subscriptionTrafficUsageHeader(response.headers),
      );
      final remoteSourceLabel =
          _nonEmpty(sourceLabel) ?? _profileTitleHeader(response.headers);
      final resolved = _resolveSubscriptionPayload(
        body,
        isRemote: true,
        sourceLabel: remoteSourceLabel,
        fallbackSourceLabel:
            _nonEmpty(fallbackSourceLabel) ??
            _remoteUrlFragmentLabel(url) ??
            _remoteUrlPathLabel(url),
        trafficUsage: trafficUsage,
      );
      if (resolved != null) {
        return resolved;
      }

      throw const FormatException(
        'No supported links were found in the subscription.',
      );
    } on TimeoutException {
      throw StateError('Subscription request timed out.');
    } on SocketException catch (error) {
      throw StateError('Subscription request failed: ${error.message}');
    } on HttpException catch (error) {
      throw StateError('Subscription request failed: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  ResolvedProfileCatalog? _resolveSubscriptionPayload(
    String payload, {
    required bool isRemote,
    String? sourceLabel,
    String? fallbackSourceLabel,
    SubscriptionTrafficUsage? trafficUsage,
  }) {
    final resolvedSourceName =
        _nonEmpty(sourceLabel) ?? _nonEmpty(fallbackSourceLabel);
    final coreConfig = _tryParseCoreConfig(
      payload,
      sourceLabel: sourceLabel,
      fallbackLabel: fallbackSourceLabel,
    );
    if (coreConfig != null) {
      return ResolvedProfileCatalog(
        profiles: <ParsedVpnProfile>[coreConfig],
        isSubscription: isRemote,
        trafficUsage: isRemote ? trafficUsage : null,
        sourceName: isRemote ? resolvedSourceName : null,
      );
    }

    final directProfiles = _parseProfilesFromText(payload);
    if (directProfiles.isNotEmpty) {
      return ResolvedProfileCatalog(
        profiles: directProfiles,
        isSubscription: true,
        trafficUsage: trafficUsage,
        sourceName: resolvedSourceName,
      );
    }

    final decoded = _tryDecodeBase64Text(payload);
    if (decoded == null) {
      return null;
    }

    final decodedConfig = _tryParseCoreConfig(
      decoded,
      sourceLabel: sourceLabel,
      fallbackLabel: fallbackSourceLabel,
    );
    if (decodedConfig != null) {
      return ResolvedProfileCatalog(
        profiles: <ParsedVpnProfile>[decodedConfig],
        isSubscription: true,
        trafficUsage: trafficUsage,
        sourceName: resolvedSourceName,
      );
    }

    final decodedProfiles = _parseProfilesFromText(decoded);
    if (decodedProfiles.isEmpty) {
      return null;
    }

    return ResolvedProfileCatalog(
      profiles: decodedProfiles,
      isSubscription: true,
      trafficUsage: trafficUsage,
      sourceName: resolvedSourceName,
    );
  }

  String? _subscriptionTrafficUsageHeader(HttpHeaders headers) {
    final directHeader =
        headers.value('subscription-userinfo') ??
        headers.value('Subscription-Userinfo');
    if (directHeader != null && directHeader.trim().isNotEmpty) {
      return directHeader;
    }

    String? scannedHeader;
    headers.forEach((name, values) {
      if (scannedHeader != null) {
        return;
      }
      final normalizedName = name.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (normalizedName == 'subscriptionuserinfo' ||
          normalizedName == 'subscriptionuserinformation') {
        if (values.isNotEmpty) {
          scannedHeader = values.join('; ');
        }
      }
    });

    return scannedHeader;
  }

  String? _profileTitleHeader(HttpHeaders headers) {
    final directHeader =
        headers.value('profile-title') ?? headers.value('Profile-Title');
    if (directHeader != null && directHeader.trim().isNotEmpty) {
      return _decodeHeaderLabel(directHeader);
    }

    String? scannedHeader;
    headers.forEach((name, values) {
      if (scannedHeader != null) {
        return;
      }
      final normalizedName = name.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (normalizedName == 'profiletitle' && values.isNotEmpty) {
        scannedHeader = values.join(' ');
      }
    });

    return _decodeHeaderLabel(scannedHeader);
  }

  SubscriptionTrafficUsage? _parseSubscriptionTrafficUsage(String? header) {
    if (header == null || header.trim().isEmpty) {
      return null;
    }

    final values = <String, int>{};
    final pattern = RegExp(
      r'\b(upload|download|total|expire|up|down|used)\s*=\s*(\d+)\b',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(header)) {
      final key = match.group(1)?.toLowerCase();
      final value = int.tryParse(match.group(2) ?? '');
      if (key == null || value == null || value < 0) {
        continue;
      }
      values[_normalizeTrafficUsageKey(key)] = value;
    }

    final expireSeconds = values['expire'];
    final expiresAt = expireSeconds != null && expireSeconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            expireSeconds * 1000,
            isUtc: true,
          ).toLocal()
        : null;

    if (!values.containsKey('upload') &&
        !values.containsKey('download') &&
        !values.containsKey('total') &&
        expiresAt == null) {
      return null;
    }

    final total = values['total'];
    final used = values['used'];
    return SubscriptionTrafficUsage(
      uploadBytes: values['upload'] ?? 0,
      downloadBytes: values['download'] ?? used ?? 0,
      totalBytes: total != null && total > 0 ? total : null,
      expiresAt: expiresAt,
    );
  }

  String _normalizeTrafficUsageKey(String key) {
    return switch (key) {
      'up' => 'upload',
      'down' => 'download',
      _ => key,
    };
  }

  List<ParsedVpnProfile> _parseProfilesFromText(String text) {
    final profiles = <ParsedVpnProfile>[];
    final seen = <String>{};

    for (final link in _extractShareLinks(text)) {
      if (!seen.add(link)) {
        continue;
      }

      final parsed = _parser.tryParse(link);
      if (parsed != null) {
        profiles.add(parsed);
      }
    }

    return profiles;
  }

  List<String> _extractShareLinks(String text) {
    final normalized = text.replaceAll('\uFEFF', '');
    final matches =
        RegExp(
              r'(hysteria2|hysteria|vless|vmess|trojan|hy2|ss)://',
              caseSensitive: false,
            )
            .allMatches(normalized)
            .where((match) {
              return _isLikelyShareLinkBoundary(normalized, match.start);
            })
            .toList(growable: false);

    if (matches.isEmpty) {
      return const <String>[];
    }

    final links = <String>[];
    for (var i = 0; i < matches.length; i += 1) {
      final start = matches[i].start;
      final end = i + 1 < matches.length
          ? matches[i + 1].start
          : normalized.length;
      final candidate = _trimShareLink(normalized.substring(start, end));
      if (candidate.isNotEmpty) {
        links.add(candidate);
      }
    }

    return links;
  }

  bool _isLikelyShareLinkBoundary(String text, int start) {
    if (start == 0) {
      return true;
    }

    final previous = text.codeUnitAt(start - 1);
    if (previous <= 32) {
      return true;
    }

    return previous == 0x22 ||
        previous == 0x27 ||
        previous == 0x28 ||
        previous == 0x2c ||
        previous == 0x3b ||
        previous == 0x3c ||
        previous == 0x3e ||
        previous == 0x5b ||
        previous == 0x60 ||
        previous == 0x7b ||
        previous == 0x7c;
  }

  String _trimShareLink(String value) {
    var link = value.trim();
    final lineBreak = RegExp(r'[\r\n]').firstMatch(link);
    if (lineBreak != null) {
      link = link.substring(0, lineBreak.start).trim();
    }

    while (link.isNotEmpty &&
        _isTrailingShareLinkSeparator(link.codeUnitAt(link.length - 1))) {
      link = link.substring(0, link.length - 1).trimRight();
    }

    return link;
  }

  bool _isTrailingShareLinkSeparator(int codeUnit) {
    return codeUnit == 0x22 ||
        codeUnit == 0x27 ||
        codeUnit == 0x29 ||
        codeUnit == 0x2c ||
        codeUnit == 0x2e ||
        codeUnit == 0x3b ||
        codeUnit == 0x3e ||
        codeUnit == 0x5d ||
        codeUnit == 0x60 ||
        codeUnit == 0x7c ||
        codeUnit == 0x7d;
  }

  ParsedVpnProfile? _tryParseCoreConfig(
    String text, {
    String? sourceLabel,
    String? fallbackLabel,
    String? configDirectory,
  }) {
    final normalizedText = text.trim().replaceFirst('\uFEFF', '');
    if (normalizedText.isEmpty || !normalizedText.startsWith('{')) {
      return null;
    }

    final decoded = jsonDecode(normalizedText);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    return switch (_detectCoreConfigFlavor(decoded)) {
      CoreFlavor.singBox => _parseSingBoxConfig(
        decoded,
        sourceLabel: sourceLabel,
        fallbackLabel: fallbackLabel,
        configDirectory: configDirectory,
      ),
      CoreFlavor.xray => _parseXrayConfig(
        decoded,
        sourceLabel: sourceLabel,
        fallbackLabel: fallbackLabel,
        configDirectory: configDirectory,
      ),
      null => null,
    };
  }

  ParsedVpnProfile _parseSingBoxConfig(
    Map<String, dynamic> decoded, {
    String? sourceLabel,
    String? fallbackLabel,
    String? configDirectory,
  }) {
    final endpoint = _extractPrimarySingBoxEndpoint(decoded);
    final remark =
        _nonEmpty(sourceLabel) ??
        _nonEmpty(decoded['remark']?.toString()) ??
        _nonEmpty(decoded['name']?.toString()) ??
        _nonEmpty(fallbackLabel) ??
        'Sing-box config';

    return ParsedVpnProfile.singBoxConfig(
      configJson: const JsonEncoder.withIndent('  ').convert(decoded),
      remark: remark,
      server: endpoint?.server,
      port: endpoint?.port ?? 0,
      protocol: endpoint?.protocol ?? LinkProtocol.vless,
      transport: endpoint?.transport ?? TransportMode.raw,
      tlsMode: endpoint?.tlsMode ?? TlsMode.none,
      userId: endpoint?.userId,
      password: endpoint?.password,
      method: endpoint?.method,
      security: endpoint?.security,
      flow: endpoint?.flow,
      sni: endpoint?.sni,
      alpn: endpoint?.alpn ?? const <String>[],
      host: endpoint?.host,
      path: endpoint?.path,
      serviceName: endpoint?.serviceName,
      authority: endpoint?.authority,
      fingerprint: endpoint?.fingerprint,
      publicKey: endpoint?.publicKey,
      shortId: endpoint?.shortId,
      allowInsecure: endpoint?.allowInsecure ?? false,
      serverPorts: endpoint?.serverPorts ?? const <String>[],
      uploadMbps: endpoint?.uploadMbps,
      downloadMbps: endpoint?.downloadMbps,
      hysteriaNetwork: endpoint?.hysteriaNetwork,
      obfs: endpoint?.obfs,
      obfsPassword: endpoint?.obfsPassword,
      singBoxOutboundType: endpoint?.outboundType,
      configDirectory: configDirectory,
    );
  }

  ParsedVpnProfile _parseXrayConfig(
    Map<String, dynamic> decoded, {
    String? sourceLabel,
    String? fallbackLabel,
    String? configDirectory,
  }) {
    final endpoint = _extractPrimaryXrayEndpoint(decoded);
    final remark =
        _nonEmpty(sourceLabel) ??
        _nonEmpty(decoded['remark']?.toString()) ??
        _nonEmpty(decoded['name']?.toString()) ??
        _nonEmpty(fallbackLabel) ??
        'Xray config';

    return ParsedVpnProfile.xrayConfig(
      configJson: const JsonEncoder.withIndent('  ').convert(decoded),
      remark: remark,
      server: endpoint?.server,
      port: endpoint?.port ?? 0,
      protocol: endpoint?.protocol ?? LinkProtocol.vless,
      transport: endpoint?.transport ?? TransportMode.raw,
      tlsMode: endpoint?.tlsMode ?? TlsMode.none,
      userId: endpoint?.userId,
      password: endpoint?.password,
      method: endpoint?.method,
      security: endpoint?.security,
      alterId: endpoint?.alterId ?? 0,
      flow: endpoint?.flow,
      sni: endpoint?.sni,
      alpn: endpoint?.alpn ?? const <String>[],
      host: endpoint?.host,
      path: endpoint?.path,
      serviceName: endpoint?.serviceName,
      authority: endpoint?.authority,
      fingerprint: endpoint?.fingerprint,
      publicKey: endpoint?.publicKey,
      shortId: endpoint?.shortId,
      spiderX: endpoint?.spiderX,
      allowInsecure: endpoint?.allowInsecure ?? false,
      xrayOutboundProtocol: endpoint?.outboundType,
      configDirectory: configDirectory,
    );
  }

  CoreFlavor? _detectCoreConfigFlavor(Map<String, dynamic> json) {
    final xrayScore = _xrayConfigSignalScore(json);
    final singBoxScore = _singBoxConfigSignalScore(json);
    if (xrayScore == 0 && singBoxScore == 0) {
      return null;
    }
    if (xrayScore > singBoxScore) {
      return CoreFlavor.xray;
    }
    if (singBoxScore > xrayScore) {
      return CoreFlavor.singBox;
    }
    return null;
  }

  int _xrayConfigSignalScore(Map<String, dynamic> json) {
    const xrayTopLevelFields = <String>{
      'routing',
      'api',
      'policy',
      'transport',
      'stats',
      'reverse',
      'fakedns',
      'metrics',
      'observatory',
      'burstObservatory',
      'geodata',
    };

    var score = 0;
    for (final field in xrayTopLevelFields) {
      if (json.containsKey(field)) {
        score += 3;
      }
    }

    final routing = _mapValue(json['routing']);
    if (routing != null) {
      for (final field in <String>[
        'rules',
        'balancers',
        'domainStrategy',
        'domainMatcher',
      ]) {
        if (routing.containsKey(field)) {
          score += 2;
        }
      }
    }

    for (final object in _coreConfigObjects(json)) {
      if (object.containsKey('protocol')) {
        score += 6;
      }
      for (final field in <String>[
        'streamSettings',
        'sendThrough',
        'proxySettings',
        'mux',
        'targetStrategy',
      ]) {
        if (object.containsKey(field)) {
          score += 2;
        }
      }
    }

    return score;
  }

  int _singBoxConfigSignalScore(Map<String, dynamic> json) {
    const singBoxTopLevelFields = <String>{
      'route',
      'ntp',
      'certificate',
      'certificate_providers',
      'http_clients',
      'endpoints',
      'services',
      'experimental',
    };

    var score = 0;
    for (final field in singBoxTopLevelFields) {
      if (json.containsKey(field)) {
        score += 3;
      }
    }

    final route = _mapValue(json['route']);
    if (route != null) {
      for (final field in <String>[
        'rules',
        'rule_set',
        'final',
        'auto_detect_interface',
        'default_interface',
        'default_domain_resolver',
      ]) {
        if (route.containsKey(field)) {
          score += 2;
        }
      }
    }

    for (final object in _coreConfigObjects(json)) {
      if (object.containsKey('type')) {
        score += 6;
      }
      for (final field in <String>[
        'listen_port',
        'server_port',
        'tls',
        'transport',
        'dialer',
      ]) {
        if (object.containsKey(field)) {
          score += 2;
        }
      }
    }

    return score;
  }

  Iterable<Map<String, dynamic>> _coreConfigObjects(
    Map<String, dynamic> json,
  ) sync* {
    for (final key in <String>['inbounds', 'outbounds']) {
      final values = json[key];
      if (values is! List) {
        continue;
      }
      for (final item in values) {
        final object = _mapValue(item);
        if (object != null) {
          yield object;
        }
      }
    }
  }

  _ConfigEndpoint? _extractPrimaryXrayEndpoint(Map<String, dynamic> json) {
    final outbounds = json['outbounds'];
    if (outbounds is! List) {
      return null;
    }

    for (final item in outbounds) {
      final outbound = _mapValue(item);
      final endpoint = _endpointFromXrayOutbound(outbound);
      if (endpoint != null) {
        return endpoint;
      }
    }

    return null;
  }

  _ConfigEndpoint? _endpointFromXrayOutbound(Map<String, dynamic>? outbound) {
    if (outbound == null) {
      return null;
    }

    const serverProtocols = <String>{'vless', 'vmess', 'trojan', 'shadowsocks'};

    final outboundProtocol = _nonEmpty(
      outbound['protocol']?.toString(),
    )?.toLowerCase();
    if (outboundProtocol == null ||
        !serverProtocols.contains(outboundProtocol)) {
      return null;
    }

    final settings = _mapValue(outbound['settings']);
    final streamSettings = _mapValue(outbound['streamSettings']);

    return switch (outboundProtocol) {
      'vless' || 'vmess' => _endpointFromXrayVnextOutbound(
        outboundProtocol,
        settings,
        streamSettings,
      ),
      'trojan' || 'shadowsocks' => _endpointFromXrayServerOutbound(
        outboundProtocol,
        settings,
        streamSettings,
      ),
      _ => null,
    };
  }

  _ConfigEndpoint? _endpointFromXrayVnextOutbound(
    String outboundProtocol,
    Map<String, dynamic>? settings,
    Map<String, dynamic>? streamSettings,
  ) {
    final vnext = settings?['vnext'];
    if (vnext is! List) {
      return null;
    }

    for (final item in vnext) {
      final serverConfig = _mapValue(item);
      final server =
          _nonEmpty(serverConfig?['address']?.toString()) ??
          _nonEmpty(serverConfig?['server']?.toString());
      if (server == null) {
        continue;
      }

      final user = _firstMap(serverConfig?['users']);
      return _ConfigEndpoint(
        server: server,
        port: _intValue(serverConfig?['port']),
        outboundType: outboundProtocol,
        protocol: _protocolForCoreProtocol(outboundProtocol),
        transport: _transportForXrayStream(streamSettings),
        tlsMode: _tlsModeForXrayStream(streamSettings),
        userId:
            _nonEmpty(user?['id']?.toString()) ??
            _nonEmpty(user?['uuid']?.toString()),
        security:
            _nonEmpty(user?['security']?.toString()) ??
            _nonEmpty(user?['encryption']?.toString()),
        alterId: _intValue(user?['alterId']),
        flow: _nonEmpty(user?['flow']?.toString()),
        sni: _xrayServerName(streamSettings),
        alpn: _xrayAlpn(streamSettings),
        host: _xrayTransportHost(streamSettings),
        path: _xrayTransportPath(streamSettings),
        serviceName: _xrayGrpcServiceName(streamSettings),
        authority: _xrayTransportAuthority(streamSettings),
        fingerprint: _xrayFingerprint(streamSettings),
        publicKey: _xrayRealityValue(streamSettings, 'publicKey'),
        shortId: _xrayRealityValue(streamSettings, 'shortId'),
        spiderX: _xrayRealityValue(streamSettings, 'spiderX'),
        allowInsecure: _xrayAllowInsecure(streamSettings),
      );
    }

    return null;
  }

  _ConfigEndpoint? _endpointFromXrayServerOutbound(
    String outboundProtocol,
    Map<String, dynamic>? settings,
    Map<String, dynamic>? streamSettings,
  ) {
    final servers = settings?['servers'];
    if (servers is! List) {
      return null;
    }

    for (final item in servers) {
      final serverConfig = _mapValue(item);
      final server =
          _nonEmpty(serverConfig?['address']?.toString()) ??
          _nonEmpty(serverConfig?['server']?.toString());
      if (server == null) {
        continue;
      }

      return _ConfigEndpoint(
        server: server,
        port: _intValue(serverConfig?['port']),
        outboundType: outboundProtocol,
        protocol: _protocolForCoreProtocol(outboundProtocol),
        transport: _transportForXrayStream(streamSettings),
        tlsMode: _tlsModeForXrayStream(streamSettings),
        password: _nonEmpty(serverConfig?['password']?.toString()),
        method: _nonEmpty(serverConfig?['method']?.toString()),
        security: _nonEmpty(serverConfig?['security']?.toString()),
        sni: _xrayServerName(streamSettings),
        alpn: _xrayAlpn(streamSettings),
        host: _xrayTransportHost(streamSettings),
        path: _xrayTransportPath(streamSettings),
        serviceName: _xrayGrpcServiceName(streamSettings),
        authority: _xrayTransportAuthority(streamSettings),
        fingerprint: _xrayFingerprint(streamSettings),
        publicKey: _xrayRealityValue(streamSettings, 'publicKey'),
        shortId: _xrayRealityValue(streamSettings, 'shortId'),
        spiderX: _xrayRealityValue(streamSettings, 'spiderX'),
        allowInsecure: _xrayAllowInsecure(streamSettings),
      );
    }

    return null;
  }

  _ConfigEndpoint? _extractPrimarySingBoxEndpoint(Map<String, dynamic> json) {
    final outbounds = json['outbounds'];
    if (outbounds is! List) {
      return null;
    }

    final outboundMaps = <Map<String, dynamic>>[];
    final outboundsByTag = <String, Map<String, dynamic>>{};

    for (final item in outbounds) {
      final outbound = _mapValue(item);
      if (outbound == null) {
        continue;
      }
      outboundMaps.add(outbound);
      final tag = _nonEmpty(outbound['tag']?.toString());
      if (tag != null) {
        outboundsByTag[tag] = outbound;
      }
    }

    final route = _mapValue(json['route']);
    final finalTag = _nonEmpty(route?['final']?.toString());
    if (finalTag != null) {
      final finalOutbound = _resolveServerSingBoxOutbound(
        finalTag,
        outboundsByTag,
      );
      final endpoint = _endpointFromSingBoxOutbound(finalOutbound);
      if (endpoint != null) {
        return endpoint;
      }
    }

    for (final outbound in outboundMaps) {
      final endpoint = _endpointFromSingBoxOutbound(outbound);
      if (endpoint != null) {
        return endpoint;
      }
    }

    return null;
  }

  Map<String, dynamic>? _resolveServerSingBoxOutbound(
    String tag,
    Map<String, Map<String, dynamic>> outboundsByTag, [
    Set<String>? visited,
  ]) {
    final seen = visited ?? <String>{};
    if (!seen.add(tag)) {
      return null;
    }

    final outbound = outboundsByTag[tag];
    if (outbound == null) {
      return null;
    }

    if (_endpointFromSingBoxOutbound(outbound) != null) {
      return outbound;
    }

    final outboundRefs = outbound['outbounds'];
    if (outboundRefs is! List) {
      return null;
    }

    for (final ref in outboundRefs) {
      final childTag = _nonEmpty(ref?.toString());
      if (childTag == null) {
        continue;
      }
      final resolved = _resolveServerSingBoxOutbound(
        childTag,
        outboundsByTag,
        seen,
      );
      if (resolved != null) {
        return resolved;
      }
    }

    return null;
  }

  _ConfigEndpoint? _endpointFromSingBoxOutbound(
    Map<String, dynamic>? outbound,
  ) {
    if (outbound == null) {
      return null;
    }

    const nonServerOutboundTypes = <String>{
      'block',
      'direct',
      'dns',
      'selector',
      'urltest',
    };

    final outboundType = _nonEmpty(outbound['type']?.toString())?.toLowerCase();
    if (outboundType == null || nonServerOutboundTypes.contains(outboundType)) {
      return null;
    }

    final server = _nonEmpty(outbound['server']?.toString());
    if (server == null) {
      return null;
    }

    final tls = _mapValue(outbound['tls']);
    final transport = _mapValue(outbound['transport']);
    final reality = _mapValue(tls?['reality']);
    final utls = _mapValue(tls?['utls']);

    return _ConfigEndpoint(
      server: server,
      port:
          _intValueOrNull(outbound['server_port']) ??
          _firstServerPort(_stringList(outbound['server_ports'])) ??
          0,
      outboundType: outboundType,
      protocol: _protocolForSingBoxOutbound(outboundType),
      transport: _transportForSingBoxOutbound(transport),
      tlsMode: _tlsModeForSingBoxOutbound(tls),
      userId: _nonEmpty(outbound['uuid']?.toString()),
      password: _nonEmpty(outbound['password']?.toString()),
      method: _nonEmpty(outbound['method']?.toString()),
      security: _nonEmpty(outbound['security']?.toString()),
      flow: _nonEmpty(outbound['flow']?.toString()),
      sni: _nonEmpty(tls?['server_name']?.toString()),
      alpn: _stringList(tls?['alpn']),
      host: _transportHost(transport),
      path: _nonEmpty(transport?['path']?.toString()),
      serviceName:
          _nonEmpty(transport?['service_name']?.toString()) ??
          _nonEmpty(transport?['serviceName']?.toString()),
      authority: _transportAuthority(transport),
      fingerprint: _nonEmpty(utls?['fingerprint']?.toString()),
      publicKey: _nonEmpty(reality?['public_key']?.toString()),
      shortId: _nonEmpty(reality?['short_id']?.toString()),
      allowInsecure: tls?['insecure'] == true,
      serverPorts: _stringList(outbound['server_ports']),
      uploadMbps:
          _intValueOrNull(outbound['up_mbps']) ?? _mbpsValue(outbound['up']),
      downloadMbps:
          _intValueOrNull(outbound['down_mbps']) ??
          _mbpsValue(outbound['down']),
      hysteriaNetwork: _nonEmpty(outbound['network']?.toString()),
      obfs: _singBoxObfsType(outbound),
      obfsPassword: _singBoxObfsPassword(outbound),
    );
  }

  LinkProtocol _protocolForSingBoxOutbound(String outboundType) {
    return _protocolForCoreProtocol(outboundType);
  }

  LinkProtocol _protocolForCoreProtocol(String protocol) {
    return switch (protocol) {
      'vmess' => LinkProtocol.vmess,
      'trojan' => LinkProtocol.trojan,
      'shadowsocks' => LinkProtocol.shadowsocks,
      'hysteria' => LinkProtocol.hysteria,
      'hysteria2' => LinkProtocol.hysteria2,
      _ => LinkProtocol.vless,
    };
  }

  TransportMode _transportForXrayStream(Map<String, dynamic>? streamSettings) {
    final network = _nonEmpty(
      streamSettings?['network']?.toString(),
    )?.toLowerCase();
    return switch (network) {
      'ws' || 'websocket' => TransportMode.ws,
      'grpc' => TransportMode.grpc,
      'http' => TransportMode.http,
      'httpupgrade' || 'http-upgrade' => TransportMode.httpUpgrade,
      'quic' => TransportMode.quic,
      'xhttp' || 'splithttp' || 'split-http' => TransportMode.xhttp,
      _ => TransportMode.raw,
    };
  }

  TlsMode _tlsModeForXrayStream(Map<String, dynamic>? streamSettings) {
    final security = _nonEmpty(
      streamSettings?['security']?.toString(),
    )?.toLowerCase();
    return switch (security) {
      'reality' => TlsMode.reality,
      'tls' => TlsMode.tls,
      _ => TlsMode.none,
    };
  }

  String? _xrayServerName(Map<String, dynamic>? streamSettings) {
    return _xrayRealityValue(streamSettings, 'serverName') ??
        _xrayTlsValue(streamSettings, 'serverName') ??
        _xrayTlsValue(streamSettings, 'server_name');
  }

  List<String> _xrayAlpn(Map<String, dynamic>? streamSettings) {
    return _stringList(
      _xrayRealitySettings(streamSettings)?['alpn'] ??
          _xrayTlsSettings(streamSettings)?['alpn'],
    );
  }

  String? _xrayFingerprint(Map<String, dynamic>? streamSettings) {
    return _xrayRealityValue(streamSettings, 'fingerprint') ??
        _xrayTlsValue(streamSettings, 'fingerprint');
  }

  bool _xrayAllowInsecure(Map<String, dynamic>? streamSettings) {
    return _xrayTlsSettings(streamSettings)?['allowInsecure'] == true;
  }

  String? _xrayRealityValue(Map<String, dynamic>? streamSettings, String key) {
    return _nonEmpty(_xrayRealitySettings(streamSettings)?[key]?.toString());
  }

  String? _xrayTlsValue(Map<String, dynamic>? streamSettings, String key) {
    return _nonEmpty(_xrayTlsSettings(streamSettings)?[key]?.toString());
  }

  Map<String, dynamic>? _xrayRealitySettings(
    Map<String, dynamic>? streamSettings,
  ) {
    return _mapValue(streamSettings?['realitySettings']);
  }

  Map<String, dynamic>? _xrayTlsSettings(Map<String, dynamic>? streamSettings) {
    return _mapValue(streamSettings?['tlsSettings']);
  }

  String? _xrayTransportHost(Map<String, dynamic>? streamSettings) {
    final settings = _xrayTransportSettings(streamSettings);
    if (settings == null) {
      return null;
    }

    final host = settings['host'];
    if (host is List) {
      for (final item in host) {
        final value = _nonEmpty(item?.toString());
        if (value != null) {
          return value;
        }
      }
    }

    final directHost = _nonEmpty(host?.toString());
    if (directHost != null) {
      return directHost;
    }

    final headers = _mapValue(settings['headers']);
    final hostValue = headers?['Host'] ?? headers?['host'];
    if (hostValue is List) {
      for (final item in hostValue) {
        final value = _nonEmpty(item?.toString());
        if (value != null) {
          return value;
        }
      }
      return null;
    }
    return _nonEmpty(hostValue?.toString());
  }

  String? _xrayTransportPath(Map<String, dynamic>? streamSettings) {
    return _nonEmpty(
      _xrayTransportSettings(streamSettings)?['path']?.toString(),
    );
  }

  String? _xrayGrpcServiceName(Map<String, dynamic>? streamSettings) {
    final grpcSettings = _mapValue(streamSettings?['grpcSettings']);
    return _nonEmpty(grpcSettings?['serviceName']?.toString()) ??
        _nonEmpty(grpcSettings?['service_name']?.toString());
  }

  String? _xrayTransportAuthority(Map<String, dynamic>? streamSettings) {
    final grpcSettings = _mapValue(streamSettings?['grpcSettings']);
    final grpcAuthority = _nonEmpty(grpcSettings?['authority']?.toString());
    if (grpcAuthority != null) {
      return grpcAuthority;
    }

    final settings = _xrayTransportSettings(streamSettings);
    final headers = _mapValue(settings?['headers']);
    return _nonEmpty(settings?['authority']?.toString()) ??
        _nonEmpty(headers?[':authority']?.toString()) ??
        _nonEmpty(headers?['authority']?.toString());
  }

  Map<String, dynamic>? _xrayTransportSettings(
    Map<String, dynamic>? streamSettings,
  ) {
    final network = _nonEmpty(
      streamSettings?['network']?.toString(),
    )?.toLowerCase();
    return switch (network) {
      'ws' || 'websocket' => _mapValue(streamSettings?['wsSettings']),
      'grpc' => _mapValue(streamSettings?['grpcSettings']),
      'http' => _mapValue(streamSettings?['httpSettings']),
      'xhttp' ||
      'splithttp' ||
      'split-http' => _mapValue(streamSettings?['xhttpSettings']),
      'httpupgrade' ||
      'http-upgrade' => _mapValue(streamSettings?['httpupgradeSettings']),
      'quic' => _mapValue(streamSettings?['quicSettings']),
      _ => _mapValue(streamSettings?['tcpSettings']),
    };
  }

  TransportMode _transportForSingBoxOutbound(Map<String, dynamic>? transport) {
    final type = _nonEmpty(transport?['type']?.toString())?.toLowerCase();
    return switch (type) {
      'ws' || 'websocket' => TransportMode.ws,
      'grpc' => TransportMode.grpc,
      'http' => TransportMode.http,
      'httpupgrade' || 'http-upgrade' => TransportMode.httpUpgrade,
      'quic' => TransportMode.quic,
      'xhttp' || 'splithttp' || 'split-http' => TransportMode.xhttp,
      _ => TransportMode.raw,
    };
  }

  TlsMode _tlsModeForSingBoxOutbound(Map<String, dynamic>? tls) {
    if (tls == null || tls['enabled'] != true) {
      return TlsMode.none;
    }

    final reality = _mapValue(tls['reality']);
    if (reality != null && reality['enabled'] == true) {
      return TlsMode.reality;
    }

    return TlsMode.tls;
  }

  String? _transportHost(Map<String, dynamic>? transport) {
    if (transport == null) {
      return null;
    }

    final directHost =
        _nonEmpty(transport['host']?.toString()) ??
        _nonEmpty(transport['Host']?.toString());
    if (directHost != null) {
      return directHost;
    }

    final headers = _mapValue(transport['headers']);
    final hostValue = headers?['Host'] ?? headers?['host'];
    if (hostValue is List) {
      for (final item in hostValue) {
        final host = _nonEmpty(item?.toString());
        if (host != null) {
          return host;
        }
      }
      return null;
    }
    return _nonEmpty(hostValue?.toString());
  }

  String? _transportAuthority(Map<String, dynamic>? transport) {
    if (transport == null) {
      return null;
    }
    final headers = _mapValue(transport['headers']);
    return _nonEmpty(transport['authority']?.toString()) ??
        _nonEmpty(headers?[':authority']?.toString()) ??
        _nonEmpty(headers?['authority']?.toString());
  }

  List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .map((item) => _nonEmpty(item?.toString()))
          .whereType<String>()
          .toList(growable: false);
    }

    final single = _nonEmpty(value?.toString());
    if (single == null) {
      return const <String>[];
    }
    return <String>[single];
  }

  Map<String, dynamic>? _firstMap(Object? value) {
    if (value is! List) {
      return null;
    }
    for (final item in value) {
      final map = _mapValue(item);
      if (map != null) {
        return map;
      }
    }
    return null;
  }

  int _intValue(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? 0;
    }
    return 0;
  }

  int? _intValueOrNull(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  int? _mbpsValue(Object? value) {
    final raw = _nonEmpty(value?.toString());
    if (raw == null) {
      return null;
    }
    final match = RegExp(
      r'^(\d+)\s*mbps$',
      caseSensitive: false,
    ).firstMatch(raw);
    return int.tryParse(match?.group(1) ?? '');
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

  String? _singBoxObfsType(Map<String, dynamic> outbound) {
    final obfs = outbound['obfs'];
    final obfsMap = _mapValue(obfs);
    if (obfsMap != null) {
      return _nonEmpty(obfsMap['type']?.toString());
    }
    return null;
  }

  String? _singBoxObfsPassword(Map<String, dynamic> outbound) {
    final obfs = outbound['obfs'];
    final obfsMap = _mapValue(obfs);
    if (obfsMap != null) {
      return _nonEmpty(obfsMap['password']?.toString());
    }
    return _nonEmpty(obfs?.toString());
  }

  Map<String, dynamic>? _mapValue(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  String? _nonEmpty(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _decodeHeaderLabel(String? value) {
    final trimmed = _nonEmpty(value);
    if (trimmed == null) {
      return null;
    }

    try {
      return _nonEmpty(Uri.decodeFull(trimmed)) ?? trimmed;
    } on FormatException {
      return trimmed;
    }
  }

  String? _remoteUrlPathLabel(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return null;
    }

    for (final segment in uri.pathSegments.reversed) {
      final decoded = _decodeHeaderLabel(segment);
      if (decoded != null) {
        return decoded;
      }
    }

    return _nonEmpty(uri.host);
  }

  String? _remoteUrlFragmentLabel(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return null;
    }
    return _decodeHeaderLabel(uri.fragment);
  }

  File? _resolveLocalConfigFile(String rawInput) {
    final line = _primaryLine(rawInput);
    if (line.isEmpty || line.contains('\n') || line.startsWith('{')) {
      return null;
    }

    final uri = Uri.tryParse(line);
    if (uri != null && uri.scheme.toLowerCase() == 'file') {
      final file = File.fromUri(uri);
      return file.existsSync() ? file : null;
    }

    final file = File(line);
    return file.existsSync() ? file : null;
  }

  _SingBoxRemoteProfile? _parseSingBoxRemoteProfileImportLink(String rawInput) {
    final line = _primaryLine(rawInput);
    if (line.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(line);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'sing-box' ||
        uri.host.toLowerCase() != 'import-remote-profile') {
      return null;
    }

    final remoteUrl = uri.queryParameters['url']?.trim();
    if (remoteUrl == null || remoteUrl.isEmpty) {
      throw const FormatException('Sing-box import link is missing url.');
    }

    final remoteUri = Uri.tryParse(remoteUrl);
    if (remoteUri == null ||
        remoteUri.host.isEmpty ||
        (remoteUri.scheme != 'http' && remoteUri.scheme != 'https')) {
      throw const FormatException('Sing-box import link url is invalid.');
    }

    return _SingBoxRemoteProfile(
      name: _nonEmpty(Uri.decodeComponent(uri.fragment)),
      url: remoteUri.toString(),
      host: _nonEmpty(remoteUri.host),
    );
  }

  List<String> _candidateLines(String text) {
    return text
        .replaceAll('\uFEFF', '')
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _primaryLine(String rawInput) {
    return _candidateLines(
      rawInput,
    ).firstWhere((line) => line.isNotEmpty, orElse: () => '');
  }

  String _decodeResponseBody(List<int> bytes) {
    return utf8.decode(bytes, allowMalformed: true).trim();
  }

  String? _tryDecodeBase64Text(String rawValue) {
    final normalized = rawValue
        .replaceAll('\uFEFF', '')
        .replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty || normalized.contains('://')) {
      return null;
    }

    final remainder = normalized.length % 4;
    final padded = remainder == 0
        ? normalized
        : normalized.padRight(normalized.length + (4 - remainder), '=');

    try {
      return utf8.decode(base64.decode(padded), allowMalformed: true).trim();
    } on FormatException {
      try {
        return utf8
            .decode(base64Url.decode(padded), allowMalformed: true)
            .trim();
      } on FormatException {
        return null;
      }
    }
  }
}

class _ConfigEndpoint {
  const _ConfigEndpoint({
    required this.server,
    required this.port,
    required this.outboundType,
    required this.protocol,
    required this.transport,
    required this.tlsMode,
    this.userId,
    this.password,
    this.method,
    this.security,
    this.alterId = 0,
    this.flow,
    this.sni,
    this.alpn = const <String>[],
    this.host,
    this.path,
    this.serviceName,
    this.authority,
    this.fingerprint,
    this.publicKey,
    this.shortId,
    this.spiderX,
    this.allowInsecure = false,
    this.serverPorts = const <String>[],
    this.uploadMbps,
    this.downloadMbps,
    this.hysteriaNetwork,
    this.obfs,
    this.obfsPassword,
  });

  final String server;
  final int port;
  final String outboundType;
  final LinkProtocol protocol;
  final TransportMode transport;
  final TlsMode tlsMode;
  final String? userId;
  final String? password;
  final String? method;
  final String? security;
  final int alterId;
  final String? flow;
  final String? sni;
  final List<String> alpn;
  final String? host;
  final String? path;
  final String? serviceName;
  final String? authority;
  final String? fingerprint;
  final String? publicKey;
  final String? shortId;
  final String? spiderX;
  final bool allowInsecure;
  final List<String> serverPorts;
  final int? uploadMbps;
  final int? downloadMbps;
  final String? hysteriaNetwork;
  final String? obfs;
  final String? obfsPassword;
}

class _SingBoxRemoteProfile {
  const _SingBoxRemoteProfile({
    required this.name,
    required this.url,
    required this.host,
  });

  final String? name;
  final String url;
  final String? host;
}
