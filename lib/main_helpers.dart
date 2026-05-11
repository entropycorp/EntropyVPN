part of 'main.dart';

class _EntropyBackdrop extends StatelessWidget {
  const _EntropyBackdrop();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(color: _appBackgroundColor),
    );
  }
}

TextStyle _monoStyle(
  ThemeData theme, {
  Color? color,
  double? fontSize,
  FontWeight? weight,
}) {
  return (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
    fontFamily: 'JetBrainsMono',
    color: color ?? theme.colorScheme.onSurfaceVariant,
    fontSize: fontSize,
    fontWeight: weight ?? FontWeight.w600,
    height: 1.35,
    letterSpacing: 0.2,
  );
}

String _sourceHeadline(ConfigSource source, ParsedVpnProfile? profile) {
  if (source.isSubscription && source.hasMultipleProfiles) {
    return _sourceSubscriptionTitle(source);
  }

  final title = profile?.remark?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  if (profile != null) {
    return profile.endpointLabel;
  }
  return _sourceFragmentTitle(source) ??
      _sourceDisplayName(source) ??
      _sourceFallbackTitle(source);
}

String _sourceSubscriptionTitle(ConfigSource source) {
  return _sourceFragmentTitle(source) ??
      _sourceDisplayName(source) ??
      _sourceFallbackTitle(source);
}

String? _sourceDisplayName(ConfigSource source) {
  final displayName = source.displayName?.trim();
  if (displayName == null || displayName.isEmpty) {
    return null;
  }
  return displayName;
}

String? _sourceFragmentTitle(ConfigSource source) {
  final uri = Uri.tryParse(source.rawInput.trim());
  final fragment = uri?.fragment.trim();
  if (fragment == null || fragment.isEmpty) {
    return null;
  }

  try {
    final decoded = Uri.decodeComponent(fragment).trim();
    return decoded.isEmpty ? null : decoded;
  } on FormatException {
    return fragment;
  }
}

String _sourceSubtitle(
  AppStrings strings,
  CoreFlavor? core,
  ParsedVpnProfile? profile,
) {
  if (profile == null) {
    return strings.noProfilesLoaded;
  }
  if (profile.isSingBoxConfig) {
    final outboundType = profile.singBoxOutboundType?.trim();
    if (outboundType != null && outboundType.isNotEmpty) {
      final parts = <String>[
        if (core != null) strings.coreName(core),
        _singBoxProtocolLabel(strings, profile),
        _profileNetworkMode(strings, profile),
      ];
      final flowLabel = _profileFlowLabel(profile.flow);
      if (flowLabel != null && !parts.contains(flowLabel)) {
        parts.add(flowLabel);
      }
      return parts.join(' / ');
    }
    return <String>[
      if (core != null) strings.coreName(core),
      profile.endpointLabel,
    ].join(' / ');
  }
  if (profile.isXrayConfig) {
    final outboundProtocol = profile.xrayOutboundProtocol?.trim();
    if (outboundProtocol != null && outboundProtocol.isNotEmpty) {
      final parts = <String>[
        if (core != null) strings.coreName(core),
        _xrayProtocolLabel(strings, profile),
        _profileNetworkMode(strings, profile),
      ];
      final flowLabel = _profileFlowLabel(profile.flow);
      if (flowLabel != null && !parts.contains(flowLabel)) {
        parts.add(flowLabel);
      }
      return parts.join(' / ');
    }
    return <String>[
      if (core != null) strings.coreName(core),
      profile.endpointLabel,
    ].join(' / ');
  }
  final networkMode = _profileNetworkMode(strings, profile);
  final parts = <String>[
    if (core != null) strings.coreName(core),
    strings.protocolName(profile.protocol),
    networkMode,
  ];
  return parts.join(' / ');
}

String _profileNetworkMode(AppStrings strings, ParsedVpnProfile profile) {
  return profile.tlsMode == TlsMode.reality
      ? strings.tlsName(profile.tlsMode)
      : strings.transportName(profile.transport);
}

