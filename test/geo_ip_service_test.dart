import 'dart:convert';
import 'dart:io';

import 'package:entropy_vpn/services/geo_ip_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GeoIpInfo', () {
    test('tooltip omits subdivision and timezone', () {
      const info = GeoIpInfo(
        countryCode: 'CH',
        city: 'Zurich',
        subdivision: 'ZH',
        timeZone: 'Europe/Zurich',
        resolvedIp: '209.99.191.16',
      );

      expect(info.tooltipLabel, 'CH / Zurich / 209.99.191.16');
    });
  });

  group('GeoIpService', () {
    test('queries IPWHOIS endpoint when resolving an IP', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'entropy_geo_ip_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final cacheFile = File(
        '${tempDir.path}${Platform.pathSeparator}cache.json',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      final requests = <HttpRequest>[];
      server.listen((request) async {
        requests.add(request);
        final resolvedIp = request.uri.pathSegments.length >= 2
            ? request.uri.pathSegments[1]
            : null;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'success': true,
            'ip': resolvedIp,
            'city': 'Frankfurt am Main',
            'region': 'Hesse',
            'country_code': 'DE',
            'timezone': <String, Object?>{'id': 'Europe/Berlin'},
            'connection': <String, Object?>{'org': 'Example Network'},
          }),
        );
        await request.response.close();
      });

      final httpClient = HttpClient();
      addTearDown(() => httpClient.close(force: true));
      final service = GeoIpService(
        httpClient: httpClient,
        cacheFileProvider: () async => cacheFile,
        ipWhoIsEndpoint: Uri(
          scheme: 'http',
          host: server.address.address,
          port: server.port,
          path: '/geo',
        ),
      );

      final info = await service.resolveServer('8.8.8.8');

      expect(info?.countryCode, 'DE');
      expect(info?.city, 'Frankfurt am Main');
      expect(info?.subdivision, 'Hesse');
      expect(info?.timeZone, 'Europe/Berlin');
      expect(info?.asnOrganization, 'Example Network');
      expect(requests, hasLength(1));
      expect(requests.single.uri.path, '/geo/8.8.8.8');
      expect(requests.single.uri.queryParameters, isEmpty);
      expect(
        requests.single.headers.value(HttpHeaders.acceptHeader),
        'application/json',
      );
    });

    test('uses persisted server cache when resolving a server', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'entropy_geo_ip_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final cacheFile = File(
        '${tempDir.path}${Platform.pathSeparator}cache.json',
      );
      await cacheFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'version': 2,
          'provider': 'ipwho.is',
          'servers': <String, Object?>{
            'vpn.example.com': const GeoIpInfo(
              countryCode: 'CH',
              resolvedIp: '209.99.191.16',
              city: 'Zurich',
            ).toJson(),
          },
        }),
      );

      final service = GeoIpService(cacheFileProvider: () async => cacheFile);

      final info = await service.resolveServer('VPN.EXAMPLE.COM');

      expect(info?.countryCode, 'CH');
      expect(info?.city, 'Zurich');
      expect(info?.resolvedIp, '209.99.191.16');
    });

    test('ignores legacy country lookup cache entries', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'entropy_geo_ip_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final cacheFile = File(
        '${tempDir.path}${Platform.pathSeparator}cache.json',
      );
      await cacheFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'version': 1,
          'servers': <String, Object?>{
            '2.27.11.183': const GeoIpInfo(
              countryCode: 'US',
              resolvedIp: '2.27.11.183',
            ).toJson(),
          },
          'ips': <String, Object?>{
            '2.27.11.183': const GeoIpInfo(
              countryCode: 'US',
              resolvedIp: '2.27.11.183',
            ).toJson(),
          },
        }),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'success': true,
            'city': 'Helsinki',
            'region': 'Uusimaa',
            'country_code': 'FI',
          }),
        );
        await request.response.close();
      });

      final httpClient = HttpClient();
      addTearDown(() => httpClient.close(force: true));
      final service = GeoIpService(
        httpClient: httpClient,
        cacheFileProvider: () async => cacheFile,
        ipWhoIsEndpoint: Uri(
          scheme: 'http',
          host: server.address.address,
          port: server.port,
        ),
      );

      final info = await service.resolveServer('2.27.11.183');

      expect(info?.countryCode, 'FI');
      expect(info?.city, 'Helsinki');
    });
  });

  group('flagEmojiFromCountryCode', () {
    test('returns emoji for valid ISO country code', () {
      expect(flagEmojiFromCountryCode('us'), '🇺🇸');
      expect(flagEmojiFromCountryCode('DE'), '🇩🇪');
    });

    test('returns null for invalid values', () {
      expect(flagEmojiFromCountryCode(null), isNull);
      expect(flagEmojiFromCountryCode(''), isNull);
      expect(flagEmojiFromCountryCode('USA'), isNull);
      expect(flagEmojiFromCountryCode('1a'), isNull);
    });
  });
}
