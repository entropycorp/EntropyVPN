import 'dart:io';

import '../models/vpn_profile.dart';

bool applyNativeSingBoxTunSettingsToConfig(
  Map<String, dynamic> config, {
  required TunIpMode tunIpMode,
  required String androidTunStack,
  String? tunInterfaceName,
  int? mtu,
  bool androidCompatibility = false,
}) {
  final tunInbounds = _singBoxTunInbounds(config);
  if (tunInbounds.isEmpty) {
    return false;
  }

  final normalizedTunInterfaceName = tunInterfaceName?.trim();
  for (final inbound in tunInbounds) {
    if (normalizedTunInterfaceName != null &&
        normalizedTunInterfaceName.isNotEmpty) {
      inbound['interface_name'] = normalizedTunInterfaceName;
    }
    if (mtu != null && mtu > 0) {
      inbound['mtu'] = mtu;
    }
    if (androidCompatibility) {
      _applyAndroidTunCompatibility(inbound, androidTunStack);
    }
    _applyTunIpModeToInbound(inbound, tunIpMode);
  }
  if (androidCompatibility) {
    _applyAndroidRouteCompatibility(config);
  }
  _applyDnsStrategy(config, tunIpMode);
  _ensureResolveRuleAfterSniff(config, tunIpMode, tunInbounds);
  _ensureDnsHijackRuleAfterResolve(config, tunInbounds);
  return true;
}

Map<String, dynamic> buildSingBoxDnsHijackRule() {
  return <String, dynamic>{
    ...buildSingBoxDnsMatcherRule(),
    'action': 'hijack-dns',
  };
}

Map<String, dynamic> buildSingBoxDnsMatcherRule() {
  return <String, dynamic>{
    'type': 'logical',
    'mode': 'or',
    'rules': <Map<String, dynamic>>[
      <String, dynamic>{'protocol': 'dns'},
      <String, dynamic>{'port': 53},
    ],
  };
}

void _applyAndroidTunCompatibility(
  Map<String, dynamic> inbound,
  String androidTunStack,
) {
  inbound
    ..remove('interface_name')
    ..remove('strict_route')
    ..remove('gso');
  inbound['stack'] = androidTunStack;
}

void _applyAndroidRouteCompatibility(Map<String, dynamic> config) {
  final route = _ensureMapField(config, 'route');
  route['auto_detect_interface'] = true;
}

List<Map<String, dynamic>> _singBoxTunInbounds(Map<String, dynamic> config) {
  final inbounds = config['inbounds'];
  if (inbounds is! List) {
    return const <Map<String, dynamic>>[];
  }

  final result = <Map<String, dynamic>>[];
  for (final inbound in inbounds) {
    if (inbound is! Map) {
      continue;
    }
    final typed = inbound.cast<String, dynamic>();
    if (typed['type']?.toString().trim().toLowerCase() == 'tun') {
      result.add(typed);
    }
  }
  return result;
}

void _applyTunIpModeToInbound(Map<String, dynamic> inbound, TunIpMode mode) {
  if (mode == TunIpMode.dualStack) {
    _ensureTunAddressField(inbound, mode);
    return;
  }

  _filterIpFamilyField(
    inbound,
    'address',
    mode,
    fallback: _defaultNativeTunAddress(mode),
  );
  _filterIpFamilyField(inbound, 'route_address', mode);
  _filterIpFamilyField(inbound, 'route_exclude_address', mode);

  switch (mode) {
    case TunIpMode.ipv4:
      inbound
        ..remove('inet6_address')
        ..remove('inet6_route_address')
        ..remove('inet6_route_exclude_address');
    case TunIpMode.ipv6:
      inbound
        ..remove('inet4_address')
        ..remove('inet4_route_address')
        ..remove('inet4_route_exclude_address');
    case TunIpMode.dualStack:
      break;
  }
  _ensureTunAddressField(inbound, mode);
}

void _ensureTunAddressField(Map<String, dynamic> inbound, TunIpMode mode) {
  if (mode == TunIpMode.dualStack) {
    return;
  }
  if (_fieldHasSelectedIpFamily(inbound['address'], mode)) {
    return;
  }

  final legacyField = mode == TunIpMode.ipv4
      ? 'inet4_address'
      : 'inet6_address';
  if (_fieldHasSelectedIpFamily(inbound[legacyField], mode)) {
    return;
  }

  inbound['address'] = _defaultNativeTunAddress(mode);
}

