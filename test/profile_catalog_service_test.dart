import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:entropy_vpn/models/config_source.dart';
import 'package:entropy_vpn/models/vpn_profile.dart';
import 'package:entropy_vpn/services/config_source_export.dart';
import 'package:entropy_vpn/services/profile_catalog_service.dart';

void main() {
  group('ProfileCatalogService', () {
    final service = ProfileCatalogService();

    test('resolves inline base64 subscription payloads', () {
      final payload = base64.encode(
        utf8.encode(
          [
            'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsocket&sni=server.example.com#Demo',
            'ss://YWVzLTI1Ni1nY206c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#SS',
          ].join('\n'),
        ),
      );

      final catalog = service.resolveInline(payload);

      expect(catalog.isSubscription, isTrue);
      expect(catalog.profiles, hasLength(2));
      expect(catalog.profiles.first.protocol, LinkProtocol.vless);
      expect(catalog.profiles.last.protocol, LinkProtocol.shadowsocks);
      expect(catalog.profiles.last.remark, 'SS');
    });

    test('resolves inline multi-link text as a selectable catalog', () {
      final catalog = service.resolveInline(
        [
          'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
          'ss://YWVzLTI1Ni1nY206c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#SS',
        ].join('\n'),
      );

      expect(catalog.isSubscription, isTrue);
      expect(catalog.profiles, hasLength(2));
      expect(catalog.profiles.first.protocol, LinkProtocol.trojan);
    });

    test('extracts multiple share links from single-line payloads', () {
      final catalog = service.resolveInline(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=tls&type=ws#One '
        'ss://YWVzLTI1Ni1nY206c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#SS',
      );

      expect(catalog.isSubscription, isTrue);
      expect(catalog.profiles, hasLength(2));
      expect(catalog.profiles.first.remark, 'One');
      expect(catalog.profiles.last.protocol, LinkProtocol.shadowsocks);
    });

    test('extracts Hysteria links from subscription payloads', () {
      final catalog = service.resolveInline(
        [
          'hy2://secret@hy2.example.com:443/?obfs=salamander&obfs-password=obfs-secret&sni=sni.example.com#Hy2',
          'hysteria://hy.example.com:8443?auth=secret&upmbps=100&downmbps=200#Hy',
        ].join('\n'),
      );

      expect(catalog.isSubscription, isTrue);
      expect(catalog.profiles, hasLength(2));
      expect(catalog.profiles.first.protocol, LinkProtocol.hysteria2);
      expect(catalog.profiles.first.server, 'hy2.example.com');
      expect(catalog.profiles.last.protocol, LinkProtocol.hysteria);
      expect(catalog.profiles.last.uploadMbps, 100);
    });

    test('resolves inline sing-box JSON configs', () {
      final catalog = service.resolveInline(
        jsonEncode(<String, dynamic>{
          'log': <String, dynamic>{'level': 'info'},
          'inbounds': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'tun',
              'tag': 'tun-in',
              'address': <String>['172.19.0.1/30'],
              'auto_route': true,
              'strict_route': true,
            },
          ],
          'outbounds': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'vless',
              'tag': 'proxy',
              'server': 'vpn.example.com',
              'server_port': 443,
              'uuid': '11111111-1111-1111-1111-111111111111',
            },
            <String, dynamic>{'type': 'direct', 'tag': 'direct'},
          ],
          'route': <String, dynamic>{'final': 'proxy'},
        }),
      );

      expect(catalog.isSubscription, isFalse);
      expect(catalog.profiles, hasLength(1));
      expect(catalog.profiles.first.isSingBoxConfig, isTrue);
      expect(catalog.profiles.first.server, 'vpn.example.com');
      expect(catalog.profiles.first.port, 443);
      expect(catalog.profiles.first.singBoxOutboundType, 'vless');
      expect(catalog.profiles.first.protocol, LinkProtocol.vless);
      expect(catalog.profiles.first.transport, TransportMode.raw);
      expect(catalog.profiles.first.tlsMode, TlsMode.none);
      expect(
        jsonDecode(catalog.profiles.first.singBoxConfigJson!),
        isA<Map<String, dynamic>>(),
      );
    });

    test('resolves inline Xray JSON configs', () {
      final catalog = service.resolveInline(
        jsonEncode(<String, dynamic>{
          'log': <String, dynamic>{'loglevel': 'warning'},
          'inbounds': <Map<String, dynamic>>[
            <String, dynamic>{
              'protocol': 'socks',
              'tag': 'socks-in',
              'listen': '127.0.0.1',
              'port': 1080,
            },
          ],
          'outbounds': <Map<String, dynamic>>[
            <String, dynamic>{
              'protocol': 'vless',
              'tag': 'proxy',
              'settings': <String, dynamic>{
                'vnext': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'address': 'xray.example.com',
                    'port': 443,
                    'users': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': '11111111-1111-1111-1111-111111111111',
                        'encryption': 'none',
                        'flow': 'xtls-rprx-vision',
                      },
                    ],
                  },
                ],
              },
              'streamSettings': <String, dynamic>{
                'network': 'ws',
                'security': 'tls',
                'tlsSettings': <String, dynamic>{
                  'serverName': 'server.example.com',
                  'alpn': <String>['h2'],
                  'fingerprint': 'chrome',
                },
                'wsSettings': <String, dynamic>{
                  'path': '/vpn',
                  'headers': <String, dynamic>{'Host': 'cdn.example.com'},
                },
              },
            },
            <String, dynamic>{'protocol': 'freedom', 'tag': 'direct'},
          ],
          'routing': <String, dynamic>{
            'domainStrategy': 'AsIs',
            'rules': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'field', 'outboundTag': 'proxy'},
            ],
          },
        }),
      );

      final profile = catalog.profiles.single;
      expect(catalog.isSubscription, isFalse);
      expect(profile.isXrayConfig, isTrue);
      expect(profile.isSingBoxConfig, isFalse);
      expect(profile.server, 'xray.example.com');
      expect(profile.port, 443);
      expect(profile.xrayOutboundProtocol, 'vless');
      expect(profile.protocol, LinkProtocol.vless);
      expect(profile.transport, TransportMode.ws);
      expect(profile.tlsMode, TlsMode.tls);
      expect(profile.sni, 'server.example.com');
      expect(profile.alpn, <String>['h2']);
      expect(profile.host, 'cdn.example.com');
      expect(profile.path, '/vpn');
      expect(profile.fingerprint, 'chrome');
      expect(profile.flow, 'xtls-rprx-vision');
      expect(jsonDecode(profile.xrayConfigJson!), isA<Map<String, dynamic>>());
    });

    test('resolves local sing-box JSON config files', () async {
      final directory = await Directory.systemTemp.createTemp(
        'entropyvpn_singbox_test_',
      );
      addTearDown(() => directory.delete(recursive: true));

      final file = File(
        '${directory.path}${Platform.pathSeparator}config.json',
      );
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'inbounds': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'mixed', 'listen_port': 2080},
          ],
          'outbounds': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'trojan',
              'tag': 'proxy',
              'server': 'trojan.example.com',
              'server_port': 443,
              'password': 'secret',
            },
          ],
        }),
      );

      final catalog = await service.resolve(file.path);

      expect(catalog.profiles.single.isSingBoxConfig, isTrue);
      expect(catalog.profiles.single.remark, 'config.json');
      expect(catalog.profiles.single.singBoxConfigDirectory, directory.path);
      expect(catalog.profiles.single.server, 'trojan.example.com');
    });

    test('resolves exported source JSON files', () async {
      final directory = await Directory.systemTemp.createTemp(
        'entropyvpn_export_test_',
      );
      addTearDown(() => directory.delete(recursive: true));

      const source = ConfigSource(
        id: 'source-1',
        rawInput: 'https://example.com/subscription',
        kind: ConfigSourceKind.subscription,
        profiles: <ParsedVpnProfile>[
          ParsedVpnProfile(
            protocol: LinkProtocol.vless,
            server: 'exported.example.com',
            port: 443,
            transport: TransportMode.ws,
            tlsMode: TlsMode.tls,
            userId: '11111111-1111-1111-1111-111111111111',
            remark: 'Exported profile',
          ),
        ],
        autoUpdateIntervalMinutes: 120,
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}exported.json',
      );
      await file.writeAsString(
        ConfigSourceExport.encode(source, exportedAt: DateTime.utc(2026, 5, 2)),
      );

      final catalog = await service.resolve(file.path);

      expect(catalog.isSubscription, isTrue);
      expect(catalog.sourceRawInput, source.rawInput);
      expect(catalog.profiles.single.server, 'exported.example.com');
      expect(catalog.profiles.single.remark, 'Exported profile');
    });

    test('fetches and resolves remote plain-text subscriptions', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write(
          [
            'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsocket&sni=server.example.com#Demo',
            'ss://YWVzLTI1Ni1nY206c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#SS',
          ].join('\n'),
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/subscription',
      );

      expect(catalog.isSubscription, isTrue);
      expect(catalog.sourceName, 'subscription');
      expect(catalog.profiles, hasLength(2));
      expect(catalog.profiles.first.remark, 'Demo');
      expect(catalog.profiles.last.remark, 'SS');
    });

    test('captures remote subscription title headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.headers
          ..contentType = ContentType.text
          ..set('Profile-Title', 'Demo%20Subscription');
        request.response.write(
          'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none#Demo',
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/subscription',
      );

      expect(catalog.sourceName, 'Demo Subscription');
    });

    test('uses remote subscription URL fragments as title fallback', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write(
          'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none#Demo',
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/sub/176449930893983717#BlookVPN',
      );

      expect(catalog.sourceName, 'BlookVPN');
    });

    test('captures remote subscription traffic usage headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final expiresAt = DateTime.utc(2026, 5, 15);
      final expireSeconds = expiresAt.millisecondsSinceEpoch ~/ 1000;

      server.listen((request) async {
        request.response.headers
          ..contentType = ContentType.text
          ..set(
            'Subscription-Userinfo',
            'upload=1073741824; download=2147483648; '
                'total=10737418240; expire=$expireSeconds',
          );
        request.response.write(
          'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none#Demo',
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/subscription',
      );

      expect(catalog.trafficUsage?.uploadBytes, 1024 * 1024 * 1024);
      expect(catalog.trafficUsage?.downloadBytes, 2 * 1024 * 1024 * 1024);
      expect(catalog.trafficUsage?.totalBytes, 10 * 1024 * 1024 * 1024);
      expect(catalog.trafficUsage?.expiresAt?.toUtc(), expiresAt);
    });

    test('captures alternate subscription traffic header spellings', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.headers
          ..contentType = ContentType.text
          ..set(
            'Subscription-User-Info',
            'up=1024, down=2048, total=4096, expire=0',
          );
        request.response.write(
          'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none#Demo',
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/subscription',
      );

      expect(catalog.trafficUsage?.uploadBytes, 1024);
      expect(catalog.trafficUsage?.downloadBytes, 2048);
      expect(catalog.trafficUsage?.totalBytes, 4096);
      expect(catalog.trafficUsage?.expiresAt, isNull);
    });

    test('announces EntropyVPN subscription device identity', () async {
      final service = ProfileCatalogService()
        ..subscriptionDeviceId = 'entropyvpn-test-device';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      String? userAgent;
      String? hwid;
      String? deviceOs;

      server.listen((request) async {
        userAgent = request.headers.value(HttpHeaders.userAgentHeader);
        hwid = request.headers.value('x-hwid');
        deviceOs = request.headers.value('x-device-os');
        request.response.headers.contentType = ContentType.text;
        request.response.write(
          'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none#Demo',
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/subscription',
      );

      expect(catalog.profiles, hasLength(1));
      expect(userAgent, 'EntropyVPN/1.5.0');
      expect(hwid, 'entropyvpn-test-device');
      expect(deviceOs, isNotEmpty);
    });

    test('fetches and resolves remote base64 subscriptions', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final payload = base64.encode(
        utf8.encode(
          [
            'trojan://password@example.com:443?security=tls&type=ws&host=cdn.example.com&path=%2Fvpn&sni=server.example.com#Trojan',
            'ss://YWVzLTI1Ni1nY206c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#SS',
          ].join('\n'),
        ),
      );

      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write(payload);
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/subscription',
      );

      expect(catalog.isSubscription, isTrue);
      expect(catalog.profiles, hasLength(2));
      expect(catalog.profiles.first.protocol, LinkProtocol.trojan);
      expect(catalog.profiles.last.protocol, LinkProtocol.shadowsocks);
    });

    test('fetches and resolves remote sing-box JSON configs', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.headers
          ..contentType = ContentType.json
          ..set('Profile-Title', 'Remote office');
        request.response.write(
          jsonEncode(<String, dynamic>{
            'inbounds': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tun',
                'address': <String>['172.19.0.1/30'],
                'auto_route': true,
              },
            ],
            'outbounds': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'shadowsocks',
                'tag': 'proxy',
                'server': 'ss.example.com',
                'server_port': 8388,
                'method': '2022-blake3-aes-128-gcm',
                'password': 'secret',
              },
            ],
          }),
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/sing-box.json',
      );

      expect(catalog.isSubscription, isTrue);
      expect(catalog.profiles.single.isSingBoxConfig, isTrue);
      expect(catalog.profiles.single.remark, 'Remote office');
      expect(catalog.profiles.single.server, 'ss.example.com');
      expect(catalog.profiles.single.port, 8388);
      expect(catalog.profiles.single.singBoxOutboundType, 'shadowsocks');
      expect(catalog.profiles.single.protocol, LinkProtocol.shadowsocks);
    });

    test('uses remote path as sing-box JSON profile title fallback', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, dynamic>{
            'outbounds': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'vless',
                'tag': 'proxy',
                'server': 'fallback.example.com',
                'server_port': 443,
                'uuid': '11111111-1111-1111-1111-111111111111',
              },
            ],
          }),
        );
        await request.response.close();
      });

      final catalog = await service.resolve(
        'http://${server.address.address}:${server.port}/ethical?format=json',
      );

      expect(catalog.profiles.single.remark, 'ethical');
      expect(catalog.profiles.single.server, 'fallback.example.com');
    });

    test('extracts metadata from selector-wrapped sing-box outbounds', () {
      final catalog = service.resolveInline(
        jsonEncode(<String, dynamic>{
          'outbounds': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'selector',
              'tag': 'proxy',
              'outbounds': <String>['auto', 'direct', 'vless-reality'],
            },
            <String, dynamic>{
              'type': 'urltest',
              'tag': 'auto',
              'outbounds': <String>['vless-reality'],
            },
            <String, dynamic>{'type': 'direct', 'tag': 'direct'},
            <String, dynamic>{
              'type': 'vless',
              'tag': 'vless-reality',
              'server': '209.99.191.16',
              'server_port': 443,
              'uuid': 'a9c3c068-7630-4160-9f62-d89faab31343',
              'tls': <String, dynamic>{
                'enabled': true,
                'server_name': 'addons.mozilla.org',
                'utls': <String, dynamic>{
                  'enabled': true,
                  'fingerprint': 'chrome',
                },
                'reality': <String, dynamic>{
                  'enabled': true,
                  'public_key': 'public-key',
                  'short_id': 'short-id',
                },
              },
              'transport': <String, dynamic>{},
            },
          ],
          'route': <String, dynamic>{'final': 'proxy'},
        }),
      );

      final profile = catalog.profiles.single;
      expect(profile.server, '209.99.191.16');
      expect(profile.port, 443);
      expect(profile.singBoxOutboundType, 'vless');
      expect(profile.protocol, LinkProtocol.vless);
      expect(profile.transport, TransportMode.raw);
      expect(profile.tlsMode, TlsMode.reality);
      expect(profile.sni, 'addons.mozilla.org');
      expect(profile.fingerprint, 'chrome');
      expect(profile.publicKey, 'public-key');
      expect(profile.shortId, 'short-id');
      expect(profile.userId, 'a9c3c068-7630-4160-9f62-d89faab31343');
    });

    test('fetches sing-box remote profile import links', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, dynamic>{
            'inbounds': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tun',
                'address': <String>['172.19.0.1/30'],
                'auto_route': true,
              },
            ],
            'outbounds': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'hysteria2',
                'tag': 'proxy',
                'server': 'hy2.example.com',
                'server_port': 443,
                'password': 'secret',
              },
            ],
          }),
        );
        await request.response.close();
      });

      final remoteUrl =
          'http://${server.address.address}:${server.port}/profile.json';
      final importLink =
          'sing-box://import-remote-profile?url=${Uri.encodeQueryComponent(remoteUrl)}#Office';
      final catalog = await service.resolve(importLink);

      expect(catalog.isSubscription, isTrue);
      expect(catalog.profiles.single.isSingBoxConfig, isTrue);
      expect(catalog.profiles.single.remark, 'Office');
      expect(catalog.profiles.single.server, 'hy2.example.com');
      expect(catalog.profiles.single.port, 443);
      expect(catalog.profiles.single.protocol, LinkProtocol.hysteria2);
      expect(catalog.profiles.single.singBoxOutboundType, 'hysteria2');
    });
  });
}
