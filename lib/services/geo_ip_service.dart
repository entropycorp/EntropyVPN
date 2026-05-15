import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class GeoIpInfo {
  const GeoIpInfo({
    required this.countryCode,
    required this.resolvedIp,
    this.city,
    this.subdivision,
    this.timeZone,
    this.asnOrganization,
  });

  final String countryCode;
  final String resolvedIp;
  final String? city;
  final String? subdivision;
  final String? timeZone;
  final String? asnOrganization;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'countryCode': countryCode,
      'resolvedIp': resolvedIp,
      'city': city,
      'subdivision': subdivision,
      'timeZone': timeZone,
      'asnOrganization': asnOrganization,
    };
  }

  static GeoIpInfo? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final countryCode = _normalizeCountryCode(value['countryCode']);
    final resolvedIp = _readCacheText(value['resolvedIp']);
    if (countryCode == null || resolvedIp == null) {
      return null;
    }

    return GeoIpInfo(
      countryCode: countryCode,
      resolvedIp: resolvedIp,
      city: _readCacheText(value['city']),
      subdivision: _readCacheText(value['subdivision']),
      timeZone: _readCacheText(value['timeZone']),
      asnOrganization: _readCacheText(value['asnOrganization']),
    );
  }

  String get tooltipLabel {
    final parts = <String>[countryCode];
    if (city != null && city!.isNotEmpty) {
      parts.add(city!);
    }
    parts.add(resolvedIp);
    return parts.join(' / ');
  }
}

class GeoIpService {
  GeoIpService({
    HttpClient? httpClient,
    Future<File> Function()? cacheFileProvider,
    Uri? ipWhoIsEndpoint,
  }) : _httpClient = httpClient ?? HttpClient(),
       _cacheFileProvider = cacheFileProvider ?? _defaultCacheFile,
       _ipWhoIsEndpoint = ipWhoIsEndpoint ?? _defaultIpWhoIsEndpoint;

  static const MethodChannel _androidControlChannel = MethodChannel(
    'entropy_vpn/control',
  );
  /// Process-wide instance. Production code must use this so a single
  /// in-memory cache and a single file writer back the whole app.
  static final GeoIpService shared = GeoIpService();

  static final Uri _defaultIpWhoIsEndpoint = Uri.https('ipwho.is', '/');
  static const int _cacheVersion = 2;
  static const String _cacheProvider = 'ipwho.is';
  static const Duration _saveDebounce = Duration(milliseconds: 750);

  final HttpClient _httpClient;
  final Future<File> Function() _cacheFileProvider;
  final Uri _ipWhoIsEndpoint;
  final Map<String, GeoIpInfo> _serverCache = <String, GeoIpInfo>{};
  final Map<String, GeoIpInfo> _ipCache = <String, GeoIpInfo>{};
  final Map<String, Future<GeoIpInfo?>> _pendingServerLookups =
      <String, Future<GeoIpInfo?>>{};
  final Map<String, Future<GeoIpInfo?>> _pendingIpLookups =
      <String, Future<GeoIpInfo?>>{};
  Future<void>? _persistentCacheLoad;
  Timer? _saveTimer;
  Future<void>? _activeSave;
  bool _cacheDirty = false;

  Future<GeoIpInfo?> resolveServer(String server) {
    final normalizedServer = server.trim();
    if (normalizedServer.isEmpty) {
      return Future<GeoIpInfo?>.value();
    }

    final cacheKey = _serverCacheKey(normalizedServer);
    final cached = _serverCache[cacheKey];
    if (cached != null) {
      return Future<GeoIpInfo?>.value(cached);
    }

    final pending = _pendingServerLookups[cacheKey];
    if (pending != null) {
      return pending;
    }

    final lookup = _resolveServerInternal(normalizedServer, cacheKey);
    _pendingServerLookups[cacheKey] = lookup;
    return lookup.whenComplete(() {
      _pendingServerLookups.remove(cacheKey);
    });
  }

  Future<GeoIpInfo?> _resolveServerInternal(
    String server,
    String cacheKey,
  ) async {
    await _ensurePersistentCacheLoaded();
    final cached = _serverCache[cacheKey];
    if (cached != null) {
      return cached;
    }

    final resolvedIp = await _resolvePublicIp(server);
    if (resolvedIp == null) {
      return _serverCache[cacheKey];
    }

    final info = await _resolveIp(resolvedIp);
    if (info == null) {
      return _serverCache[cacheKey];
    }

    _rememberServerInfo(cacheKey, info);
    return info;
  }

