import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/config_source.dart';
import '../models/dns_settings.dart';
import '../models/split_tunnel.dart';
import '../models/vpn_profile.dart';

class PersistedAppState {
  const PersistedAppState({
    required this.language,
    required this.trafficMode,
    required this.tunIpMode,
    required this.sources,
    required this.selectedSourceId,
    this.dnsSettings = const DnsSettings(),
    this.splitTunnelSettings = const SplitTunnelSettings(),
    this.domainSplitTunnelSettings = const DomainSplitTunnelSettings(),
    this.appUpdateLastCheckedAt,
    this.lastShownAppUpdateTag,
    this.lastShownAndroidAppUpdateTag,
    this.showInAppUpdateNotifications = true,
    this.showAndroidUpdateNotifications = true,
    this.killswitchEnabled = false,
    this.subscriptionDeviceId,
  });

  final AppLanguage language;
  final TrafficMode trafficMode;
  final TunIpMode tunIpMode;
  final List<ConfigSource> sources;
  final String? selectedSourceId;
  final DnsSettings dnsSettings;
  final SplitTunnelSettings splitTunnelSettings;
  final DomainSplitTunnelSettings domainSplitTunnelSettings;
  final DateTime? appUpdateLastCheckedAt;
  final String? lastShownAppUpdateTag;
  final String? lastShownAndroidAppUpdateTag;
  final bool showInAppUpdateNotifications;
  final bool showAndroidUpdateNotifications;
  final bool killswitchEnabled;
  final String? subscriptionDeviceId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'version': 10,
      'language': language.name,
      'trafficMode': trafficMode.name,
      'tunIpMode': tunIpMode.name,
      'selectedSourceId': selectedSourceId,
      'subscription': <String, Object?>{'deviceId': subscriptionDeviceId},
      'dns': dnsSettings.normalized.toJson(),
      'splitTunnel': splitTunnelSettings.normalized.toJson(),
      'domainSplitTunnel': domainSplitTunnelSettings.normalized.toJson(),
      'killswitch': <String, Object?>{'enabled': killswitchEnabled},
      'appUpdate': <String, Object?>{
        'lastCheckedAt': appUpdateLastCheckedAt?.toIso8601String(),
        'lastShownReleaseTag': lastShownAppUpdateTag,
        'lastShownAndroidReleaseTag': lastShownAndroidAppUpdateTag,
        'inAppNotificationsEnabled': showInAppUpdateNotifications,
        'androidNotificationsEnabled': showAndroidUpdateNotifications,
      },
      'sources': sources
          .map((source) => source.toJson())
          .toList(growable: false),
    };
  }

  factory PersistedAppState.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 1;
    final sources = ((json['sources'] as List<dynamic>?) ?? const <dynamic>[])
        .map((item) {
          if (item is Map<String, dynamic>) {
            return ConfigSource.fromJson(item);
          }
          if (item is Map) {
            return ConfigSource.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            );
          }
          return null;
        })
        .whereType<ConfigSource>()
        .toList(growable: false);
    final tunIpMode = _tunIpModeByName(
      json['tunIpMode'] as String?,
      fallback: TunIpMode.ipv4,
    );
    final shouldMigrateAndroidTunIpMode = Platform.isAndroid && version < 4;
    final appUpdate = _stringKeyedMap(json['appUpdate']);
    final subscription = _stringKeyedMap(json['subscription']);
    final killswitch = _stringKeyedMap(json['killswitch']);

    return PersistedAppState(
      language: _appLanguageByName(json['language'] as String?),
      trafficMode: _trafficModeByName(json['trafficMode'] as String?),
      tunIpMode: shouldMigrateAndroidTunIpMode ? TunIpMode.ipv4 : tunIpMode,
      sources: sources,
      selectedSourceId: json['selectedSourceId'] as String?,
      dnsSettings: DnsSettings.fromJson(
        (json['dns'] as Map?)?.cast<String, dynamic>(),
      ),
      splitTunnelSettings: SplitTunnelSettings.fromJson(
        (json['splitTunnel'] as Map?)?.cast<String, dynamic>(),
      ),
      domainSplitTunnelSettings: DomainSplitTunnelSettings.fromJson(
        (json['domainSplitTunnel'] as Map?)?.cast<String, dynamic>(),
      ),
      appUpdateLastCheckedAt: _parseDateTime(
        appUpdate?['lastCheckedAt'] as String?,
      ),
      lastShownAppUpdateTag: _parseOptionalString(
        appUpdate?['lastShownReleaseTag'],
      ),
      lastShownAndroidAppUpdateTag: _parseOptionalString(
        appUpdate?['lastShownAndroidReleaseTag'],
      ),
      showInAppUpdateNotifications: _parseBool(
        appUpdate?['inAppNotificationsEnabled'],
        fallback: true,
      ),
      showAndroidUpdateNotifications: _parseBool(
        appUpdate?['androidNotificationsEnabled'],
        fallback: true,
      ),
      killswitchEnabled: _parseBool(killswitch?['enabled'], fallback: false),
      subscriptionDeviceId: _parseOptionalString(
        subscription?['deviceId'] ?? json['subscriptionDeviceId'],
      ),
    );
  }
}