void _filterIpFamilyField(
  Map<String, dynamic> target,
  String field,
  TunIpMode mode, {
  List<String>? fallback,
}) {
  final rawValue = target[field];
  final values = _stringFieldValues(rawValue);
  if (values.isEmpty) {
    return;
  }

  final filtered = values
      .where((value) => _matchesTunIpMode(value, mode))
      .toList(growable: false);
  if (filtered.isEmpty) {
    if (fallback == null || fallback.isEmpty) {
      target.remove(field);
    } else {
      target[field] = fallback;
    }
    return;
  }

  target[field] = rawValue is String && filtered.length == 1
      ? filtered.single
      : filtered;
}

bool _fieldHasSelectedIpFamily(Object? rawValue, TunIpMode mode) {
  return _stringFieldValues(
    rawValue,
  ).any((value) => _matchesTunIpMode(value, mode));
}

List<String> _stringFieldValues(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? const <String>[] : <String>[trimmed];
  }
  if (value is List) {
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

bool _matchesTunIpMode(String value, TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => !_isIpv6AddressLike(value),
    TunIpMode.dualStack => true,
    TunIpMode.ipv6 => _isIpv6AddressLike(value),
  };
}

bool _isIpv6AddressLike(String value) {
  final host = _addressHost(value);
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) {
    return parsed.type == InternetAddressType.IPv6;
  }
  return host.contains(':');
}

String _addressHost(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('[')) {
    final end = trimmed.indexOf(']');
    if (end > 1) {
      return trimmed.substring(1, end);
    }
  }
  return trimmed.split('/').first.trim();
}

List<String> _defaultNativeTunAddress(TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => <String>['172.19.0.1/30'],
    TunIpMode.dualStack => <String>['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
    TunIpMode.ipv6 => <String>['fdfe:dcba:9876::1/126'],
  };
}

void _applyDnsStrategy(Map<String, dynamic> config, TunIpMode mode) {
  final dns = config['dns'];
  if (dns is! Map) {
    return;
  }
  dns['strategy'] = singBoxDnsStrategyForTunIpMode(mode);
}

String singBoxDnsStrategyForTunIpMode(TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => 'ipv4_only',
    TunIpMode.dualStack => 'prefer_ipv4',
    TunIpMode.ipv6 => 'ipv6_only',
  };
}

void _ensureResolveRuleAfterSniff(
  Map<String, dynamic> config,
  TunIpMode mode,
  List<Map<String, dynamic>> tunInbounds,
) {
  final route = _ensureMapField(config, 'route');
  final rules = _ensureRulesList(route);
  final strategy = singBoxDnsStrategyForTunIpMode(mode);
  final inboundMatcher = _buildTunInboundMatcher(tunInbounds);

  for (final rule in rules) {
    if (rule is! Map) {
      continue;
    }
    final typed = rule.cast<String, dynamic>();
    if (_isGenericResolveRule(typed, inboundMatcher)) {
      typed['strategy'] = strategy;
      return;
    }
  }

  final resolveRule = <String, dynamic>{
    'action': 'resolve',
    'strategy': strategy,
  };
  if (inboundMatcher != null) {
    resolveRule['inbound'] = inboundMatcher;
  }
  final sniffIndex = rules.indexWhere((rule) {
    if (rule is! Map) {
      return false;
    }
    final typed = rule.cast<String, dynamic>();
    return typed['action']?.toString().trim().toLowerCase() == 'sniff' &&
        _ruleInboundMatches(typed['inbound'], inboundMatcher);
  });

  if (sniffIndex >= 0) {
    rules.insert(sniffIndex + 1, resolveRule);
    return;
  }

  final sniffRule = <String, dynamic>{'action': 'sniff'};
  if (inboundMatcher != null) {
    sniffRule['inbound'] = inboundMatcher;
  }

  rules
    ..insert(0, resolveRule)
    ..insert(0, sniffRule);
}

void _ensureDnsHijackRuleAfterResolve(
  Map<String, dynamic> config,
  List<Map<String, dynamic>> tunInbounds,
) {
  final route = _ensureMapField(config, 'route');
  final rules = _ensureRulesList(route);
  final inboundMatcher = _buildTunInboundMatcher(tunInbounds);

  for (final rule in rules) {
    if (rule is! Map) {
      continue;
    }
    final typed = rule.cast<String, dynamic>();
    if (_isDnsHijackRule(typed, inboundMatcher)) {
      return;
    }
  }

  final hijackRule = buildSingBoxDnsHijackRule();
  if (inboundMatcher != null) {
    hijackRule['inbound'] = inboundMatcher;
  }

  final resolveIndex = rules.indexWhere((rule) {
    if (rule is! Map) {
      return false;
    }
    final typed = rule.cast<String, dynamic>();
    return typed['action']?.toString().trim().toLowerCase() == 'resolve' &&
        _ruleInboundMatches(typed['inbound'], inboundMatcher);
  });
  if (resolveIndex >= 0) {
    rules.insert(resolveIndex + 1, hijackRule);
    return;
  }

  final sniffIndex = rules.indexWhere((rule) {
    if (rule is! Map) {
      return false;
    }
    final typed = rule.cast<String, dynamic>();
    return typed['action']?.toString().trim().toLowerCase() == 'sniff' &&
        _ruleInboundMatches(typed['inbound'], inboundMatcher);
  });
  if (sniffIndex >= 0) {
    rules.insert(sniffIndex + 1, hijackRule);
    return;
  }

  rules.insert(0, hijackRule);
}

