import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:entropy_vpn/models/split_tunnel.dart';
import 'package:entropy_vpn/models/vpn_profile.dart';
import 'package:entropy_vpn/services/core_config_builder.dart';
import 'package:entropy_vpn/services/share_link_parser.dart';

void main() {
  group('ShareLinkParser', () {
    final parser = ShareLinkParser();

    test('parses VLESS share links', () {
      final profile = parser.parse(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsocket&sni=server.example.com#Demo',
      );

      expect(profile.protocol, LinkProtocol.vless);
      expect(profile.server, 'example.com');
      expect(profile.port, 443);
      expect(profile.transport, TransportMode.ws);
      expect(profile.tlsMode, TlsMode.tls);
      expect(profile.userId, '11111111-1111-1111-1111-111111111111');
      expect(profile.host, 'cdn.example.com');
      expect(profile.path, '/socket');
      expect(profile.remark, 'Demo');
    });

    test('parses VMess share links', () {
      const payload =
          'eyJhZGQiOiJ2bWVzcy5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjIyMjIyMjIyLTIyMjItMjIyMi0yMjIyLTIyMjIyMjIyMjIyMiIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0IjoiZ3JwYyIsInRscyI6InRscyIsInBhdGgiOiJ2cG5TZXJ2aWNlIiwicHMiOiJMYWIifQ==';

      final profile = parser.parse('vmess://$payload');

      expect(profile.protocol, LinkProtocol.vmess);
      expect(profile.transport, TransportMode.grpc);
      expect(profile.tlsMode, TlsMode.tls);
      expect(profile.serviceName, 'vpnService');
      expect(profile.remark, 'Lab');
    });

    test('parses Shadowsocks share links', () {
      final profile = parser.parse(
        'ss://YWVzLTI1Ni1nY206c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#SS',
      );

      expect(profile.protocol, LinkProtocol.shadowsocks);
      expect(profile.server, 'example.com');
      expect(profile.port, 8388);
      expect(profile.method, 'aes-256-gcm');
      expect(profile.password, 'secret');
      expect(profile.remark, 'SS');
    });

    test('parses XHTTP transport share links', () {
      final profile = parser.parse(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=tls&type=xhttp&host=cdn.example.com&path=%2Fxhttp&sni=server.example.com&alpn=h3#XHTTP',
      );

      expect(profile.protocol, LinkProtocol.vless);
      expect(profile.transport, TransportMode.xhttp);
      expect(profile.tlsMode, TlsMode.tls);
      expect(profile.host, 'cdn.example.com');
      expect(profile.path, '/xhttp');
      expect(profile.alpn, <String>['h3']);
      expect(profile.remark, 'XHTTP');
    });

    test('parses Hysteria share links', () {
      final profile = parser.parse(
        'hysteria://hy.example.com:8443?protocol=udp&auth=secret&peer=sni.example.com&insecure=1&upmbps=100&downmbps=200&alpn=hysteria&obfs=xplus&obfsParam=obfs-secret#Hy',
      );

      expect(profile.protocol, LinkProtocol.hysteria);
      expect(profile.server, 'hy.example.com');
      expect(profile.port, 8443);
      expect(profile.transport, TransportMode.quic);
      expect(profile.password, 'secret');
      expect(profile.sni, 'sni.example.com');
      expect(profile.allowInsecure, isTrue);
      expect(profile.uploadMbps, 100);
      expect(profile.downloadMbps, 200);
      expect(profile.hysteriaNetwork, 'udp');
      expect(profile.obfs, 'xplus');
      expect(profile.obfsPassword, 'obfs-secret');
    });

    test('parses Hysteria2 share links', () {
      final profile = parser.parse(
        'hysteria2://user%3Asecret@hy2.example.com:443/?insecure=1&obfs=salamander&obfs-password=obfs-secret&sni=sni.example.com#Hy2',
      );

      expect(profile.protocol, LinkProtocol.hysteria2);
      expect(profile.server, 'hy2.example.com');
      expect(profile.port, 443);
      expect(profile.transport, TransportMode.quic);
      expect(profile.password, 'user:secret');
      expect(profile.sni, 'sni.example.com');
      expect(profile.allowInsecure, isTrue);
      expect(profile.obfs, 'salamander');
      expect(profile.obfsPassword, 'obfs-secret');
      expect(profile.remark, 'Hy2');
    });
  });

  group('CoreConfigBuilder', () {
    final parser = ShareLinkParser();
    final builder = CoreConfigBuilder();

    test('builds sing-box REALITY config', () {
      final profile = parser.parse(
        'vless://11111111-1111-1111-1111-111111111111@reality.example.com:443?encryption=none&security=reality&type=tcp&sni=cdn.example.com&fp=chrome&pbk=publicKey&sid=abcd1234&spx=%2F#Reality',
      );

      final config = builder.buildSingBox(profile);
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final tls = outbound['tls'] as Map<String, dynamic>;

      expect(outbound['type'], 'vless');
      expect(
        (tls['reality'] as Map<String, dynamic>)['public_key'],
        'publicKey',
      );
      expect((tls['utls'] as Map<String, dynamic>)['fingerprint'], 'chrome');
    });

    test('builds sing-box QUIC transport config', () {
      final profile = parser.parse(
        'vless://11111111-1111-1111-1111-111111111111@quic.example.com:443?encryption=none&security=tls&type=quic&sni=server.example.com#QUIC',
      );

      final config = builder.buildSingBox(profile);
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;

      expect(outbound['type'], 'vless');
      expect(outbound['transport'], <String, dynamic>{'type': 'quic'});
      expect((outbound['tls'] as Map<String, dynamic>)['enabled'], isTrue);
    });

    test('builds sing-box Hysteria config', () {
      final profile = parser.parse(
        'hysteria://hy.example.com:8443?protocol=udp&auth=secret&peer=sni.example.com&upmbps=100&downmbps=200&obfsParam=obfs-secret#Hy',
      );

      final config = builder.buildSingBox(profile);
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final tls = outbound['tls'] as Map<String, dynamic>;

      expect(outbound['type'], 'hysteria');
      expect(outbound['server'], 'hy.example.com');
      expect(outbound['server_port'], 8443);
      expect(outbound['auth_str'], 'secret');
      expect(outbound['up_mbps'], 100);
      expect(outbound['down_mbps'], 200);
      expect(outbound['network'], 'udp');
      expect(outbound['obfs'], 'obfs-secret');
      expect(tls['server_name'], 'sni.example.com');
    });

    test('builds sing-box Hysteria2 config', () {
      final profile = parser.parse(
        'hy2://secret@hy2.example.com:443/?obfs=salamander&obfs-password=obfs-secret&sni=sni.example.com#Hy2',
      );

      final config = builder.buildSingBox(profile);
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final tls = outbound['tls'] as Map<String, dynamic>;
      final obfs = outbound['obfs'] as Map<String, dynamic>;

      expect(outbound['type'], 'hysteria2');
      expect(outbound['server'], 'hy2.example.com');
      expect(outbound['server_port'], 443);
      expect(outbound['password'], 'secret');
      expect(obfs['type'], 'salamander');
      expect(obfs['password'], 'obfs-secret');
      expect(tls['server_name'], 'sni.example.com');
    });

    test('builds sing-box TUN config for VLESS REALITY Vision', () {
      final profile = parser.parse(
        'vless://1378b49d-8628-4aae-abcc-129f6c8b4ed1@209.99.191.16:50776?type=tcp&security=reality&pbk=KT_TIvPMLHtQmvBrGcS7BTWXXec1c1-q5rVB3r_GjWM&sid=e80f&fp=chrome&sni=www.samsung.com&flow=xtls-rprx-vision#vless-reality-httpupgrade',
      );

      final config = builder.buildSingBox(
        profile,
        trafficMode: TrafficMode.tun,
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final tls = outbound['tls'] as Map<String, dynamic>;

      expect(inbound['type'], 'tun');
      expect(inbound['route_exclude_address'], contains('209.99.191.16/32'));
      expect(outbound['type'], 'vless');
      expect(outbound['flow'], 'xtls-rprx-vision');
      expect(outbound['server'], '209.99.191.16');
      expect(outbound['server_port'], 50776);
      expect(tls['server_name'], 'www.samsung.com');
      expect(
        (tls['reality'] as Map<String, dynamic>)['public_key'],
        'KT_TIvPMLHtQmvBrGcS7BTWXXec1c1-q5rVB3r_GjWM',
      );
      expect((tls['reality'] as Map<String, dynamic>)['short_id'], 'e80f');
    });

    test('builds sing-box TUN config', () {
      final profile = parser.parse(
        'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
      );

      final config = builder.buildSingBox(
        profile,
        trafficMode: TrafficMode.tun,
        tunInterfaceName: 'EntropyVPN TUN test',
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final dns = config['dns'] as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;
      final dnsServers = dns['servers'] as List<dynamic>;
      final routeRules = route['rules'] as List<dynamic>;

      expect(inbound['type'], 'tun');
      expect(inbound['interface_name'], 'EntropyVPN TUN test');
      expect(inbound['auto_route'], true);
      expect(inbound['strict_route'], true);
      expect(inbound['stack'], 'mixed');
      expect(inbound['mtu'], 1400);
      expect(inbound['address'], <String>['172.19.0.1/30']);
      expect(inbound['route_address'], <String>['0.0.0.0/1', '128.0.0.0/1']);
      expect(inbound.containsKey('route_exclude_address'), isFalse);
      expect(outbound.containsKey('bind_interface'), isFalse);
      expect(dns['final'], 'dns-remote');
      expect(dns['strategy'], 'ipv4_only');
      expect((dnsServers.first as Map<String, dynamic>)['tag'], 'dns-local');
      expect((dnsServers.last as Map<String, dynamic>)['tag'], 'dns-remote');
      expect((routeRules.first as Map<String, dynamic>)['action'], 'sniff');
      expect((routeRules[1] as Map<String, dynamic>)['action'], 'resolve');
      expect((routeRules[1] as Map<String, dynamic>)['strategy'], 'ipv4_only');
      expect((routeRules[2] as Map<String, dynamic>)['action'], 'hijack-dns');
      expect((routeRules[3] as Map<String, dynamic>)['network'], 'udp');
      expect((routeRules[3] as Map<String, dynamic>)['port'], 443);
      expect((routeRules[3] as Map<String, dynamic>)['action'], 'reject');
      expect(route['default_domain_resolver'], 'dns-local');
      expect(inbound.containsKey('set_system_proxy'), isFalse);
    });

    test('builds dual-stack TUN IP mode', () {
      final profile = parser.parse(
        'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
      );

      final config = builder.buildSingBox(
        profile,
        trafficMode: TrafficMode.tun,
        tunIpMode: TunIpMode.dualStack,
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final dns = config['dns'] as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;
      final routeRules = route['rules'] as List<dynamic>;

      expect(inbound['address'], <String>[
        '172.19.0.1/30',
        'fdfe:dcba:9876::1/126',
      ]);
      expect(inbound.containsKey('route_address'), isFalse);
      expect(dns['strategy'], 'prefer_ipv4');
      expect(
        (routeRules[1] as Map<String, dynamic>)['strategy'],
        'prefer_ipv4',
      );
    });

    test('builds IPv6-only TUN IP mode', () {
      final profile = parser.parse(
        'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
      );

      final config = builder.buildSingBox(
        profile,
        trafficMode: TrafficMode.tun,
        tunIpMode: TunIpMode.ipv6,
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final dns = config['dns'] as Map<String, dynamic>;

      expect(inbound['address'], <String>['fdfe:dcba:9876::1/126']);
      expect(inbound['route_address'], <String>['::/1', '8000::/1']);
      expect(dns['strategy'], 'ipv6_only');
    });

    test('applies TUN IP mode to native sing-box configs', () {
      final config = <String, dynamic>{
        'inbounds': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'tun',
            'tag': 'tun-in',
            'mtu': 9000,
            'address': <String>['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
            'route_address': <String>[
              '0.0.0.0/1',
              '128.0.0.0/1',
              '::/1',
              '8000::/1',
            ],
            'auto_route': true,
          },
        ],
        'dns': <String, dynamic>{'servers': <Map<String, dynamic>>[]},
        'route': <String, dynamic>{
          'rules': <Map<String, dynamic>>[
            <String, dynamic>{'inbound': 'tun-in', 'action': 'sniff'},
          ],
          'final': 'proxy',
        },
      };

      final applied = builder.applyNativeSingBoxTunSettings(
        config,
        tunIpMode: TunIpMode.ipv4,
        tunInterfaceName: 'EntropyVPN TUN test',
        mtu: CoreConfigBuilder.tunMtu,
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final dns = config['dns'] as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;
      final rules = route['rules'] as List<dynamic>;

      expect(applied, isTrue);
      expect(inbound['interface_name'], 'EntropyVPN TUN test');
      expect(inbound['mtu'], CoreConfigBuilder.tunMtu);
      expect(inbound['address'], <String>['172.19.0.1/30']);
      expect(inbound['route_address'], <String>['0.0.0.0/1', '128.0.0.0/1']);
      expect(dns['strategy'], 'ipv4_only');
      expect((rules[0] as Map<String, dynamic>)['action'], 'sniff');
      expect((rules[1] as Map<String, dynamic>)['action'], 'resolve');
      expect((rules[1] as Map<String, dynamic>)['inbound'], 'tun-in');
      expect((rules[1] as Map<String, dynamic>)['strategy'], 'ipv4_only');
      expect((rules[2] as Map<String, dynamic>)['action'], 'hijack-dns');
      expect((rules[2] as Map<String, dynamic>)['inbound'], 'tun-in');
    });

    test('adds DNS hijack to native sing-box TUN configs', () {
      final config = <String, dynamic>{
        'inbounds': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'tun',
            'tag': 'tun-in',
            'address': <String>['172.19.0.1/30'],
            'auto_route': true,
          },
          <String, dynamic>{
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': '127.0.0.1',
            'listen_port': 2080,
          },
        ],
        'dns': <String, dynamic>{'servers': <Map<String, dynamic>>[]},
        'route': <String, dynamic>{
          'rules': <Map<String, dynamic>>[
            <String, dynamic>{'action': 'sniff'},
          ],
          'final': 'proxy',
        },
      };

      final applied = builder.applyNativeSingBoxTunSettings(
        config,
        tunIpMode: TunIpMode.ipv4,
      );
      final route = config['route'] as Map<String, dynamic>;
      final rules = route['rules'] as List<dynamic>;

      expect(applied, isTrue);
      expect((rules[0] as Map<String, dynamic>)['action'], 'sniff');
      expect((rules[1] as Map<String, dynamic>)['action'], 'resolve');
      expect((rules[1] as Map<String, dynamic>)['inbound'], 'tun-in');
      expect((rules[2] as Map<String, dynamic>)['action'], 'hijack-dns');
      expect((rules[2] as Map<String, dynamic>)['inbound'], 'tun-in');
      expect(jsonEncode(rules[2]), contains('"protocol":"dns"'));
      expect(jsonEncode(rules[2]), contains('"port":53'));
    });

    test('normalizes native sing-box TUN configs for Android SFA runtime', () {
      final config = <String, dynamic>{
        'inbounds': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'tun',
            'tag': 'tun-in',
            'interface_name': 'desktop-tun',
            'stack': 'mixed',
            'strict_route': true,
            'gso': true,
            'mtu': 9000,
            'address': <String>['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
            'auto_route': true,
          },
        ],
        'dns': <String, dynamic>{'servers': <Map<String, dynamic>>[]},
        'route': <String, dynamic>{'final': 'proxy'},
      };

      final applied = builder.applyNativeSingBoxTunSettings(
        config,
        tunIpMode: TunIpMode.dualStack,
        mtu: CoreConfigBuilder.tunMtu,
        androidCompatibility: true,
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;

      expect(applied, isTrue);
      expect(inbound['stack'], CoreConfigBuilder.androidTunStack);
      expect(inbound['mtu'], CoreConfigBuilder.tunMtu);
      expect(inbound.containsKey('interface_name'), isFalse);
      expect(inbound.containsKey('strict_route'), isFalse);
      expect(inbound.containsKey('gso'), isFalse);
      expect(route['auto_detect_interface'], isTrue);
    });

    test('keeps existing native sing-box DNS hijack rules', () {
      final existingHijack = <String, dynamic>{
        'protocol': 'dns',
        'action': 'hijack-dns',
      };
      final config = <String, dynamic>{
        'inbounds': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'tun',
            'tag': 'tun-in',
            'address': <String>['172.19.0.1/30'],
            'auto_route': true,
          },
        ],
        'dns': <String, dynamic>{'servers': <Map<String, dynamic>>[]},
        'route': <String, dynamic>{
          'rules': <Map<String, dynamic>>[
            <String, dynamic>{'action': 'sniff'},
            <String, dynamic>{'action': 'resolve', 'strategy': 'prefer_ipv4'},
            existingHijack,
          ],
          'final': 'proxy',
        },
      };

      final applied = builder.applyNativeSingBoxTunSettings(
        config,
        tunIpMode: TunIpMode.ipv4,
      );
      final route = config['route'] as Map<String, dynamic>;
      final rules = route['rules'] as List<dynamic>;

      expect(applied, isTrue);
      expect(
        rules.where((rule) {
          return rule is Map &&
              rule['action']?.toString().trim().toLowerCase() == 'hijack-dns';
        }),
        hasLength(1),
      );
      expect(identical(rules[2], existingHijack), isTrue);
    });

    test('builds TUN route exclusion for IP server', () {
      final profile = parser.parse(
        'trojan://password@209.99.191.16:56033?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#TrojanIP',
      );

      final config = builder.buildSingBox(
        profile,
        trafficMode: TrafficMode.tun,
        routeDefaultInterface: 'Ethernet',
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;

      expect(inbound['route_exclude_address'], contains('209.99.191.16/32'));
      expect(outbound.containsKey('bind_interface'), isFalse);
      expect(route['auto_detect_interface'], isFalse);
      expect(route['default_interface'], 'Ethernet');
    });

    test('builds TUN split tunnel whitelist rules', () {
      final profile = parser.parse(
        'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
      );

      final config = builder.buildSingBox(
        profile,
        trafficMode: TrafficMode.tun,
        splitTunnelSettings: const SplitTunnelSettings(
          mode: SplitTunnelMode.whitelist,
          apps: <SplitTunnelApp>[
            SplitTunnelApp(
              id: r'c:\apps\code\code.exe',
              name: 'Visual Studio Code',
              path: r'C:\Apps\Code\Code.exe',
            ),
          ],
        ),
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;
      final routeRulesJson = jsonEncode(route['rules']);

      expect(inbound['strict_route'], isFalse);
      expect(route['final'], 'direct');
      expect(routeRulesJson, contains('process_name'));
      expect(routeRulesJson, contains('Code.exe'));
      expect(routeRulesJson, contains('Code'));
      expect(routeRulesJson, contains('code'));
      expect(routeRulesJson, contains(r'C:\\Apps\\Code\\Code.exe'));
      expect(routeRulesJson, contains('process_path_regex'));
      expect(routeRulesJson, contains(r'C:\\Apps\\Code'));
      expect(routeRulesJson, contains('"action":"route"'));
      expect(routeRulesJson, contains('"outbound":"proxy"'));
    });

    test('builds TUN split tunnel blacklist rules', () {
      final profile = parser.parse(
        'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
      );

      final config = builder.buildSingBox(
        profile,
        trafficMode: TrafficMode.tun,
        splitTunnelSettings: const SplitTunnelSettings(
          mode: SplitTunnelMode.blacklist,
          apps: <SplitTunnelApp>[
            SplitTunnelApp(
              id: r'c:\apps\game.exe',
              name: 'Game',
              path: r'C:\Apps\game.exe',
            ),
          ],
        ),
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;
      final routeRulesJson = jsonEncode(route['rules']);

      expect(inbound['strict_route'], isTrue);
      expect(route['final'], 'proxy');
      expect(routeRulesJson, contains('process_name'));
      expect(routeRulesJson, contains('game.exe'));
      expect(routeRulesJson, contains(r'C:\\Apps\\game.exe'));
      expect(routeRulesJson, contains('"outbound":"direct"'));
    });

    test('builds Xray ws config', () {
      final profile = parser.parse(
        'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
      );

      final config = builder.buildXray(profile);
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final stream = outbound['streamSettings'] as Map<String, dynamic>;

      expect(outbound['protocol'], 'trojan');
      expect(stream['network'], 'ws');
      expect(stream['security'], 'tls');
      expect((stream['wsSettings'] as Map<String, dynamic>)['path'], '/vpn');
    });

    test('builds Xray XHTTP config', () {
      final profile = parser.parse(
        'vless://11111111-1111-1111-1111-111111111111@xhttp.example.com:443?encryption=none&security=tls&type=xhttp&host=cdn.example.com&path=%2Fxhttp&sni=server.example.com&alpn=h3#XHTTP',
      );

      final config = builder.buildXray(profile);
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final stream = outbound['streamSettings'] as Map<String, dynamic>;
      final xhttp = stream['xhttpSettings'] as Map<String, dynamic>;

      expect(stream['network'], 'xhttp');
      expect(stream['security'], 'tls');
      expect(xhttp['path'], '/xhttp');
      expect(xhttp['host'], 'cdn.example.com');
      expect((stream['tlsSettings'] as Map<String, dynamic>)['alpn'], <String>[
        'h3',
      ]);
    });

    test('builds Xray TCP config for raw transport like v2rayNG', () {
      final profile = parser.parse(
        'vless://1378b49d-8628-4aae-abcc-129f6c8b4ed1@example.com:443?type=tcp&security=reality&pbk=publicKey&sid=e80f&fp=chrome&sni=www.samsung.com&flow=xtls-rprx-vision#RealityTCP',
      );

      final config = builder.buildXray(profile);
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final stream = outbound['streamSettings'] as Map<String, dynamic>;

      expect(stream['network'], 'tcp');
      expect(stream['security'], 'reality');
    });

    test('builds Xray TUN config with generated Windows interface name', () {
      final profile = parser.parse(
        'vless://1378b49d-8628-4aae-abcc-129f6c8b4ed1@example.com:443?type=tcp&security=reality&pbk=publicKey&sid=e80f&fp=chrome&sni=www.samsung.com&flow=xtls-rprx-vision#RealityTCP',
      );

      final config = builder.buildFor(
        CoreFlavor.xray,
        profile,
        trafficMode: TrafficMode.tun,
        tunInterfaceName: 'EntropyVPN TUN test',
        outboundBindInterface: 'Ethernet',
        xrayServerAddressOverride: '203.0.113.8',
      );
      final inbound =
          (config['inbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final settings = inbound['settings'] as Map<String, dynamic>;
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      final outbounds = config['outbounds'] as List<dynamic>;
      final stream = outbound['streamSettings'] as Map<String, dynamic>;
      final sockopt = stream['sockopt'] as Map<String, dynamic>;
      final dns = config['dns'] as Map<String, dynamic>;
      final routing = config['routing'] as Map<String, dynamic>;
      final rules = routing['rules'] as List<dynamic>;
      final dnsRule = rules.first as Map<String, dynamic>;
      final quicRule = rules[1] as Map<String, dynamic>;
      final dnsOutbound = outbounds
          .whereType<Map<dynamic, dynamic>>()
          .firstWhere((item) => item['tag'] == 'dns-out');
      final dnsOutboundSettings =
          dnsOutbound['settings'] as Map<String, dynamic>;
      final dnsOutboundRules = dnsOutboundSettings['rules'] as List<dynamic>;
      final blockedAaaaRule = dnsOutboundRules.first as Map<String, dynamic>;
      final directOutbound = outbounds
          .whereType<Map<dynamic, dynamic>>()
          .firstWhere((item) => item['tag'] == 'direct');
      final directStream =
          directOutbound['streamSettings'] as Map<String, dynamic>;
      final directSockopt = directStream['sockopt'] as Map<String, dynamic>;
      final vnext =
          (outbound['settings'] as Map<String, dynamic>)['vnext']
              as List<dynamic>;
      final vnextServer = vnext.first as Map<String, dynamic>;

      expect(inbound['protocol'], 'tun');
      expect(settings['name'], 'EntropyVPN TUN test');
      expect(settings['MTU'], CoreConfigBuilder.tunMtu);
      expect(settings['userLevel'], 0);
      expect(settings.containsKey('address'), isFalse);
      expect(settings.containsKey('gateway'), isFalse);
      expect(settings.containsKey('dns'), isFalse);
      expect(inbound.containsKey('auto_route'), isFalse);
      expect(dns['servers'], <String>['1.1.1.1']);
      expect(dns['queryStrategy'], 'UseIPv4');
      expect(dns['tag'], 'dns-query');
      expect(vnextServer['address'], '203.0.113.8');
      expect(sockopt['interface'], 'Ethernet');
      expect(dnsOutbound['protocol'], 'dns');
      expect(blockedAaaaRule['action'], 'reject');
      expect(blockedAaaaRule['qtype'], 28);
      expect(dnsRule['inboundTag'], <String>['tun-in']);
      expect(dnsRule['port'], '53');
      expect(dnsRule['outboundTag'], 'dns-out');
      expect(quicRule['network'], 'udp');
      expect(quicRule['port'], '443');
      expect(quicRule['outboundTag'], 'block');
      expect(directSockopt['interface'], 'Ethernet');
    });
  });
}
