part of 'core_config_builder.dart';

Map<String, dynamic> _buildSingBoxConfig(
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
          'listen_port': CoreConfigBuilder.singBoxMixedPort,
          'set_system_proxy': true,
        },
        TrafficMode.tun => <String, dynamic>{
          'type': 'tun',
          'tag': 'tun-in',
          if (!Platform.isAndroid) 'interface_name': effectiveTunInterfaceName,
          'mtu': CoreConfigBuilder.tunMtu,
          'stack': isAndroidTunMode
              ? CoreConfigBuilder.androidTunStack
              : CoreConfigBuilder.desktopTunStack,
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

bool _applyNativeSingBoxTunSettings(
  Map<String, dynamic> config, {
  required TunIpMode tunIpMode,
  String? tunInterfaceName,
  int? mtu,
  bool androidCompatibility = false,
}) {
  return applyNativeSingBoxTunSettingsToConfig(
    config,
    tunIpMode: tunIpMode,
    tunInterfaceName: tunInterfaceName,
    mtu: mtu,
    androidCompatibility: androidCompatibility,
    androidTunStack: CoreConfigBuilder.androidTunStack,
  );
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
        if (profile.hysteriaNetwork != null) 'network': profile.hysteriaNetwork,
        if (profile.obfsPassword != null) 'obfs': profile.obfsPassword,
      });
    case LinkProtocol.hysteria2:
      outbound.addAll(<String, dynamic>{
        'type': 'hysteria2',
        'server': profile.server,
        if (profile.serverPorts.isEmpty) 'server_port': profile.port,
        if (profile.serverPorts.isNotEmpty) 'server_ports': profile.serverPorts,
        if (profile.password != null) 'password': profile.password,
        if (profile.uploadMbps != null) 'up_mbps': profile.uploadMbps,
        if (profile.downloadMbps != null) 'down_mbps': profile.downloadMbps,
        if (profile.hysteriaNetwork != null) 'network': profile.hysteriaNetwork,
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

bool _supportsSingBoxV2RayTransport(LinkProtocol protocol) {
  return switch (protocol) {
    LinkProtocol.vless || LinkProtocol.vmess || LinkProtocol.trojan => true,
    LinkProtocol.shadowsocks ||
    LinkProtocol.hysteria ||
    LinkProtocol.hysteria2 => false,
  };
}

int _requirePositiveInt(int? value, String name) {
  if (value == null || value <= 0) {
    throw StateError('$name is missing in the provided link.');
  }
  return value;
}
