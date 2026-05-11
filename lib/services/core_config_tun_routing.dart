part of 'core_config_builder.dart';

List<Map<String, dynamic>> _buildTunnelDnsServers({
  required bool includeLocalResolver,
  required TunIpMode tunIpMode,
}) {
  final remoteDnsServer = switch (tunIpMode) {
    TunIpMode.ipv4 => '1.1.1.1',
    TunIpMode.dualStack => '1.1.1.1',
    TunIpMode.ipv6 => '2606:4700:4700::1111',
  };

  return <Map<String, dynamic>>[
    if (includeLocalResolver)
      <String, dynamic>{'type': 'local', 'tag': 'dns-local'},
    <String, dynamic>{
      'type': 'https',
      'tag': 'dns-remote',
      'server': remoteDnsServer,
      'server_port': 443,
      'path': '/dns-query',
      'tls': <String, dynamic>{
        'enabled': true,
        'server_name': 'cloudflare-dns.com',
      },
      'detour': 'proxy',
    },
  ];
}

List<Map<String, dynamic>> _buildTunnelRouteRules(
  SplitTunnelSettings splitTunnelSettings, {
  DomainSplitTunnelSettings domainSplitTunnelSettings =
      const DomainSplitTunnelSettings(),
  required TunIpMode tunIpMode,
}) {
  final splitTunnel = splitTunnelSettings.normalized;
  final domainSplitTunnel = domainSplitTunnelSettings.normalized;
  final hasWhitelist =
      splitTunnel.mode == SplitTunnelMode.whitelist ||
      domainSplitTunnel.mode == SplitTunnelMode.whitelist;
  final hasBlacklist =
      splitTunnel.mode == SplitTunnelMode.blacklist ||
      domainSplitTunnel.mode == SplitTunnelMode.blacklist;
  final rules = <Map<String, dynamic>>[
    <String, dynamic>{'action': 'sniff'},
    _buildResolveRule(mode: tunIpMode),
  ];

  if (!hasWhitelist && !hasBlacklist) {
    return rules
      ..add(buildSingBoxDnsHijackRule())
      ..add(_buildQuicRejectRule())
      ..add(_buildPrivateDirectRule());
  }

  if (hasWhitelist) {
    rules
      ..add(_buildQuicRejectRule())
      ..add(_buildPrivateDirectRule());
    _addSplitTunnelDirectRules(rules, splitTunnel, domainSplitTunnel);
    _addSplitTunnelProxyDnsRules(rules, splitTunnel, domainSplitTunnel);
    _addSplitTunnelProxyRules(rules, splitTunnel, domainSplitTunnel);
  } else {
    rules.add(_buildPrivateDirectRule());
    _addSplitTunnelDirectRules(rules, splitTunnel, domainSplitTunnel);
    rules
      ..add(buildSingBoxDnsHijackRule())
      ..add(_buildQuicRejectRule());
  }

  return rules;
}

void _addSplitTunnelDirectRules(
  List<Map<String, dynamic>> rules,
  SplitTunnelSettings splitTunnel,
  DomainSplitTunnelSettings domainSplitTunnel,
) {
  if (splitTunnel.mode == SplitTunnelMode.blacklist &&
      splitTunnel.hasSelectedApps) {
    rules.add(_buildProcessRouteRule(splitTunnel.apps, outbound: 'direct'));
  }
  if (domainSplitTunnel.mode == SplitTunnelMode.blacklist &&
      domainSplitTunnel.hasSelectedDomains) {
    rules.add(
      _buildDomainRouteRule(domainSplitTunnel.domains, outbound: 'direct'),
    );
  }
}

void _addSplitTunnelProxyDnsRules(
  List<Map<String, dynamic>> rules,
  SplitTunnelSettings splitTunnel,
  DomainSplitTunnelSettings domainSplitTunnel,
) {
  if (splitTunnel.mode == SplitTunnelMode.whitelist &&
      splitTunnel.hasSelectedApps) {
    rules.add(
      _buildSplitTunnelAndRule(
        _buildProcessMatcherRule(splitTunnel.apps),
        buildSingBoxDnsMatcherRule(),
        action: 'hijack-dns',
      ),
    );
  }
  if (domainSplitTunnel.mode == SplitTunnelMode.whitelist &&
      domainSplitTunnel.hasSelectedDomains) {
    rules.add(
      _buildSplitTunnelAndRule(
        _buildDomainMatcherRule(domainSplitTunnel.domains),
        buildSingBoxDnsMatcherRule(),
        action: 'hijack-dns',
      ),
    );
  }
}

void _addSplitTunnelProxyRules(
  List<Map<String, dynamic>> rules,
  SplitTunnelSettings splitTunnel,
  DomainSplitTunnelSettings domainSplitTunnel,
) {
  if (splitTunnel.mode == SplitTunnelMode.whitelist &&
      splitTunnel.hasSelectedApps) {
    rules.add(_buildProcessRouteRule(splitTunnel.apps, outbound: 'proxy'));
  }
  if (domainSplitTunnel.mode == SplitTunnelMode.whitelist &&
      domainSplitTunnel.hasSelectedDomains) {
    rules.add(
      _buildDomainRouteRule(domainSplitTunnel.domains, outbound: 'proxy'),
    );
  }
}

String _buildRouteFinal(
  SplitTunnelSettings splitTunnelSettings,
  DomainSplitTunnelSettings domainSplitTunnelSettings,
) {
  return splitTunnelSettings.mode == SplitTunnelMode.whitelist ||
          domainSplitTunnelSettings.mode == SplitTunnelMode.whitelist
      ? 'direct'
      : 'proxy';
}

