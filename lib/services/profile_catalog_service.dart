import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../models/config_source.dart';
import '../models/vpn_profile.dart';
import 'config_source_export.dart';
import 'share_link_parser.dart';

part 'profile_catalog_native_config.dart';
part 'profile_catalog_payload_resolver.dart';
part 'profile_catalog_subscription_headers.dart';

const String _subscriptionUserAgent = 'EntropyVPN/1.7.0';

class ResolvedProfileCatalog {
  ResolvedProfileCatalog({
    required List<ParsedVpnProfile> profiles,
    required this.isSubscription,
    this.trafficUsage,
    this.sourceRawInput,
    this.sourceName,
  }) : profiles = List<ParsedVpnProfile>.unmodifiable(profiles);

  final List<ParsedVpnProfile> profiles;
  final bool isSubscription;
  final SubscriptionTrafficUsage? trafficUsage;
  final String? sourceRawInput;
  final String? sourceName;
}

class ProfileCatalogService {
  ProfileCatalogService({
    ShareLinkParser? parser,
    HttpClient Function()? httpClientFactory,
  }) : _parser = parser ?? ShareLinkParser(),
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  String? subscriptionDeviceId;

  final ShareLinkParser _parser;
  final HttpClient Function() _httpClientFactory;
  late final _SubscriptionPayloadResolver _payloadResolver =
      _SubscriptionPayloadResolver(_parser);

  bool looksLikeRemoteSubscription(String rawInput) {
    final line = _primaryLine(rawInput);
    if (line.isEmpty) {
      return false;
    }

    final uri = Uri.tryParse(line);
    if (uri == null || uri.host.isEmpty) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  Future<ResolvedProfileCatalog> resolve(String rawInput) async {
    final singBoxRemoteProfile = _parseSingBoxRemoteProfileImportLink(rawInput);
    if (singBoxRemoteProfile != null) {
      return _resolveRemoteSubscription(
        singBoxRemoteProfile.url,
        sourceLabel: singBoxRemoteProfile.name,
        fallbackSourceLabel: singBoxRemoteProfile.host,
      );
    }

    if (looksLikeRemoteSubscription(rawInput)) {
      return _resolveRemoteSubscription(_primaryLine(rawInput));
    }
    final localFile = _resolveLocalConfigFile(rawInput);
    if (localFile != null) {
      final payload = await localFile.readAsString();
      final exportedSource = ConfigSourceExport.tryParse(payload);
      if (exportedSource != null) {
        return _catalogFromExportedSource(exportedSource);
      }
      final profile = _tryParseCoreConfig(
        payload,
        sourceLabel: p.basename(localFile.path),
        configDirectory: localFile.parent.path,
      );
      if (profile != null) {
        return ResolvedProfileCatalog(
          profiles: <ParsedVpnProfile>[profile],
          isSubscription: false,
        );
      }
    }
    return resolveInline(rawInput);
  }

  ResolvedProfileCatalog resolveInline(String rawInput) {
    return _payloadResolver.resolveInline(rawInput);
  }

  Future<ResolvedProfileCatalog> _resolveRemoteSubscription(
    String url, {
    String? sourceLabel,
    String? fallbackSourceLabel,
  }) async {
    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 15);
    client.userAgent = _subscriptionUserAgent;

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, _subscriptionUserAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/plain, application/octet-stream, */*',
      );
      _setSubscriptionDeviceHeaders(request.headers);

      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Subscription request failed with status ${response.statusCode}.',
        );
      }

      final bodyBytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) {
          builder.add(chunk);
          return builder;
        },
      );
      final body = _decodeResponseBody(bodyBytes.takeBytes());
      final trafficUsage = _parseSubscriptionTrafficUsage(
        _subscriptionTrafficUsageHeader(response.headers),
      );
      final remoteSourceLabel =
          _nonEmpty(sourceLabel) ?? _profileTitleHeader(response.headers);
      final resolved = _payloadResolver.resolveSubscriptionPayload(
        body,
        isRemote: true,
        sourceLabel: remoteSourceLabel,
        fallbackSourceLabel:
            _nonEmpty(fallbackSourceLabel) ??
            _remoteUrlFragmentLabel(url) ??
            _remoteUrlPathLabel(url),
        trafficUsage: trafficUsage,
      );
      if (resolved != null) {
        return resolved;
      }

      throw const FormatException(
        'No supported links were found in the subscription.',
      );
    } on TimeoutException {
      throw StateError('Subscription request timed out.');
    } on SocketException catch (error) {
      throw StateError('Subscription request failed: ${error.message}');
    } on HttpException catch (error) {
      throw StateError('Subscription request failed: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  void _setSubscriptionDeviceHeaders(HttpHeaders headers) {
    final deviceId = _nonEmpty(subscriptionDeviceId);
    if (deviceId == null) {
      return;
    }

    headers
      ..set('x-hwid', _headerSafeValue(deviceId))
      ..set('x-device-os', _subscriptionDeviceOs())
      ..set('x-ver-os', _headerSafeValue(Platform.operatingSystemVersion))
      ..set('x-device-model', _subscriptionDeviceModel());
  }

  String _subscriptionDeviceOs() {
    return switch (Platform.operatingSystem.toLowerCase()) {
      'windows' => 'Windows',
      'android' => 'Android',
      'ios' => 'iOS',
      'macos' => 'macOS',
      'linux' => 'Linux',
      _ => Platform.operatingSystem,
    };
  }

  String _subscriptionDeviceModel() {
    if (Platform.isWindows) {
      return 'Desktop';
    }
    if (Platform.isAndroid) {
      return 'Android Device';
    }
    return _headerSafeValue(Platform.operatingSystem);
  }

  String _headerSafeValue(String value) {
    return value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  }
}

String? _nonEmpty(String? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
