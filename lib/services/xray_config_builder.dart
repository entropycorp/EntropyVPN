part of 'core_config_builder.dart';

Map<String, dynamic> _buildXrayConfig(
  ParsedVpnProfile profile, {
  TrafficMode trafficMode = TrafficMode.systemProxy,
  TunIpMode tunIpMode = TunIpMode.ipv4,
  DomainSplitTunnelSettings domainSplitTunnelSettings =
      const DomainSplitTunnelSettings(),
  String? tunInterfaceName,
  String? outboundBindInterface,
  String? serverAddressOverride,
}) {
  final isTunMode = trafficMode == TrafficMode.tun;
  final effectiveDomainSplitTunnel = (isTunMode || Platform.isAndroid)
      ? domainSplitTunnelSettings.normalized
      : const DomainSplitTunnelSettings();
  final useAndroidHevDnsRouting = Platform.isAndroid && !isTunMode;
  final useXrayDnsRouting = useAndroidHevDnsRouting || isTunMode;
  final xrayRoutingRules = _buildXrayRoutingRules(
    domainSplitTunnelSettings: effectiveDomainSplitTunnel,
    useXrayDnsRouting: useXrayDnsRouting,
    isTunMode: isTunMode,
  );
  final normalizedTunInterfaceName = tunInterfaceName?.trim();
  final effectiveTunInterfaceName =
      normalizedTunInterfaceName == null || normalizedTunInterfaceName.isEmpty
      ? 'xray0'
      : normalizedTunInterfaceName;

  return <String, dynamic>{
    'log': <String, dynamic>{'loglevel': 'warning'},
    if (useXrayDnsRouting)
      'dns': <String, dynamic>{
        'servers': isTunMode
            ? _buildXrayTunDnsServers(tunIpMode)
            : _buildXrayAndroidDnsServers(tunIpMode),
        'queryStrategy': _buildXrayDnsQueryStrategy(tunIpMode),
        if (isTunMode) 'tag': 'dns-query',
      },
    'inbounds': <Map<String, dynamic>>[
      if (!isTunMode)
        <String, dynamic>{
          'tag': 'socks-in',
          'protocol': 'socks',
          'listen': '127.0.0.1',
          'port': CoreConfigBuilder.xraySocksPort,
          'settings': <String, dynamic>{'udp': true},
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls', 'quic'],
          },
        },
      if (!isTunMode)
        <String, dynamic>{
          'tag': 'http-in',
          'protocol': 'http',
          'listen': '127.0.0.1',
          'port': CoreConfigBuilder.xrayHttpPort,
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls', 'quic'],
          },
        },
      if (isTunMode)
        <String, dynamic>{
          'tag': 'tun-in',
          'protocol': 'tun',
          'settings': <String, dynamic>{
            'name': effectiveTunInterfaceName,
            'MTU': CoreConfigBuilder.tunMtu,
            'userLevel': 0,
          },
          if (effectiveDomainSplitTunnel.isEnabled)
            'sniffing': <String, dynamic>{
              'enabled': true,
              'destOverride': <String>['http', 'tls', 'quic'],
            },
        },
    ],
    'outbounds': <Map<String, dynamic>>[
      _buildXrayOutbound(
        profile,
        bindInterface: outboundBindInterface,
        serverAddressOverride: serverAddressOverride,
      ),
      if (useXrayDnsRouting) _buildXrayDnsOutbound(tunIpMode),
      _buildXrayDirectOutbound(
        bindInterface: isTunMode ? outboundBindInterface : null,
      ),
      <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
    ],
    if (xrayRoutingRules.isNotEmpty)
      'routing': <String, dynamic>{
        'domainStrategy': 'AsIs',
        'rules': xrayRoutingRules,
      },
  };
}