  Future<String?> _resolvePublicIp(String server) async {
    final parsed = InternetAddress.tryParse(server);
    if (parsed != null) {
      return _isPublicAddress(parsed) ? parsed.address : null;
    }

    try {
      final addresses = await InternetAddress.lookup(
        server,
        type: InternetAddressType.any,
      ).timeout(const Duration(seconds: 4));

      for (final address in addresses) {
        if (_isPublicAddress(address)) {
          return address.address;
        }
      }
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }

    return null;
  }

  Future<GeoIpInfo?> _resolveIp(String ipAddress) {
    final cached = _ipCache[ipAddress];
    if (cached != null) {
      return Future<GeoIpInfo?>.value(cached);
    }

    final pending = _pendingIpLookups[ipAddress];
    if (pending != null) {
      return pending;
    }

    final lookup = _resolveIpInternal(ipAddress);
    _pendingIpLookups[ipAddress] = lookup;
    return lookup.whenComplete(() {
      _pendingIpLookups.remove(ipAddress);
    });
  }

  Future<GeoIpInfo?> _resolveIpInternal(String ipAddress) async {
    await _ensurePersistentCacheLoaded();
    final cached = _ipCache[ipAddress];
    if (cached != null) {
      return cached;
    }

    try {
      final request = await _httpClient
          .getUrl(_buildIpWhoIsUri(ipAddress))
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'EntropyVPN/1.6.0');

      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }

      final payload = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      if (decoded['success'] == false) {
        return null;
      }

      final geo = decoded['geo'];
      final asInfo = decoded['as'];
      final asnInfo = decoded['asn'];
      final timeZoneInfo = decoded['timezone'];
      final connectionInfo = decoded['connection'];
      final countryCode = _normalizeCountryCode(
        _readText(decoded['country_code']) ??
            _readNestedText(geo, 'country_code') ??
            _readText(decoded['country']),
      );
      if (countryCode == null) {
        return null;
      }