Map<String, dynamic> _buildResolveRule({TunIpMode mode = TunIpMode.ipv4}) {
  return <String, dynamic>{
    'action': 'resolve',
    'strategy': singBoxDnsStrategyForTunIpMode(mode),
  };
}

bool _shouldEnableStrictRoute(
  SplitTunnelSettings splitTunnelSettings,
  DomainSplitTunnelSettings domainSplitTunnelSettings,
) {
  return splitTunnelSettings.mode != SplitTunnelMode.whitelist &&
      domainSplitTunnelSettings.mode != SplitTunnelMode.whitelist;
}

Map<String, dynamic> _buildQuicRejectRule() {
  return <String, dynamic>{
    ..._buildQuicMatcherRule(),
    'action': 'reject',
    'method': 'default',
  };
}

Map<String, dynamic> _buildQuicMatcherRule() {
  return <String, dynamic>{'network': 'udp', 'port': 443};
}

Map<String, dynamic> _buildPrivateDirectRule() {
  return <String, dynamic>{
    'ip_is_private': true,
    'action': 'route',
    'outbound': 'direct',
  };
}

Map<String, dynamic> _buildProcessRouteRule(
  List<SplitTunnelApp> apps, {
  required String outbound,
}) {
  return <String, dynamic>{
    ..._buildProcessMatcherRule(apps),
    'action': 'route',
    'outbound': outbound,
  };
}

Map<String, dynamic> _buildDomainRouteRule(
  List<SplitTunnelDomain> domains, {
  required String outbound,
}) {
  return <String, dynamic>{
    ..._buildDomainMatcherRule(domains),
    'action': 'route',
    'outbound': outbound,
  };
}

Map<String, dynamic> _buildDomainMatcherRule(List<SplitTunnelDomain> domains) {
  final suffixes =
      domains
          .map((domain) => domain.normalized.matchSuffix)
          .where((domain) => domain.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();

  return <String, dynamic>{'domain_suffix': suffixes};
}

Map<String, dynamic> _buildSplitTunnelAndRule(
  Map<String, dynamic> firstMatcher,
  Map<String, dynamic> matcher, {
  String? action,
  String? outbound,
  String? method,
}) {
  final rule = <String, dynamic>{
    'type': 'logical',
    'mode': 'and',
    'rules': <Map<String, dynamic>>[firstMatcher, matcher],
  };
  if (action != null) {
    rule['action'] = action;
  }
  if (outbound != null) {
    rule['action'] = action ?? 'route';
    rule['outbound'] = outbound;
  }
  if (method != null) {
    rule['method'] = method;
  }
  return rule;
}

Map<String, dynamic> _buildProcessMatcherRule(List<SplitTunnelApp> apps) {
  final processNames =
      apps.expand(_buildProcessNameVariants).toSet().toList(growable: false)
        ..sort();
  final processPaths =
      apps
          .map((app) => app.path.trim())
          .where((path) => path.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
  final processPathRegexes =
      apps.expand(_buildProcessPathRegexes).toSet().toList(growable: false)
        ..sort();
  final matchers = <Map<String, dynamic>>[
    if (processNames.isNotEmpty)
      <String, dynamic>{'process_name': processNames},
    if (processPaths.isNotEmpty)
      <String, dynamic>{'process_path': processPaths},
    if (processPathRegexes.isNotEmpty)
      <String, dynamic>{'process_path_regex': processPathRegexes},
  ];

  if (matchers.length == 1) {
    return matchers.single;
  }

  return <String, dynamic>{'type': 'logical', 'mode': 'or', 'rules': matchers};
}

Iterable<String> _buildProcessNameVariants(SplitTunnelApp app) sync* {
  final rawName = app.processName.trim();
  if (rawName.isEmpty) {
    return;
  }

  final baseName = p.basenameWithoutExtension(rawName).trim();
  for (final name in <String>{rawName, rawName.toLowerCase(), baseName}) {
    if (name.isNotEmpty) {
      yield name;
    }
    final lower = name.toLowerCase();
    if (lower.isNotEmpty) {
      yield lower;
    }
  }
}

Iterable<String> _buildProcessPathRegexes(SplitTunnelApp app) sync* {
  final rawPath = app.path.trim();
  if (rawPath.isEmpty) {
    return;
  }

  yield '(?i)^${RegExp.escape(rawPath)}\$';

  final directory = p.dirname(rawPath).trim();
  if (directory.isEmpty || directory == rawPath) {
    return;
  }
  yield '(?i)^${RegExp.escape(directory)}[\\\\/].+\\.exe\$';
}

List<String> _buildTunAddresses(TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => <String>['172.19.0.1/30'],
    TunIpMode.dualStack => <String>['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
    TunIpMode.ipv6 => <String>['fdfe:dcba:9876::1/126'],
  };
}

List<String> _buildTunRouteAddresses(TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => <String>['0.0.0.0/1', '128.0.0.0/1'],
    TunIpMode.dualStack => const <String>[],
    TunIpMode.ipv6 => <String>['::/1', '8000::/1'],
  };
}

List<String> _buildTunRouteExcludes(ParsedVpnProfile profile) {
  final server = profile.server.trim();
  if (server.isEmpty) {
    return const <String>[];
  }

  final ip = InternetAddress.tryParse(server);
  if (ip == null) {
    return const <String>[];
  }

  return <String>[
    ip.type == InternetAddressType.IPv6 ? '$server/128' : '$server/32',
  ];
}