class AppStateStore {
  AppStateStore({File? stateFile}) : _overrideStateFile = stateFile;

  static const MethodChannel _androidControlChannel = MethodChannel(
    'entropy_vpn/control',
  );
  static const String _tempStateFileSuffix = '.tmp';
  static const String _backupStateFileSuffix = '.bak';

  final File? _overrideStateFile;
  Future<void> _pendingSave = Future<void>.value();

  Future<PersistedAppState?> load() async {
    final file = await _stateFile();
    final primary = await _loadStateFile(file);
    final tempFile = _tempStateFile(file);
    final temp = await _loadStateFile(tempFile);

    if (primary.state != null) {
      final tempIsNewer =
          temp.state != null &&
          temp.modifiedAt != null &&
          primary.modifiedAt != null &&
          temp.modifiedAt!.isAfter(primary.modifiedAt!);
      if (tempIsNewer) {
        await _promoteRecoveredState(file, temp.state!);
        return temp.state;
      }
      return primary.state;
    }

    final backup = await _loadStateFile(_backupStateFile(file));
    final recovered = temp.state ?? backup.state;
    if (recovered == null) {
      return null;
    }

    await _promoteRecoveredState(file, recovered);
    return recovered;
  }

  Future<void> save(PersistedAppState state) async {
    final write = _pendingSave
        .catchError((Object _) {})
        .then((_) => _writeState(state));
    _pendingSave = write;
    await write;
  }

  Future<void> _writeState(PersistedAppState state) async {
    final file = await _stateFile();
    await _writeStateFile(file, state);
  }

  Future<void> _writeStateFile(File file, PersistedAppState state) async {
    await file.parent.create(recursive: true);
    final json = const JsonEncoder.withIndent('  ').convert(state.toJson());
    final tempFile = _tempStateFile(file);
    final backupFile = _backupStateFile(file);

    await tempFile.writeAsString(json, flush: true);

    if (await file.exists()) {
      await file.copy(backupFile.path);
    }

    try {
      await tempFile.rename(file.path);
    } on FileSystemException {
      await tempFile.copy(file.path);
      await _deleteIfExists(tempFile);
    }

    await _deleteIfExists(backupFile);
  }

  Future<_LoadedAppState> _loadStateFile(File file) async {
    if (!await file.exists()) {
      return const _LoadedAppState();
    }

    try {
      final modifiedAt = await file.lastModified();
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const _LoadedAppState();
      }

      final decoded = jsonDecode(raw);
      final stateJson = _stringKeyedMap(decoded);
      if (stateJson == null) {
        return const _LoadedAppState();
      }

      return _LoadedAppState(
        state: PersistedAppState.fromJson(stateJson),
        modifiedAt: modifiedAt,
      );
    } on FormatException {
      return const _LoadedAppState();
    } on FileSystemException {
      return const _LoadedAppState();
    } on TypeError {
      return const _LoadedAppState();
    }
  }

  Future<void> _promoteRecoveredState(
    File file,
    PersistedAppState state,
  ) async {
    try {
      await _writeStateFile(file, state);
    } on FileSystemException {}
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {}
  }

  Future<File> _stateFile() async {
    final override = _overrideStateFile;
    if (override != null) {
      return override;
    }

    if (Platform.isAndroid) {
      final appDataDirectory = await _androidControlChannel
          .invokeMethod<String>('getAppDataDirectory');
      if (appDataDirectory != null && appDataDirectory.trim().isNotEmpty) {
        return File(p.join(appDataDirectory, 'app_state.json'));
      }
    }

    final localAppData =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.current.path;
    return File(p.join(localAppData, 'EntropyVPN', 'app_state.json'));
  }

  File _tempStateFile(File file) {
    return File('${file.path}$_tempStateFileSuffix');
  }

  File _backupStateFile(File file) {
    return File('${file.path}$_backupStateFileSuffix');
  }

  Map<String, dynamic>? _stringKeyedMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }
}

class _LoadedAppState {
  const _LoadedAppState({this.state, this.modifiedAt});

  final PersistedAppState? state;
  final DateTime? modifiedAt;
}

AppLanguage _appLanguageByName(String? name) {
  if (name == AppLanguage.ru.name) {
    return AppLanguage.ru;
  }
  return AppLanguage.en;
}

TrafficMode _trafficModeByName(String? name) {
  if (name == TrafficMode.tun.name) {
    return TrafficMode.tun;
  }
  return TrafficMode.systemProxy;
}

TunIpMode _tunIpModeByName(
  String? name, {
  TunIpMode fallback = TunIpMode.ipv4,
}) {
  for (final mode in TunIpMode.values) {
    if (mode.name == name) {
      return mode;
    }
  }
  return fallback;
}

DateTime? _parseDateTime(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}

Map<String, dynamic>? _stringKeyedMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

String? _parseOptionalString(Object? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.toString().trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _parseBool(Object? value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  return fallback;
}