String _singBoxProtocolLabel(AppStrings strings, ParsedVpnProfile profile) {
  final outboundType = profile.singBoxOutboundType?.trim().toLowerCase();
  return switch (outboundType) {
    'vless' => strings.protocolName(LinkProtocol.vless),
    'vmess' => strings.protocolName(LinkProtocol.vmess),
    'trojan' => strings.protocolName(LinkProtocol.trojan),
    'shadowsocks' => strings.protocolName(LinkProtocol.shadowsocks),
    String value when value.isNotEmpty => _formatSingBoxType(value),
    _ => strings.protocolName(profile.protocol),
  };
}

String _xrayProtocolLabel(AppStrings strings, ParsedVpnProfile profile) {
  final outboundProtocol = profile.xrayOutboundProtocol?.trim().toLowerCase();
  return switch (outboundProtocol) {
    'vless' => strings.protocolName(LinkProtocol.vless),
    'vmess' => strings.protocolName(LinkProtocol.vmess),
    'trojan' => strings.protocolName(LinkProtocol.trojan),
    'shadowsocks' => strings.protocolName(LinkProtocol.shadowsocks),
    String value when value.isNotEmpty => _formatSingBoxType(value),
    _ => strings.protocolName(profile.protocol),
  };
}

String? _profileFlowLabel(String? flow) {
  final normalized = flow?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  if (normalized.toLowerCase().contains('vision')) {
    return 'XTLS Vision';
  }
  return normalized;
}