Map<String, dynamic> _buildXrayOutbound(
  ParsedVpnProfile profile, {
  String? bindInterface,
  String? serverAddressOverride,
}) {
  final outbound = <String, dynamic>{'tag': 'proxy'};
  final serverAddress = serverAddressOverride?.trim().isNotEmpty == true
      ? serverAddressOverride!.trim()
      : profile.server;

  switch (profile.protocol) {
    case LinkProtocol.vless:
      outbound.addAll(<String, dynamic>{
        'protocol': 'vless',
        'settings': <String, dynamic>{
          'vnext': <Map<String, dynamic>>[
            <String, dynamic>{
              'address': serverAddress,
              'port': profile.port,
              'users': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': _require(profile.userId, 'VLESS user ID'),
                  'encryption': profile.security ?? 'none',
                  'flow': profile.flow ?? '',
                  'level': 0,
                },
              ],
            },
          ],
        },
      });
    case LinkProtocol.vmess:
      outbound.addAll(<String, dynamic>{
        'protocol': 'vmess',
        'settings': <String, dynamic>{
          'vnext': <Map<String, dynamic>>[
            <String, dynamic>{
              'address': serverAddress,
              'port': profile.port,
              'users': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': _require(profile.userId, 'VMess user ID'),
                  'security': profile.security ?? 'auto',
                  'alterId': profile.alterId,
                  'level': 0,
                },
              ],
            },
          ],
        },
      });
    case LinkProtocol.trojan:
      outbound.addAll(<String, dynamic>{
        'protocol': 'trojan',
        'settings': <String, dynamic>{
          'servers': <Map<String, dynamic>>[
            <String, dynamic>{
              'address': serverAddress,
              'port': profile.port,
              'password': _require(profile.password, 'Trojan password'),
            },
          ],
        },
      });
    case LinkProtocol.shadowsocks:
      if (profile.plugin != null) {
        throw StateError(
          'Xray desktop wrapper does not support Shadowsocks plugins yet.',
        );
      }
      outbound.addAll(<String, dynamic>{
        'protocol': 'shadowsocks',
        'settings': <String, dynamic>{
          'servers': <Map<String, dynamic>>[
            <String, dynamic>{
              'address': serverAddress,
              'port': profile.port,
              'method': _require(profile.method, 'Shadowsocks method'),
              'password': _require(profile.password, 'Shadowsocks password'),
            },
          ],
        },
      });
    case LinkProtocol.hysteria:
    case LinkProtocol.hysteria2:
      throw StateError(
        '${profile.protocol.name} links must be run with sing-box.',
      );
  }

  outbound['streamSettings'] = _buildXrayStreamSettings(
    profile,
    bindInterface: bindInterface,
  );
  return outbound;
}

Map<String, dynamic> _buildXrayDirectOutbound({String? bindInterface}) {
  final outbound = <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'};
  final normalizedBindInterface = bindInterface?.trim();
  if (normalizedBindInterface != null && normalizedBindInterface.isNotEmpty) {
    outbound['streamSettings'] = <String, dynamic>{
      'sockopt': <String, dynamic>{'interface': normalizedBindInterface},
    };
  }
  return outbound;
}

Map<String, dynamic> _buildXrayDnsOutbound(TunIpMode mode) {
  final blockedQueryTypes = switch (mode) {
    TunIpMode.ipv4 => <int>[28],
    TunIpMode.dualStack => const <int>[],
    TunIpMode.ipv6 => <int>[1],
  };

  return <String, dynamic>{
    'tag': 'dns-out',
    'protocol': 'dns',
    if (blockedQueryTypes.isNotEmpty)
      'settings': <String, dynamic>{
        'rules': blockedQueryTypes
            .map(
              (queryType) => <String, dynamic>{
                'action': 'reject',
                'qtype': queryType,
              },
            )
            .toList(growable: false),
      },
  };
}

Map<String, dynamic> _buildXrayStreamSettings(
  ParsedVpnProfile profile, {
  String? bindInterface,
}) {
  if (profile.transport == TransportMode.quic) {
    throw StateError(
      'QUIC transport is not supported for Xray in this desktop wrapper yet.',
    );
  }

  final stream = <String, dynamic>{
    'network': switch (profile.transport) {
      TransportMode.raw => 'tcp',
      TransportMode.ws => 'ws',
      TransportMode.grpc => 'grpc',
      TransportMode.httpUpgrade => 'httpupgrade',
      TransportMode.http => 'xhttp',
      TransportMode.xhttp => 'xhttp',
      TransportMode.quic => 'quic',
    },
    'security': switch (profile.tlsMode) {
      TlsMode.none => 'none',
      TlsMode.tls => 'tls',
      TlsMode.reality => 'reality',
    },
  };

  if (profile.tlsMode == TlsMode.tls) {
    stream['tlsSettings'] = _buildXrayTlsSettings(profile);
  }
  if (profile.tlsMode == TlsMode.reality) {
    stream['realitySettings'] = _buildXrayRealitySettings(profile);
  }
  final normalizedBindInterface = bindInterface?.trim();
  if (normalizedBindInterface != null && normalizedBindInterface.isNotEmpty) {
    stream['sockopt'] = <String, dynamic>{'interface': normalizedBindInterface};
  }

  switch (profile.transport) {
    case TransportMode.raw:
      break;
    case TransportMode.ws:
      stream['wsSettings'] = <String, dynamic>{
        'path': profile.path ?? '/',
        if (profile.host != null)
          'headers': <String, dynamic>{'Host': profile.host},
      };
    case TransportMode.grpc:
      stream['grpcSettings'] = <String, dynamic>{
        'serviceName': profile.serviceName ?? 'grpc',
        if (profile.authority != null) 'authority': profile.authority,
      };
    case TransportMode.httpUpgrade:
      stream['httpupgradeSettings'] = <String, dynamic>{
        'path': profile.path ?? '/',
        if (profile.host != null) 'host': profile.host,
      };
    case TransportMode.http:
    case TransportMode.xhttp:
      stream['xhttpSettings'] = <String, dynamic>{
        'path': profile.path ?? '/',
        if (profile.host != null) 'host': profile.host,
      };
    case TransportMode.quic:
      break;
  }

  return stream;
}

