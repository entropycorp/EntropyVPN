import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

const Duration appUpdateCheckInterval = Duration(hours: 1);
const String appUpdateReleasesPageUrl =
    'https://github.com/entropycorp/EntropyVPN/releases';

final Uri appUpdateLatestReleaseApiUri = Uri.https(
  'api.github.com',
  '/repos/entropycorp/EntropyVPN/releases/latest',
);

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tagName,
    required this.version,
    required this.title,
    required this.releaseUrl,
    this.currentVersion,
    this.publishedAt,
  });

  final String tagName;
  final AppVersion version;
  final String title;
  final Uri releaseUrl;
  final String? currentVersion;
  final DateTime? publishedAt;

  String get versionLabel => version.toString();

  AppUpdateInfo copyWith({
    String? tagName,
    AppVersion? version,
    String? title,
    Uri? releaseUrl,
    String? currentVersion,
    DateTime? publishedAt,
  }) {
    return AppUpdateInfo(
      tagName: tagName ?? this.tagName,
      version: version ?? this.version,
      title: title ?? this.title,
      releaseUrl: releaseUrl ?? this.releaseUrl,
      currentVersion: currentVersion ?? this.currentVersion,
      publishedAt: publishedAt ?? this.publishedAt,
    );
  }
}

class AppVersion implements Comparable<AppVersion> {
  AppVersion._(List<int> releaseSegments, List<String> preReleaseSegments)
    : releaseSegments = List<int>.unmodifiable(releaseSegments),
      preReleaseSegments = List<String>.unmodifiable(preReleaseSegments);

  final List<int> releaseSegments;
  final List<String> preReleaseSegments;

  static AppVersion? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final withoutPrefix = trimmed.replaceFirst(RegExp(r'^[vV]'), '');
    final direct = _parseCandidate(withoutPrefix);
    if (direct != null) {
      return direct;
    }

    final match = RegExp(
      r'(\d+(?:\.\d+)*(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)',
    ).firstMatch(trimmed);
    if (match == null) {
      return null;
    }
    return _parseCandidate(match.group(1)!);
  }

  static AppVersion? _parseCandidate(String candidate) {
    final match = RegExp(
      r'^(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(candidate.trim());
    if (match == null) {
      return null;
    }

    final release = <int>[];
    for (final part in match.group(1)!.split('.')) {
      final value = int.tryParse(part);
      if (value == null) {
        return null;
      }
      release.add(value);
    }

    final preRelease = match
        .group(2)
        ?.split('.')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    return AppVersion._(release, preRelease ?? const <String>[]);
  }

  @override
  int compareTo(AppVersion other) {
    final length = releaseSegments.length > other.releaseSegments.length
        ? releaseSegments.length
        : other.releaseSegments.length;
    final releaseLength = length < 3 ? 3 : length;
    for (var index = 0; index < releaseLength; index += 1) {
      final left = index < releaseSegments.length ? releaseSegments[index] : 0;
      final right = index < other.releaseSegments.length
          ? other.releaseSegments[index]
          : 0;
      if (left != right) {
        return left.compareTo(right);
      }
    }

    if (preReleaseSegments.isEmpty && other.preReleaseSegments.isEmpty) {
      return 0;
    }
    if (preReleaseSegments.isEmpty) {
      return 1;
    }
    if (other.preReleaseSegments.isEmpty) {
      return -1;
    }

    final preReleaseLength =
        preReleaseSegments.length > other.preReleaseSegments.length
        ? preReleaseSegments.length
        : other.preReleaseSegments.length;
    for (var index = 0; index < preReleaseLength; index += 1) {
      if (index >= preReleaseSegments.length) {
        return -1;
      }
      if (index >= other.preReleaseSegments.length) {
        return 1;
      }
      final result = _comparePreReleaseIdentifier(
        preReleaseSegments[index],
        other.preReleaseSegments[index],
      );
      if (result != 0) {
        return result;
      }
    }
    return 0;
  }

  int _comparePreReleaseIdentifier(String left, String right) {
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    if (leftNumber != null && rightNumber != null) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null) {
      return -1;
    }
    if (rightNumber != null) {
      return 1;
    }
    return left.compareTo(right);
  }

  @override
  String toString() {
    final release = releaseSegments.join('.');
    if (preReleaseSegments.isEmpty) {
      return release;
    }
    return '$release-${preReleaseSegments.join('.')}';
  }
}