String _formatSingBoxType(String value) {
  return value
      .split(RegExp(r'[-_]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

String _profileOptionLabel(AppStrings strings, ParsedVpnProfile profile) {
  if (profile.isSingBoxConfig) {
    return profile.remark?.trim().isNotEmpty == true
        ? profile.remark!.trim()
        : 'Sing-box config';
  }
  final title = profile.remark?.trim();
  if (title != null && title.isNotEmpty) {
    return '$title - ${profile.endpointLabel}';
  }
  return '${strings.protocolName(profile.protocol)} - ${profile.endpointLabel}';
}

double _mobileSourcePageHeight(
  BuildContext context,
  ConfigSource source, {
  required VpnController controller,
  required AppStrings strings,
  required double maxWidth,
}) {
  if (source.isSubscription) {
    final theme = Theme.of(context);
    final visibleRows = source.profiles.length.clamp(1, 4).toInt();
    final rowHeight = _mobileProfileCardHeightFor(context);
    final listHeight =
        visibleRows * rowHeight + (visibleRows - 1) * _mobileProfileCardSpacing;
    final innerWidth = (maxWidth - _mobileSubscriptionPanelPadding * 2)
        .clamp(96.0, double.infinity)
        .toDouble();
    final headerTextWidth =
        (innerWidth -
                _mobileSubscriptionHeaderLeftPadding -
                _mobileSubscriptionHeaderRightPadding -
                _mobileSubscriptionHeaderIconSize -
                _mobileSubscriptionHeaderIconGap -
                8 -
                _mobileSubscriptionHeaderActionWidth)
            .clamp(48.0, double.infinity)
            .toDouble();
    final headerTitleHeight = _measuredTextHeight(
      context,
      _sourceSubscriptionTitle(source),
      _subscriptionHeaderTitleStyle(theme),
      maxWidth: headerTextWidth,
      maxLines: 1,
    );
    final expiresLabel = _sourceTrafficExpiryDateLabel(source);
    final headerTextHeight = expiresLabel == null
        ? headerTitleHeight
        : math.max(
            headerTitleHeight,
            _measuredTextHeight(
              context,
              expiresLabel,
              _subscriptionHeaderExpiryStyle(theme, theme.colorScheme),
              maxWidth: headerTextWidth,
              maxLines: 1,
            ),
          );
    final headerHeight =
        _mobileSubscriptionHeaderBottomPadding +
        math.max(_mobileSubscriptionHeaderIconSize, headerTextHeight);

    var height =
        _mobileSubscriptionPanelPadding * 2 + headerHeight + listHeight;

    if (source.lastUpdateError != null) {
      final errorTextWidth = (innerWidth - 16 - 7)
          .clamp(64.0, double.infinity)
          .toDouble();
      final errorHeight = math.max(
        16.0,
        _measuredTextHeight(
          context,
          source.lastUpdateError!,
          theme.textTheme.bodySmall,
          maxWidth: errorTextWidth,
          maxLines: 2,
        ),
      );
      height += 10 + errorHeight;
    }

    final usage = source.trafficUsage;
    if (usage != null && usage.hasTotal) {
      height +=
          _mobileSubscriptionTrafficTopGap +
          24 +
          _mobileSubscriptionTrafficProfileGap;
    } else {
      height += _mobileSubscriptionHeaderGap;
    }

    return height.ceilToDouble().clamp(132.0, 620.0).toDouble();
  }

  final theme = Theme.of(context);
  final profile = source.selectedProfile;
  final showSourceState = source.isUpdating || !source.hasMultipleProfiles;
  final actionRowWidth = showSourceState ? 74.0 : 34.0;
  final titleStyle = _configCardTitleStyle(theme);
  final subtitleStyle = _configCardSubtitleStyle(theme, theme.colorScheme);
  const flagWidth = _configCardFlagWidth;
  final textWidth =
      (maxWidth -
              18 -
              _configCardFlagGap -
              flagWidth -
              14 -
              14 -
              actionRowWidth)
          .clamp(64.0, double.infinity)
          .toDouble();
  final titleMetrics = _measuredTextVisualMetrics(
    context,
    _sourceHeadline(source, profile),
    titleStyle,
    maxWidth: textWidth,
    maxLines: 1,
    textHeightBehavior: _configCardTextHeightBehavior,
  );
  final subtitleMetrics = _measuredTextVisualMetrics(
    context,
    _sourceSubtitle(
      strings,
      controller.displayCoreForProfile(profile),
      profile,
    ),
    subtitleStyle,
    maxWidth: textWidth,
    maxLines: 2,
    textHeightBehavior: _configCardTextHeightBehavior,
  );

  var primaryHeight = _configCardPrimaryHeight(
    minHeight: _mobileConfigCardMinHeight,
    titleHeight: titleMetrics.visualHeight,
    subtitleHeight: subtitleMetrics.visualHeight,
  );

  final usage = source.trafficUsage;
  if (source.isSubscription && usage != null && usage.hasTotal) {
    primaryHeight += 8 + 24;
    if (usage.expiresAt != null) {
      final expiresLabel = _formatCompactDate(usage.expiresAt!);
      final expiresStyle = _subscriptionTrafficExpiryStyle(
        theme,
        theme.colorScheme,
      );
      primaryHeight +=
          7 +
          _measuredTrafficExpiryHeight(
            context,
            expiresLabel,
            expiresStyle,
            maxWidth: textWidth,
          );
    }
  }

  var height = primaryHeight;

  if (source.lastUpdateError != null) {
    final errorTextWidth = (maxWidth - 18 - 14 - 16 - 7)
        .clamp(64.0, double.infinity)
        .toDouble();
    final errorHeight = math.max(
      16.0,
      _measuredTextHeight(
        context,
        source.lastUpdateError!,
        theme.textTheme.bodySmall,
        maxWidth: errorTextWidth,
        maxLines: 2,
      ),
    );
    height += 10 + errorHeight + _mobileConfigCardVerticalPadding;
  }

  return height
      .ceilToDouble()
      .clamp(_mobileConfigCardMinHeight, 360.0)
      .toDouble();
}

double _mobileSourcePagerMinHeight(
  BuildContext context,
  List<ConfigSource> sources, {
  required VpnController controller,
  required AppStrings strings,
  required double maxWidth,
}) {
  var height = 0.0;
  for (final source in sources) {
    final sourceHeight = _mobileSourcePageHeight(
      context,
      source,
      controller: controller,
      strings: strings,
      maxWidth: maxWidth,
    );
    if (sourceHeight > height) {
      height = sourceHeight;
    }
  }
  if (sources.length > 1) {
    height += _mobileSourcePagerDotGap + _mobileSourcePagerDotHeight;
  }
  return height;
}

double _mobileProfileCardHeightFor(BuildContext context) {
  final scaledBodySize = MediaQuery.textScalerOf(context).scale(14);
  final extraHeight = math.max(0.0, scaledBodySize - 14) * 2.2;
  return (_mobileProfileCardHeight + extraHeight)
      .clamp(_mobileProfileCardHeight, 124.0)
      .toDouble();
}

double _configCardPrimaryHeight({
  required double minHeight,
  required double titleHeight,
  required double subtitleHeight,
}) {
  return math.max(
    minHeight,
    titleHeight + subtitleHeight + _configCardMinSegmentGap * 3,
  );
}

class _MeasuredTextVisualMetrics {
  const _MeasuredTextVisualMetrics({
    required this.visualTop,
    required this.visualBottom,
  });

  final double visualTop;
  final double visualBottom;

  double get visualHeight => visualBottom - visualTop;
  double get visualCenterY => visualTop + visualHeight / 2;
}

_MeasuredTextVisualMetrics _measuredTextVisualMetrics(
  BuildContext context,
  String text,
  TextStyle? style, {
  required double maxWidth,
  required int maxLines,
  TextHeightBehavior? textHeightBehavior,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: style ?? DefaultTextStyle.of(context).style,
    ),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    maxLines: maxLines,
    textScaler: MediaQuery.textScalerOf(context),
    textHeightBehavior: textHeightBehavior,
  )..layout(maxWidth: maxWidth);
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
    boxHeightStyle: BoxHeightStyle.tight,
    boxWidthStyle: BoxWidthStyle.tight,
  );
  if (boxes.isEmpty) {
    return _MeasuredTextVisualMetrics(
      visualTop: 0,
      visualBottom: painter.size.height,
    );
  }

  var visualTop = boxes.first.top;
  var visualBottom = boxes.first.bottom;
  for (final box in boxes.skip(1)) {
    visualTop = math.min(visualTop, box.top);
    visualBottom = math.max(visualBottom, box.bottom);
  }
  return _MeasuredTextVisualMetrics(
    visualTop: visualTop,
    visualBottom: visualBottom,
  );
}

double _measuredTextHeight(
  BuildContext context,
  String text,
  TextStyle? style, {
  required double maxWidth,
  required int maxLines,
  TextHeightBehavior? textHeightBehavior,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: style ?? DefaultTextStyle.of(context).style,
    ),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    maxLines: maxLines,
    textScaler: MediaQuery.textScalerOf(context),
    textHeightBehavior: textHeightBehavior,
  )..layout(maxWidth: maxWidth);
  return painter.size.height;
}

