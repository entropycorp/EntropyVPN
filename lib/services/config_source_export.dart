import 'dart:convert';

import '../models/config_source.dart';

class ConfigSourceExport {
  static const String format = 'entropyvpn.source';
  static const int version = 1;

  static final JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  const ConfigSourceExport._();

  static String encode(ConfigSource source, {DateTime? exportedAt}) {
    return _encoder.convert(toJson(source, exportedAt: exportedAt));
  }

  static Map<String, Object?> toJson(
    ConfigSource source, {
    DateTime? exportedAt,
  }) {
    return <String, Object?>{
      'format': format,
      'version': version,
      'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
      'source': source.toJson(),
    };
  }

  static ConfigSource? tryParse(String text) {
    final normalizedText = text.trim().replaceFirst('\uFEFF', '');
    if (normalizedText.isEmpty || !normalizedText.startsWith('{')) {
      return null;
    }

    try {
      return fromDecoded(jsonDecode(normalizedText));
    } on FormatException {
      return null;
    }
  }

  static ConfigSource? fromDecoded(Object? decoded) {
    final map = _stringKeyedMap(decoded);
    if (map == null) {
      return null;
    }

    final Object? sourceValue;
    if (map['format'] == format) {
      sourceValue = map['source'];
    } else if (_looksLikeSourceJson(map)) {
      sourceValue = map;
    } else {
      return null;
    }

    final sourceJson = _stringKeyedMap(sourceValue);
    if (sourceJson == null) {
      return null;
    }

    final source = ConfigSource.fromJson(sourceJson);
    return source.hasProfiles ? source : null;
  }

  static bool _looksLikeSourceJson(Map<String, dynamic> json) {
    return json['profiles'] is List &&
        json.containsKey('rawInput') &&
        json.containsKey('kind');
  }

  static Map<String, dynamic>? _stringKeyedMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }
}
