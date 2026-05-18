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
    try {
      return _parser.parseAll(text);
    } on FormatException {
      return const <ParsedVpnProfile>[];
    }
  }

  String? _tryDecodeBase64Text(String rawValue) {
    return _parser.tryDecodeSubscriptionBase64(rawValue);
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

  final base64Decoded = _tryDecodeBase64PrefixedLabel(trimmed);
  if (base64Decoded != null) {
    return base64Decoded;
  }

  try {
    return _nonEmpty(Uri.decodeFull(trimmed)) ?? trimmed;
  } on FormatException {
    return trimmed;
  }
}

String? _tryDecodeBase64PrefixedLabel(String value) {
  const prefix = 'base64:';
  if (value.length <= prefix.length ||
      value.substring(0, prefix.length).toLowerCase() != prefix) {
    return null;
  }
  final payload = value.substring(prefix.length).trim();
  if (payload.isEmpty) {
    return null;
  }
  try {
    final normalized = base64.normalize(
      payload.replaceAll('-', '+').replaceAll('_', '/'),
    );
    final bytes = base64.decode(normalized);
    return _nonEmpty(utf8.decode(bytes));
  } catch (_) {
    return null;
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