TextStyle? _subscriptionTrafficExpiryStyle(
  ThemeData theme,
  ColorScheme scheme,
) {
  return theme.textTheme.bodySmall?.copyWith(
    color: scheme.onSurface,
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w500,
  );
}

TextStyle? _configCardTitleStyle(ThemeData theme) {
  return theme.textTheme.titleSmall?.copyWith(height: 1);
}

TextStyle? _configCardSubtitleStyle(ThemeData theme, ColorScheme scheme) {
  return _profileSubtitleStyle(theme, scheme)?.copyWith(height: 1);
}

TextStyle? _profileSubtitleStyle(ThemeData theme, ColorScheme scheme) {
  return theme.textTheme.bodyMedium?.copyWith(
    color: scheme.onSurfaceVariant,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.15,
    letterSpacing: 0,
  );
}

Color _selectedConfigSurfaceColor(ColorScheme scheme) {
  return scheme.primary.withValues(alpha: 0.24);
}

Color _trafficBarTrackColor(ColorScheme scheme) {
  return scheme.primary.withValues(alpha: 0.16);
}

const TextHeightBehavior _subscriptionHeaderTextHeightBehavior =
    TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    );

TextStyle? _subscriptionHeaderTitleStyle(ThemeData theme) {
  return theme.textTheme.titleSmall?.copyWith(height: 1);
}

TextStyle? _subscriptionHeaderExpiryStyle(ThemeData theme, ColorScheme scheme) {
  return _subscriptionTrafficExpiryStyle(theme, scheme)?.copyWith(height: 1);
}

String? _sourceTrafficExpiryDateLabel(ConfigSource source) {
  final usage = source.trafficUsage;
  final expiresAt = usage?.expiresAt;
  if (usage == null || !usage.hasTotal || expiresAt == null) {
    return null;
  }
  return _formatCompactDate(expiresAt);
}

double _measuredTrafficExpiryHeight(
  BuildContext context,
  String dateLabel,
  TextStyle? style, {
  required double maxWidth,
}) {
  final textWidth =
      (maxWidth -
              _subscriptionTrafficExpiryIconSize -
              _subscriptionTrafficExpiryIconGap)
          .clamp(1.0, double.infinity)
          .toDouble();
  final textHeight = _measuredTextHeight(
    context,
    dateLabel,
    style,
    maxWidth: textWidth,
    maxLines: 1,
  );
  return math.max(_subscriptionTrafficExpiryIconSize, textHeight);
}

