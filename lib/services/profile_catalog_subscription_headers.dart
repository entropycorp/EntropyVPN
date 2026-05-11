part of 'profile_catalog_service.dart';

String? _subscriptionTrafficUsageHeader(HttpHeaders headers) {
  final directHeader =
      headers.value('subscription-userinfo') ??
      headers.value('Subscription-Userinfo');
  if (directHeader != null && directHeader.trim().isNotEmpty) {
    return directHeader;
  }

  String? scannedHeader;
  headers.forEach((name, values) {
    if (scannedHeader != null) {
      return;
    }
    final normalizedName = name.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (normalizedName == 'subscriptionuserinfo' ||
        normalizedName == 'subscriptionuserinformation') {
      if (values.isNotEmpty) {
        scannedHeader = values.join('; ');
      }
    }
  });

  return scannedHeader;
}

String? _profileTitleHeader(HttpHeaders headers) {
  final directHeader =
      headers.value('profile-title') ?? headers.value('Profile-Title');
  if (directHeader != null && directHeader.trim().isNotEmpty) {
    return _decodeHeaderLabel(directHeader);
  }

  String? scannedHeader;
  headers.forEach((name, values) {
    if (scannedHeader != null) {
      return;
    }
    final normalizedName = name.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (normalizedName == 'profiletitle' && values.isNotEmpty) {
      scannedHeader = values.join(' ');
    }
  });

  return _decodeHeaderLabel(scannedHeader);
}

SubscriptionTrafficUsage? _parseSubscriptionTrafficUsage(String? header) {
  if (header == null || header.trim().isEmpty) {
    return null;
  }

  final values = <String, int>{};
  final pattern = RegExp(
    r'\b(upload|download|total|expire|up|down|used)\s*=\s*(\d+)\b',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(header)) {
    final key = match.group(1)?.toLowerCase();
    final value = int.tryParse(match.group(2) ?? '');
    if (key == null || value == null || value < 0) {
      continue;
    }
    values[_normalizeTrafficUsageKey(key)] = value;
  }

  final expireSeconds = values['expire'];
  final expiresAt = expireSeconds != null && expireSeconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(
          expireSeconds * 1000,
          isUtc: true,
        ).toLocal()
      : null;

  if (!values.containsKey('upload') &&
      !values.containsKey('download') &&
      !values.containsKey('total') &&
      expiresAt == null) {
    return null;
  }

  final total = values['total'];
  final used = values['used'];
  return SubscriptionTrafficUsage(
    uploadBytes: values['upload'] ?? 0,
    downloadBytes: values['download'] ?? used ?? 0,
    totalBytes: total != null && total > 0 ? total : null,
    expiresAt: expiresAt,
  );
}

String _normalizeTrafficUsageKey(String key) {
  return switch (key) {
    'up' => 'upload',
    'down' => 'download',
    _ => key,
  };
}
