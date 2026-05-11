part of 'profile_catalog_service.dart';

class _SubscriptionPayloadResolver {
  const _SubscriptionPayloadResolver(this._parser);

  final ShareLinkParser _parser;

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

  ResolvedProfileCatalog? resolveSubscriptionPayload(
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
      return utf8.decode(base64Url.decode(padded), allowMalformed: true).trim();
    } on FormatException {
      return null;
    }
  }
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
