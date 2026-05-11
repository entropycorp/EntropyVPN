import 'vpn_profile.dart';

enum ConfigSourceKind { config, subscription }

const int defaultSubscriptionAutoUpdateMinutes = 60;
const int minSubscriptionAutoUpdateMinutes = 15;
const int maxSubscriptionAutoUpdateMinutes = 24 * 60;
const int subscriptionAutoUpdateStepMinutes = 15;

class SubscriptionTrafficUsage {
  const SubscriptionTrafficUsage({
    required this.uploadBytes,
    required this.downloadBytes,
    this.totalBytes,
    this.expiresAt,
  });

  final int uploadBytes;
  final int downloadBytes;
  final int? totalBytes;
  final DateTime? expiresAt;

  int get usedBytes => uploadBytes + downloadBytes;
  bool get hasTotal => totalBytes != null && totalBytes! > 0;

  double? get usageRatio {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    final ratio = usedBytes / total;
    if (ratio < 0) {
      return 0;
    }
    if (ratio > 1) {
      return 1;
    }
    return ratio;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'uploadBytes': uploadBytes,
      'downloadBytes': downloadBytes,
      'totalBytes': totalBytes,
      'expiresAt': expiresAt?.toIso8601String(),
    };
  }

  factory SubscriptionTrafficUsage.fromJson(Map<String, dynamic> json) {
    return SubscriptionTrafficUsage(
      uploadBytes: _parseTrafficBytes(json['uploadBytes']),
      downloadBytes: _parseTrafficBytes(json['downloadBytes']),
      totalBytes: _parseOptionalTrafficBytes(json['totalBytes']),
      expiresAt: _parseDateTime(json['expiresAt'] as String?),
    );
  }
}

class ConfigSource {
  const ConfigSource({
    required this.id,
    required this.rawInput,
    required this.kind,
    this.displayName,
    this.profiles = const <ParsedVpnProfile>[],
    this.selectedProfileIndex = 0,
    this.isUpdating = false,
    this.isPinging = false,
    this.lastUpdatedAt,
    this.lastUpdateError,
    this.autoUpdateIntervalMinutes = defaultSubscriptionAutoUpdateMinutes,
    this.trafficUsage,
    this.tcpPingLatenciesMs = const <int, int>{},
    this.tcpPingLatencyMs,
    this.tcpPingProfileIndex,
  });

  final String id;
  final String rawInput;
  final ConfigSourceKind kind;
  final String? displayName;
  final List<ParsedVpnProfile> profiles;
  final int selectedProfileIndex;
  final bool isUpdating;
  final bool isPinging;
  final DateTime? lastUpdatedAt;
  final String? lastUpdateError;
  final int autoUpdateIntervalMinutes;
  final SubscriptionTrafficUsage? trafficUsage;
  final Map<int, int> tcpPingLatenciesMs;
  final int? tcpPingLatencyMs;
  final int? tcpPingProfileIndex;

  bool get isSubscription => kind == ConfigSourceKind.subscription;
  bool get hasMultipleProfiles => profiles.length > 1;
  bool get hasProfiles => profiles.isNotEmpty;
  int get normalizedAutoUpdateIntervalMinutes =>
      normalizeSubscriptionAutoUpdateMinutes(autoUpdateIntervalMinutes);
  Duration get autoUpdateInterval =>
      Duration(minutes: normalizedAutoUpdateIntervalMinutes);

  ParsedVpnProfile? get selectedProfile {
    if (profiles.isEmpty) {
      return null;
    }

    final safeIndex = selectedProfileIndex.clamp(0, profiles.length - 1);
    return profiles[safeIndex];
  }

  int? tcpPingLatencyForProfile(int profileIndex) {
    return tcpPingLatenciesMs[profileIndex] ??
        (tcpPingProfileIndex == profileIndex ? tcpPingLatencyMs : null);
  }