      final info = GeoIpInfo(
        countryCode: countryCode,
        resolvedIp: _readText(decoded['ip']) ?? ipAddress,
        city:
            _readText(decoded['city']) ??
            _readNestedText(geo, 'city') ??
            _readText(decoded['city_name']) ??
            _readNestedText(decoded['city'], 'name'),
        subdivision:
            _readText(decoded['region']) ??
            _readNestedText(geo, 'region') ??
            _readText(decoded['region_name']) ??
            _readNestedText(decoded['region'], 'name'),
        timeZone:
            _readNestedText(timeZoneInfo, 'id') ??
            _readNestedText(geo, 'timezone') ??
            _readText(decoded['timezone']) ??
            _readText(decoded['time_zone']),
        asnOrganization:
            _readNestedText(connectionInfo, 'org') ??
            _readNestedText(connectionInfo, 'isp') ??
            _readNestedText(asnInfo, 'name') ??
            _readNestedText(asInfo, 'name') ??
            _readText(decoded['as_name']) ??
            _readText(decoded['org']) ??
            _readText(decoded['as']) ??
            _readText(decoded['isp']),
      );
      _rememberIpInfo(ipAddress, info);
      return info;
    } on HandshakeException {
      return null;
    } on HttpException {
      return null;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Uri _buildIpWhoIsUri(String ipAddress) {
    final queryParameters = <String, String>{
      ..._ipWhoIsEndpoint.queryParameters,
    };

    return _ipWhoIsEndpoint.replace(
      pathSegments: <String>[
        ..._ipWhoIsEndpoint.pathSegments.where((segment) => segment.isNotEmpty),
        ipAddress,
      ],
      queryParameters: queryParameters,
    );
  }

  void _rememberServerInfo(String cacheKey, GeoIpInfo info) {
    _serverCache[cacheKey] = info;
    _ipCache[info.resolvedIp] = info;
    _scheduleSave();
  }

  void _rememberIpInfo(String ipAddress, GeoIpInfo info) {
    _ipCache[ipAddress] = info;
    _scheduleSave();
  }

  /// Coalesces a burst of cache updates into a single delayed disk write.
  void _scheduleSave() {
    _cacheDirty = true;
    _saveTimer ??= Timer(_saveDebounce, _runSave);
  }

  /// Runs the persistent write, ensuring only one write is in flight at a
  /// time. If more entries land mid-write, a follow-up write is scheduled.
  void _runSave() {
    _saveTimer = null;
    if (_activeSave != null || !_cacheDirty) {
      return;
    }
    _cacheDirty = false;
    _activeSave = _savePersistentCache().whenComplete(() {
      _activeSave = null;
      if (_cacheDirty) {
        _runSave();
      }
    });
  }

  /// Flushes any pending cache write to disk and waits for it to finish.
  Future<void> dispose() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _runSave();
    while (_activeSave != null) {
      await _activeSave;
    }
  }

  Future<void> _ensurePersistentCacheLoaded() {
    return _persistentCacheLoad ??= _loadPersistentCache();
  }

  Future<void> _loadPersistentCache() async {
    try {
      final file = await _cacheFileProvider();
      if (!await file.exists()) {
        return;
      }

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      if (!_isCurrentCache(decoded)) {
        return;
      }

      for (final entry in _readInfoMap(decoded['servers']).entries) {
        _serverCache.putIfAbsent(entry.key, () => entry.value);
      }
      for (final entry in _readInfoMap(decoded['ips']).entries) {
        _ipCache.putIfAbsent(entry.key, () => entry.value);
      }
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  Future<void> _savePersistentCache() async {
    try {
      final file = await _cacheFileProvider();
      await file.parent.create(recursive: true);

      // The in-memory caches are authoritative: they are seeded from disk on
      // load and only ever grow, so they can be written out wholesale without
      // re-reading and merging the file on every save.
      final payload = <String, Object?>{
        'version': _cacheVersion,
        'provider': _cacheProvider,
        'servers': _serverCache.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        'ips': _ipCache.map((key, value) => MapEntry(key, value.toJson())),
      };
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  static Map<String, GeoIpInfo> _readInfoMap(Object? value) {
    if (value is! Map) {
      return <String, GeoIpInfo>{};
    }

    final result = <String, GeoIpInfo>{};
    for (final entry in value.entries) {
      final key = entry.key?.toString().trim();
      final info = GeoIpInfo.fromJson(entry.value);
      if (key != null && key.isNotEmpty && info != null) {
        result[key] = info;
      }
    }
    return result;
  }

  static bool _isCurrentCache(Map<Object?, Object?> decoded) {
    return decoded['version'] == _cacheVersion &&
        decoded['provider'] == _cacheProvider;
  }

  static Future<File> _defaultCacheFile() async {
    if (Platform.isAndroid) {
      final appDataDirectory = await _androidControlChannel
          .invokeMethod<String>('getAppDataDirectory');
      if (appDataDirectory != null && appDataDirectory.trim().isNotEmpty) {
        return File(p.join(appDataDirectory, 'geo_ip_cache.json'));
      }
    }

    final localAppData =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.current.path;
    return File(p.join(localAppData, 'EntropyVPN', 'geo_ip_cache.json'));
  }

  static String _serverCacheKey(String server) => server.trim().toLowerCase();

  bool _isPublicAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }

    if (address.type == InternetAddressType.IPv4) {
      return !_isPrivateIpv4(address.rawAddress);
    }

    return !_isPrivateIpv6(address.rawAddress);
  }

  bool _isPrivateIpv4(List<int> bytes) {
    if (bytes.length != 4) {
      return true;
    }

    if (bytes[0] == 10 || bytes[0] == 127) {
      return true;
    }
    if (bytes[0] == 169 && bytes[1] == 254) {
      return true;
    }
    if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) {
      return true;
    }
    if (bytes[0] == 192 && bytes[1] == 168) {
      return true;
    }
    if (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) {
      return true;
    }
    if (bytes[0] >= 224) {
      return true;
    }

    return false;
  }

  bool _isPrivateIpv6(List<int> bytes) {
    if (bytes.length != 16) {
      return true;
    }

    final first = bytes[0];
    final second = bytes[1];

    if (first == 0 && second == 0) {
      return true;
    }
    if (first == 0xfc || first == 0xfd) {
      return true;
    }
    if (first == 0xfe && (second & 0xc0) == 0x80) {
      return true;
    }
    if (first == 0xff) {
      return true;
    }

    return false;
  }

  String? _readNestedText(Object? value, Object key) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    return _readText(value[key]);
  }

  String? _readText(Object? value) {
    if (value is Map || value is Iterable) {
      return null;
    }
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }
}

String? flagEmojiFromCountryCode(String? countryCode) {
  final code = _normalizeCountryCode(countryCode);
  if (code == null) {
    return null;
  }

  final first = String.fromCharCode(code.codeUnitAt(0) + 127397);
  final second = String.fromCharCode(code.codeUnitAt(1) + 127397);
  return '$first$second';
}

String? _normalizeCountryCode(String? countryCode) {
  final code = countryCode?.trim().toUpperCase();
  if (code == null || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
    return null;
  }
  return code;
}

String? _readCacheText(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text;
}