String _profileChoiceTitle(ParsedVpnProfile profile) {
  final title = profile.remark?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  return profile.endpointLabel;
}

String _sourceFallbackTitle(ConfigSource source) {
  final raw = source.rawInput.trim();
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.host.isNotEmpty) {
    final fragment = uri.fragment.trim();
    if (fragment.isNotEmpty) {
      try {
        final decoded = Uri.decodeComponent(fragment).trim();
        if (decoded.isNotEmpty) {
          return decoded;
        }
      } on FormatException {
        return fragment;
      }
    }
    for (final segment in uri.pathSegments.reversed) {
      final decoded = Uri.decodeComponent(segment).trim();
      if (decoded.isNotEmpty) {
        return decoded;
      }
    }
    return uri.host;
  }
  if (raw.length <= 36) {
    return raw;
  }
  return '${raw.substring(0, 36)}...';
}

String _sourceJsonFileName(ConfigSource source) {
  final title = _sourceHeadline(source, source.selectedProfile);
  final kind = source.isSubscription ? 'subscription' : 'config';
  final fallback = '$kind-${source.id}';
  final stem = _sanitizeFileStem(title).isEmpty
      ? _sanitizeFileStem(fallback)
      : _sanitizeFileStem(title);
  return '$stem.json';
}

String _sanitizeFileStem(String value) {
  const invalidCharacters = '<>:"/\\|?*';
  final buffer = StringBuffer();
  for (final codeUnit in value.trim().codeUnits) {
    final char = String.fromCharCode(codeUnit);
    if (codeUnit < 32 || invalidCharacters.contains(char)) {
      buffer.write('-');
    } else {
      buffer.write(char);
    }
  }

  final compact = buffer
      .toString()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp('-+'), '-')
      .trim()
      .replaceAll(RegExp(r'^[. -]+|[. -]+$'), '');
  if (compact.isEmpty) {
    return 'entropyvpn-config';
  }
  final clipped = compact.length <= 72 ? compact : compact.substring(0, 72);
  final cleaned = clipped.trim().replaceAll(RegExp(r'^[. -]+|[. -]+$'), '');
  return cleaned.isEmpty ? 'entropyvpn-config' : cleaned;
}

extension on ConfigSource {
  String get serverAddress => selectedProfile?.server ?? '';
}

Color _phaseColor(ConnectionPhase phase, ColorScheme scheme) {
  switch (phase) {
    case ConnectionPhase.connected:
      return _connectedColor;
    case ConnectionPhase.connecting:
      return scheme.secondary;
    case ConnectionPhase.disconnecting:
      return scheme.outline;
    case ConnectionPhase.error:
      return scheme.error;
    case ConnectionPhase.disconnected:
      return scheme.primary;
  }
}

String _formatTrafficBytes(int bytes) {
  final safeBytes = bytes < 0 ? 0 : bytes;
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = safeBytes.toDouble();
  var unitIndex = 0;

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  if (unitIndex == 0) {
    return '$safeBytes B';
  }

  final formatted = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '${formatted.replaceFirst(RegExp(r'\.0$'), '')} ${units[unitIndex]}';
}

String _formatCompactDate(DateTime date) {
  final local = date.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final year = local.year.toString().padLeft(4, '0');
  return '$day.$month.$year';
}

String _formatConnectedDuration(DateTime? connectedAt) {
  if (connectedAt == null) {
    return '00:00';
  }

  final elapsed = DateTime.now().difference(connectedAt);
  final safeElapsed = elapsed.isNegative ? Duration.zero : elapsed;
  final hours = safeElapsed.inHours;
  final minutes = safeElapsed.inMinutes.remainder(60);
  final seconds = safeElapsed.inSeconds.remainder(60);
  final minutesText = minutes.toString().padLeft(2, '0');
  final secondsText = seconds.toString().padLeft(2, '0');

  if (hours > 0) {
    return '$hours:$minutesText:$secondsText';
  }
  return '$minutesText:$secondsText';
}