  ConfigSource copyWith({
    String? id,
    String? rawInput,
    ConfigSourceKind? kind,
    String? displayName,
    bool clearDisplayName = false,
    List<ParsedVpnProfile>? profiles,
    int? selectedProfileIndex,
    bool? isUpdating,
    bool? isPinging,
    DateTime? lastUpdatedAt,
    bool clearLastUpdatedAt = false,
    String? lastUpdateError,
    bool clearLastUpdateError = false,
    int? autoUpdateIntervalMinutes,
    SubscriptionTrafficUsage? trafficUsage,
    bool clearTrafficUsage = false,
    Map<int, int>? tcpPingLatenciesMs,
    bool clearTcpPingLatencies = false,
    int? tcpPingLatencyMs,
    bool clearTcpPingLatency = false,
    int? tcpPingProfileIndex,
    bool clearTcpPingProfileIndex = false,
    bool clearTcpPing = false,
  }) {
    final nextProfiles = profiles ?? this.profiles;
    final nextIndex = nextProfiles.isEmpty
        ? 0
        : (selectedProfileIndex ?? this.selectedProfileIndex).clamp(
            0,
            nextProfiles.length - 1,
          );

    return ConfigSource(
      id: id ?? this.id,
      rawInput: rawInput ?? this.rawInput,
      kind: kind ?? this.kind,
      displayName: clearDisplayName ? null : (displayName ?? this.displayName),
      profiles: nextProfiles,
      selectedProfileIndex: nextIndex,
      isUpdating: isUpdating ?? this.isUpdating,
      isPinging: clearTcpPing ? false : (isPinging ?? this.isPinging),
      lastUpdatedAt: clearLastUpdatedAt
          ? null
          : (lastUpdatedAt ?? this.lastUpdatedAt),
      lastUpdateError: clearLastUpdateError
          ? null
          : (lastUpdateError ?? this.lastUpdateError),
      autoUpdateIntervalMinutes: normalizeSubscriptionAutoUpdateMinutes(
        autoUpdateIntervalMinutes ?? this.autoUpdateIntervalMinutes,
      ),
      trafficUsage: clearTrafficUsage
          ? null
          : (trafficUsage ?? this.trafficUsage),
      tcpPingLatenciesMs: clearTcpPing || clearTcpPingLatencies
          ? const <int, int>{}
          : (tcpPingLatenciesMs ?? this.tcpPingLatenciesMs),
      tcpPingLatencyMs: clearTcpPing || clearTcpPingLatency
          ? null
          : (tcpPingLatencyMs ?? this.tcpPingLatencyMs),
      tcpPingProfileIndex: clearTcpPing || clearTcpPingProfileIndex
          ? null
          : (tcpPingProfileIndex ?? this.tcpPingProfileIndex),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'rawInput': rawInput,
      'kind': kind.name,
      'displayName': _parseOptionalString(displayName),
      'profiles': profiles
          .map((profile) => profile.toJson())
          .toList(growable: false),
      'selectedProfileIndex': selectedProfileIndex,
      'lastUpdatedAt': lastUpdatedAt?.toIso8601String(),
      'lastUpdateError': lastUpdateError,
      'autoUpdateIntervalMinutes': normalizedAutoUpdateIntervalMinutes,
      'trafficUsage': trafficUsage?.toJson(),
    };
  }

  factory ConfigSource.fromJson(Map<String, dynamic> json) {
    final profiles = ((json['profiles'] as List<dynamic>?) ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(ParsedVpnProfile.fromJson)
        .toList(growable: false);

    return ConfigSource(
      id: (json['id'] as String?) ?? '',
      rawInput: (json['rawInput'] as String?) ?? '',
      kind: _configSourceKindByName(json['kind'] as String?),
      displayName: _parseOptionalString(json['displayName']),
      profiles: profiles,
      selectedProfileIndex:
          (json['selectedProfileIndex'] as num?)?.toInt() ?? 0,
      lastUpdatedAt: _parseDateTime(json['lastUpdatedAt'] as String?),
      lastUpdateError: json['lastUpdateError'] as String?,
      autoUpdateIntervalMinutes: _parseAutoUpdateIntervalMinutes(
        json['autoUpdateIntervalMinutes'],
      ),
      trafficUsage: _parseTrafficUsage(json['trafficUsage']),
    );
  }
}

int normalizeSubscriptionAutoUpdateMinutes(int minutes) {
  final clamped = minutes.clamp(
    minSubscriptionAutoUpdateMinutes,
    maxSubscriptionAutoUpdateMinutes,
  );
  final steps =
      ((clamped - minSubscriptionAutoUpdateMinutes) /
              subscriptionAutoUpdateStepMinutes)
          .round();
  return minSubscriptionAutoUpdateMinutes +
      steps * subscriptionAutoUpdateStepMinutes;
}

ConfigSourceKind _configSourceKindByName(String? name) {
  if (name == ConfigSourceKind.subscription.name) {
    return ConfigSourceKind.subscription;
  }
  return ConfigSourceKind.config;
}

DateTime? _parseDateTime(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}

String? _parseOptionalString(Object? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.toString().trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _parseAutoUpdateIntervalMinutes(Object? value) {
  if (value is num) {
    return normalizeSubscriptionAutoUpdateMinutes(value.toInt());
  }
  return defaultSubscriptionAutoUpdateMinutes;
}

SubscriptionTrafficUsage? _parseTrafficUsage(Object? value) {
  if (value is Map<String, dynamic>) {
    return SubscriptionTrafficUsage.fromJson(value);
  }
  if (value is Map) {
    return SubscriptionTrafficUsage.fromJson(
      value.map((key, value) => MapEntry(key.toString(), value)),
    );
  }
  return null;
}

int _parseTrafficBytes(Object? value) {
  if (value is num && value.isFinite && value > 0) {
    return value.toInt();
  }
  return 0;
}

int? _parseOptionalTrafficBytes(Object? value) {
  if (value is num && value.isFinite && value > 0) {
    return value.toInt();
  }
  return null;
}