Map<String, dynamic> _ensureMapField(
  Map<String, dynamic> target,
  String field,
) {
  final existing = target[field];
  if (existing is Map) {
    return existing.cast<String, dynamic>();
  }
  final created = <String, dynamic>{};
  target[field] = created;
  return created;
}

List<dynamic> _ensureRulesList(Map<String, dynamic> route) {
  final rawRules = route['rules'];
  if (rawRules is List) {
    return rawRules;
  }
  if (rawRules is Map) {
    final rules = <dynamic>[rawRules];
    route['rules'] = rules;
    return rules;
  }
  final rules = <dynamic>[];
  route['rules'] = rules;
  return rules;
}

Object? _buildTunInboundMatcher(List<Map<String, dynamic>> tunInbounds) {
  final tags = tunInbounds
      .map((inbound) => inbound['tag']?.toString().trim() ?? '')
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
  if (tags.length != tunInbounds.length || tags.isEmpty) {
    return null;
  }
  return tags.length == 1 ? tags.single : tags;
}

bool _isGenericResolveRule(Map<String, dynamic> rule, Object? inboundMatcher) {
  if (rule['action']?.toString().trim().toLowerCase() != 'resolve') {
    return false;
  }
  if (!_ruleInboundMatches(rule['inbound'], inboundMatcher)) {
    return false;
  }

  const genericResolveKeys = <String>{
    'action',
    'inbound',
    'server',
    'strategy',
    'disable_cache',
    'disable_optimistic_cache',
    'rewrite_ttl',
    'timeout',
    'client_subnet',
  };
  return rule.keys.every(genericResolveKeys.contains);
}

bool _isDnsHijackRule(Map<String, dynamic> rule, Object? inboundMatcher) {
  if (rule['action']?.toString().trim().toLowerCase() != 'hijack-dns') {
    return false;
  }
  return _ruleInboundMatches(rule['inbound'], inboundMatcher) &&
      _ruleMatchesDns(rule);
}

bool _ruleMatchesDns(Map<String, dynamic> rule) {
  final protocol = rule['protocol'];
  if (protocol is String && protocol.trim().toLowerCase() == 'dns') {
    return true;
  }
  if (protocol is List &&
      protocol.any((item) => item?.toString().trim().toLowerCase() == 'dns')) {
    return true;
  }
  if (_fieldContainsPort(rule['port'], 53)) {
    return true;
  }

  final childRules = rule['rules'];
  if (childRules is List) {
    return childRules.any((child) {
      if (child is! Map) {
        return false;
      }
      return _ruleMatchesDns(child.cast<String, dynamic>());
    });
  }
  return false;
}

bool _fieldContainsPort(Object? value, int port) {
  if (value is int) {
    return value == port;
  }
  if (value is num) {
    return value.toInt() == port;
  }
  if (value is String) {
    return value
        .split(',')
        .map((item) => item.trim())
        .any((item) => item == port.toString());
  }
  if (value is List) {
    return value.any((item) => _fieldContainsPort(item, port));
  }
  return false;
}

bool _ruleInboundMatches(Object? ruleInbound, Object? inboundMatcher) {
  if (inboundMatcher == null) {
    return ruleInbound == null;
  }
  if (ruleInbound == null) {
    return true;
  }
  final ruleTags = _inboundMatcherTags(ruleInbound);
  final targetTags = _inboundMatcherTags(inboundMatcher);
  return ruleTags.isNotEmpty &&
      targetTags.isNotEmpty &&
      ruleTags.length == targetTags.length &&
      ruleTags.every(targetTags.contains);
}

Set<String> _inboundMatcherTags(Object? value) {
  if (value is String) {
    final tag = value.trim();
    return tag.isEmpty ? const <String>{} : <String>{tag};
  }
  if (value is List) {
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toSet();
  }
  return const <String>{};
}
