import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/split_tunnel.dart';
import '../models/vpn_profile.dart';

class CoreConfigBuilder {
  static const int singBoxMixedPort = 2080;
  static const int xraySocksPort = 2080;
  static const int xrayHttpPort = 2081;
  static const int tunMtu = 1400;
  static const String androidTunStack = 'gvisor';
  static const String desktopTunStack = 'mixed';

  Map<String, dynamic> buildFor(
    CoreFlavor core,
    ParsedVpnProfile profile, {
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
    String? xrayServerAddressOverride,
  }) {
    return switch (core) {
      CoreFlavor.xray => buildXray(
        profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
        tunInterfaceName: tunInterfaceName,
        outboundBindInterface: outboundBindInterface,
        serverAddressOverride: xrayServerAddressOverride,
      ),
      CoreFlavor.singBox => buildSingBox(
        profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
        tunInterfaceName: tunInterfaceName,
        outboundBindInterface: outboundBindInterface,
        routeDefaultInterface: routeDefaultInterface,
      ),
    };
  }

  Map<String, dynamic> buildSingBox(
    ParsedVpnProfile profile, {
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
  }) {
    final isTunMode = trafficMode == TrafficMode.tun;
    final effectiveSplitTunnel = isTunMode
        ? splitTunnelSettings.normalized
        : const SplitTunnelSettings();
    final effectiveDomainSplitTunnel = isTunMode
        ? domainSplitTunnelSettings.normalized
        : const DomainSplitTunnelSettings();
    final isAndroidTunMode = isTunMode && Platform.isAndroid;
    final effectiveTunIpMode = tunIpMode;
    final tunRouteExcludes = isTunMode ? _buildTunRouteExcludes(profile) : null;
    final normalizedRouteDefaultInterface = routeDefaultInterface?.trim();
    final hasRouteDefaultInterface =
        normalizedRouteDefaultInterface != null &&
        normalizedRouteDefaultInterface.isNotEmpty;
    final dnsServers = isTunMode
        ? _buildTunnelDnsServers(
            includeLocalResolver: !isAndroidTunMode,
            tunIpMode: effectiveTunIpMode,
          )
        : const <Map<String, dynamic>>[];
    final routeRules = isTunMode
        ? _buildTunnelRouteRules(
            effectiveSplitTunnel,
            domainSplitTunnelSettings: effectiveDomainSplitTunnel,
            tunIpMode: effectiveTunIpMode,
          )
        : const <Map<String, dynamic>>[];
    final forceIpv4Tunnel = isTunMode && effectiveTunIpMode == TunIpMode.ipv4;
    final forceIpv6Tunnel = isTunMode && effectiveTunIpMode == TunIpMode.ipv6;
    final normalizedTunInterfaceName = tunInterfaceName?.trim();
    final effectiveTunInterfaceName =
        normalizedTunInterfaceName == null || normalizedTunInterfaceName.isEmpty
        ? 'EntropyVPN TUN'
        : normalizedTunInterfaceName;

    return <String, dynamic>{
      'log': <String, dynamic>{
        'level': isTunMode ? 'debug' : 'info',
        'timestamp': true,
      },
      if (isTunMode)
        'dns': <String, dynamic>{
          'servers': dnsServers,
          'final': 'dns-remote',
          'strategy': switch (effectiveTunIpMode) {
            TunIpMode.ipv4 => 'ipv4_only',
            TunIpMode.dualStack => 'prefer_ipv4',
            TunIpMode.ipv6 => 'ipv6_only',
          },
          'independent_cache': true,
        },
      'inbounds': <Map<String, dynamic>>[
        switch (trafficMode) {
          TrafficMode.systemProxy => <String, dynamic>{
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': '127.0.0.1',
            'listen_port': singBoxMixedPort,
            'set_system_proxy': true,
          },
          TrafficMode.tun => <String, dynamic>{
            'type': 'tun',
            'tag': 'tun-in',
            if (!Platform.isAndroid)
              'interface_name': effectiveTunInterfaceName,
            'mtu': tunMtu,
            'stack': isAndroidTunMode ? androidTunStack : desktopTunStack,
            'address': _buildTunAddresses(effectiveTunIpMode),
            'auto_route': true,
            if (!Platform.isAndroid)
              'strict_route': _shouldEnableStrictRoute(
                effectiveSplitTunnel,
                effectiveDomainSplitTunnel,
              ),
            if (forceIpv4Tunnel || forceIpv6Tunnel)
              'route_address': _buildTunRouteAddresses(effectiveTunIpMode),
            if (tunRouteExcludes!.isNotEmpty)
              'route_exclude_address': tunRouteExcludes,
          },
        },
      ],
      'outbounds': <Map<String, dynamic>>[
        _buildSingBoxOutbound(profile, bindInterface: outboundBindInterface),
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
      ],
      'route': <String, dynamic>{
        if (isTunMode) 'rules': routeRules,
        'final': _buildRouteFinal(
          effectiveSplitTunnel,
          effectiveDomainSplitTunnel,
        ),
        if (isTunMode && !isAndroidTunMode)
          'default_domain_resolver': 'dns-local',
        'auto_detect_interface': isTunMode
            ? (isAndroidTunMode ? true : !hasRouteDefaultInterface)
            : true,
        if (isTunMode && hasRouteDefaultInterface && !isAndroidTunMode)
          'default_interface': normalizedRouteDefaultInterface,
      },
    };
  }