class AppUpdateService {
  AppUpdateService({
    HttpClient? httpClient,
    Uri? latestReleaseApiUri,
    Duration requestTimeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient,
       _latestReleaseApiUri =
           latestReleaseApiUri ?? appUpdateLatestReleaseApiUri,
       _requestTimeout = requestTimeout;

  final HttpClient? _httpClient;
  final Uri _latestReleaseApiUri;
  final Duration _requestTimeout;

  Future<AppUpdateInfo?> checkForUpdate({String? currentVersion}) async {
    final effectiveCurrentVersion =
        currentVersion ?? await loadCurrentVersion();
    final current = effectiveCurrentVersion == null
        ? null
        : AppVersion.tryParse(effectiveCurrentVersion);
    if (current == null) {
      return null;
    }

    final latest = await fetchLatestRelease(
      currentVersion: effectiveCurrentVersion,
    );
    if (latest.version.compareTo(current) <= 0) {
      return null;
    }
    return latest;
  }

  Future<AppUpdateInfo> fetchLatestRelease({String? currentVersion}) async {
    final client = _httpClient ?? HttpClient();
    try {
      final request = await client
          .getUrl(_latestReleaseApiUri)
          .timeout(_requestTimeout);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'EntropyVPN update checker',
      );
      final response = await request.close().timeout(_requestTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'GitHub latest release returned HTTP ${response.statusCode}.',
          uri: _latestReleaseApiUri,
        );
      }

      final decoded = jsonDecode(body);
      final release = _stringKeyedMap(decoded);
      if (release == null) {
        throw const FormatException('GitHub release response was not a map.');
      }

      final tagName = _nonEmptyString(release['tag_name']);
      if (tagName == null) {
        throw const FormatException('GitHub release did not include a tag.');
      }
      final version = AppVersion.tryParse(tagName);
      if (version == null) {
        throw FormatException('Could not parse release version "$tagName".');
      }

      final title = _nonEmptyString(release['name']) ?? tagName;
      final releaseUrl =
          _absoluteUri(_nonEmptyString(release['html_url'])) ??
          _releaseUrlForTag(tagName);
      final publishedAt = DateTime.tryParse(
        _nonEmptyString(release['published_at']) ?? '',
      );

      return AppUpdateInfo(
        tagName: tagName,
        version: version,
        title: title,
        releaseUrl: releaseUrl,
        currentVersion: currentVersion,
        publishedAt: publishedAt,
      );
    } finally {
      if (_httpClient == null) {
        client.close(force: true);
      }
    }
  }

  Future<String?> loadCurrentVersion() async {
    try {
      final pubspec = await rootBundle.loadString('pubspec.yaml');
      final match = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec);
      if (match == null) {
        return null;
      }
      final raw = match.group(1)!;
      final plus = raw.indexOf('+');
      return _nonEmptyString(plus < 0 ? raw : raw.substring(0, plus));
    } catch (_) {
      return null;
    }
  }

  Future<void> openRelease(AppUpdateInfo update) async {
    final launched = await launchUrl(
      update.releaseUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      throw StateError('Could not open ${update.releaseUrl}.');
    }
  }

  Uri _releaseUrlForTag(String tagName) {
    return Uri.parse(
      '$appUpdateReleasesPageUrl/tag/${Uri.encodeComponent(tagName)}',
    );
  }

  Uri? _absoluteUri(String? value) {
    if (value == null) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    return uri;
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

  String? _nonEmptyString(Object? value) {
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }
}