Map<String, dynamic> _buildXrayTlsSettings(ParsedVpnProfile profile) {
  return <String, dynamic>{
    if (profile.sni != null) 'serverName': profile.sni,
    if (profile.allowInsecure) 'allowInsecure': true,
    if (profile.alpn.isNotEmpty) 'alpn': profile.alpn,
    if (profile.fingerprint != null) 'fingerprint': profile.fingerprint,
  };
}

Map<String, dynamic> _buildXrayRealitySettings(ParsedVpnProfile profile) {
  return <String, dynamic>{
    'serverName': profile.sni ?? profile.server,
    'fingerprint': profile.fingerprint ?? 'chrome',
    'password': _require(profile.publicKey, 'REALITY public key'),
    'shortId': profile.shortId ?? '',
    'spiderX': profile.spiderX ?? '',
  };
}

List<String> _buildXrayAndroidDnsServers(TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => <String>['1.1.1.1', '8.8.8.8'],
    TunIpMode.dualStack => <String>[
      '1.1.1.1',
      '8.8.8.8',
      '2606:4700:4700::1111',
      '2001:4860:4860::8888',
    ],
    TunIpMode.ipv6 => <String>['2606:4700:4700::1111', '2001:4860:4860::8888'],
  };
}

List<String> _buildXrayTunDnsServers(TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => <String>['1.1.1.1'],
    TunIpMode.dualStack => <String>['1.1.1.1', '2606:4700:4700::1111'],
    TunIpMode.ipv6 => <String>['2606:4700:4700::1111'],
  };
}

String _buildXrayDnsQueryStrategy(TunIpMode mode) {
  return switch (mode) {
    TunIpMode.ipv4 => 'UseIPv4',
    TunIpMode.dualStack => 'UseIP',
    TunIpMode.ipv6 => 'UseIPv6',
  };
}

List<Map<String, dynamic>> _buildXrayRoutingRules({
  required DomainSplitTunnelSettings domainSplitTunnelSettings,
  required bool useXrayDnsRouting,
  required bool isTunMode,
}) {
  final domainSplitTunnel = domainSplitTunnelSettings.normalized;
  final hasDomainWhitelist =
      domainSplitTunnel.mode == SplitTunnelMode.whitelist;
  final rules = <Map<String, dynamic>>[
    if (useXrayDnsRouting)
      <String, dynamic>{
        'type': 'field',
        'inboundTag': <String>[isTunMode ? 'tun-in' : 'socks-in'],
        'port': '53',
        'outboundTag': 'dns-out',
      },
    if (isTunMode)
      <String, dynamic>{
        'type': 'field',
        'network': 'udp',
        'port': '443',
        'outboundTag': 'block',
      },
  ];

  if (domainSplitTunnel.hasSelectedDomains) {
    switch (domainSplitTunnel.mode) {
      case SplitTunnelMode.off:
        break;
      case SplitTunnelMode.whitelist:
        rules.add(
          _buildXrayDomainRouteRule(
            domainSplitTunnel.domains,
            outboundTag: 'proxy',
          ),
        );
      case SplitTunnelMode.blacklist:
        rules.add(
          _buildXrayDomainRouteRule(
            domainSplitTunnel.domains,
            outboundTag: 'direct',
          ),
        );
    }
  }

  if (hasDomainWhitelist) {
    rules.add(_buildXrayCatchAllRouteRule(outboundTag: 'direct'));
  }
  return rules;
}

Map<String, dynamic> _buildXrayDomainRouteRule(
  List<SplitTunnelDomain> domains, {
  required String outboundTag,
}) {
  return <String, dynamic>{
    'type': 'field',
    'domain': _buildXrayDomainMatchers(domains),
    'outboundTag': outboundTag,
  };
}

List<String> _buildXrayDomainMatchers(List<SplitTunnelDomain> domains) {
  final matchers =
      domains
          .map((domain) => domain.normalized.matchSuffix)
          .where((domain) => domain.isNotEmpty)
          .map((domain) => 'domain:$domain')
          .toSet()
          .toList(growable: false)
        ..sort();
  return matchers;
}

Map<String, dynamic> _buildXrayCatchAllRouteRule({
  required String outboundTag,
}) {
  return <String, dynamic>{
    'type': 'field',
    'network': 'tcp,udp',
    'outboundTag': outboundTag,
  };
}