  Map<String, dynamic> buildXray(
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
            'port': xraySocksPort,
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
            'port': xrayHttpPort,
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
              'MTU': tunMtu,
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

  bool applyNativeSingBoxTunSettings(
    Map<String, dynamic> config, {
    required TunIpMode tunIpMode,
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
        _applyAndroidTunCompatibility(inbound);
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

  void _applyAndroidTunCompatibility(Map<String, dynamic> inbound) {
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

  Map<String, dynamic> _buildSingBoxOutbound(
    ParsedVpnProfile profile, {
    String? bindInterface,
  }) {
    final outbound = <String, dynamic>{'tag': 'proxy'};
    final normalizedBindInterface = bindInterface?.trim();
    if (normalizedBindInterface != null && normalizedBindInterface.isNotEmpty) {
      outbound['bind_interface'] = normalizedBindInterface;
    }

    switch (profile.protocol) {
      case LinkProtocol.vless:
        outbound.addAll(<String, dynamic>{
          'type': 'vless',
          'server': profile.server,
          'server_port': profile.port,
          'uuid': _require(profile.userId, 'VLESS user ID'),
          'flow': profile.flow ?? '',
          'packet_encoding': 'xudp',
        });
      case LinkProtocol.vmess:
        outbound.addAll(<String, dynamic>{
          'type': 'vmess',
          'server': profile.server,
          'server_port': profile.port,
          'uuid': _require(profile.userId, 'VMess user ID'),
          'security': profile.security ?? 'auto',
          'alter_id': profile.alterId,
          'packet_encoding': 'xudp',
        });
      case LinkProtocol.trojan:
        outbound.addAll(<String, dynamic>{
          'type': 'trojan',
          'server': profile.server,
          'server_port': profile.port,
          'password': _require(profile.password, 'Trojan password'),
        });
      case LinkProtocol.shadowsocks:
        outbound.addAll(<String, dynamic>{
          'type': 'shadowsocks',
          'server': profile.server,
          'server_port': profile.port,
          'method': _require(profile.method, 'Shadowsocks method'),
          'password': _require(profile.password, 'Shadowsocks password'),
        });
        if (profile.plugin != null) {
          outbound['plugin'] = profile.plugin;
          outbound['plugin_opts'] = profile.pluginOpts ?? '';
        }
      case LinkProtocol.hysteria:
        outbound.addAll(<String, dynamic>{
          'type': 'hysteria',
          'server': profile.server,
          'server_port': profile.port,
          'up_mbps': _requirePositiveInt(
            profile.uploadMbps,
            'Hysteria upload bandwidth',
          ),
          'down_mbps': _requirePositiveInt(
            profile.downloadMbps,
            'Hysteria download bandwidth',
          ),
          if (profile.password != null) 'auth_str': profile.password,
          if (profile.hysteriaNetwork != null)
            'network': profile.hysteriaNetwork,
          if (profile.obfsPassword != null) 'obfs': profile.obfsPassword,
        });
      case LinkProtocol.hysteria2:
        outbound.addAll(<String, dynamic>{
          'type': 'hysteria2',
          'server': profile.server,
          if (profile.serverPorts.isEmpty) 'server_port': profile.port,
          if (profile.serverPorts.isNotEmpty)
            'server_ports': profile.serverPorts,
          if (profile.password != null) 'password': profile.password,
          if (profile.uploadMbps != null) 'up_mbps': profile.uploadMbps,
          if (profile.downloadMbps != null) 'down_mbps': profile.downloadMbps,
          if (profile.hysteriaNetwork != null)
            'network': profile.hysteriaNetwork,
          if (profile.obfs != null || profile.obfsPassword != null)
            'obfs': <String, dynamic>{
              'type': profile.obfs ?? 'salamander',
              'password': _require(
                profile.obfsPassword,
                'Hysteria2 obfs password',
              ),
            },
        });
    }

    final transport = _supportsSingBoxV2RayTransport(profile.protocol)
        ? _buildSingBoxTransport(profile)
        : null;
    if (transport != null) {
      outbound['transport'] = transport;
    }

    final tls = _buildSingBoxTls(profile);
    if (tls != null) {
      outbound['tls'] = tls;
    }

    return outbound;
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

  Map<String, dynamic>? _buildSingBoxTls(ParsedVpnProfile profile) {
    if (profile.tlsMode == TlsMode.none) {
      return null;
    }

    final tls = <String, dynamic>{'enabled': true};

    if (profile.sni != null) {
      tls['server_name'] = profile.sni;
    }
    if (profile.allowInsecure) {
      tls['insecure'] = true;
    }
    if (profile.alpn.isNotEmpty) {
      tls['alpn'] = profile.alpn;
    }
    if (profile.fingerprint != null || profile.tlsMode == TlsMode.reality) {
      tls['utls'] = <String, dynamic>{
        'enabled': true,
        'fingerprint': profile.fingerprint ?? 'chrome',
      };
    }
    if (profile.tlsMode == TlsMode.reality) {
      tls['reality'] = <String, dynamic>{
        'enabled': true,
        'public_key': _require(profile.publicKey, 'REALITY public key'),
        'short_id': profile.shortId ?? '',
      };
    }

    return tls;
  }

  Map<String, dynamic>? _buildSingBoxTransport(ParsedVpnProfile profile) {
    return switch (profile.transport) {
      TransportMode.raw => null,
      TransportMode.ws => <String, dynamic>{
        'type': 'ws',
        'path': profile.path ?? '/',
        if (profile.host != null)
          'headers': <String, dynamic>{'Host': profile.host},
      },
      TransportMode.grpc => <String, dynamic>{
        'type': 'grpc',
        'service_name': profile.serviceName ?? 'grpc',
      },
      TransportMode.http => <String, dynamic>{
        'type': 'http',
        'path': profile.path ?? '/',
        if (profile.host != null) 'host': <String>[profile.host!],
      },
      TransportMode.httpUpgrade => <String, dynamic>{
        'type': 'httpupgrade',
        'path': profile.path ?? '/',
        if (profile.host != null) 'host': profile.host,
      },
      TransportMode.quic => <String, dynamic>{'type': 'quic'},
      TransportMode.xhttp => throw StateError(
        'XHTTP transport is only supported by Xray.',
      ),
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
      stream['sockopt'] = <String, dynamic>{
        'interface': normalizedBindInterface,
      };
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

  bool _supportsSingBoxV2RayTransport(LinkProtocol protocol) {
    return switch (protocol) {
      LinkProtocol.vless || LinkProtocol.vmess || LinkProtocol.trojan => true,
      LinkProtocol.shadowsocks ||
      LinkProtocol.hysteria ||
      LinkProtocol.hysteria2 => false,
    };
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

  String _require(String? value, String name) {
    if (value == null || value.trim().isEmpty) {
      throw StateError('$name is missing in the provided link.');
    }
    return value;
  }

  int _requirePositiveInt(int? value, String name) {
    if (value == null || value <= 0) {
      throw StateError('$name is missing in the provided link.');
    }
    return value;
  }

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

  List<String> _buildXrayAndroidDnsServers(TunIpMode mode) {
    return switch (mode) {
      TunIpMode.ipv4 => <String>['1.1.1.1', '8.8.8.8'],
      TunIpMode.dualStack => <String>[
        '1.1.1.1',
        '8.8.8.8',
        '2606:4700:4700::1111',
        '2001:4860:4860::8888',
      ],
      TunIpMode.ipv6 => <String>[
        '2606:4700:4700::1111',
        '2001:4860:4860::8888',
      ],
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
        ..add(_buildDnsHijackRule())
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
        ..add(_buildDnsHijackRule())
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
          _buildDnsMatcherRule(),
          action: 'hijack-dns',
        ),
      );
    }
    if (domainSplitTunnel.mode == SplitTunnelMode.whitelist &&
        domainSplitTunnel.hasSelectedDomains) {
      rules.add(
        _buildSplitTunnelAndRule(
          _buildDomainMatcherRule(domainSplitTunnel.domains),
          _buildDnsMatcherRule(),
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
      'strategy': _dnsStrategyForTunIpMode(mode),
    };
  }

  bool _shouldEnableStrictRoute(
    SplitTunnelSettings splitTunnelSettings,
    DomainSplitTunnelSettings domainSplitTunnelSettings,
  ) {
    return splitTunnelSettings.mode != SplitTunnelMode.whitelist &&
        domainSplitTunnelSettings.mode != SplitTunnelMode.whitelist;
  }

  Map<String, dynamic> _buildDnsHijackRule() {
    return <String, dynamic>{..._buildDnsMatcherRule(), 'action': 'hijack-dns'};
  }

  Map<String, dynamic> _buildDnsMatcherRule() {
    return <String, dynamic>{
      'type': 'logical',
      'mode': 'or',
      'rules': <Map<String, dynamic>>[
        <String, dynamic>{'protocol': 'dns'},
        <String, dynamic>{'port': 53},
      ],
    };
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

  Map<String, dynamic> _buildDomainMatcherRule(
    List<SplitTunnelDomain> domains,
  ) {
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

    return <String, dynamic>{
      'type': 'logical',
      'mode': 'or',
      'rules': matchers,
    };
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
    dns['strategy'] = _dnsStrategyForTunIpMode(mode);
  }

  String _dnsStrategyForTunIpMode(TunIpMode mode) {
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
    final strategy = _dnsStrategyForTunIpMode(mode);
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

    final hijackRule = _buildDnsHijackRule();
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

  bool _isGenericResolveRule(
    Map<String, dynamic> rule,
    Object? inboundMatcher,
  ) {
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
        protocol.any(
          (item) => item?.toString().trim().toLowerCase() == 'dns',
        )) {
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
}
