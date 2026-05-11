import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle, TextHeightBehavior;

import 'package:flutter/material.dart';

import 'l10n/app_strings.dart';
import 'main_constants.dart';
import 'models/config_source.dart';
import 'models/vpn_profile.dart';
import 'services/vpn_controller.dart';

class ProgrammaticPageSwipePhysics extends ScrollPhysics {
  const ProgrammaticPageSwipePhysics({super.parent});

  @override
  ProgrammaticPageSwipePhysics applyTo(ScrollPhysics? ancestor) {
    return ProgrammaticPageSwipePhysics(parent: buildParent(ancestor));
  }

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false;
}

TextStyle monoStyle(
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

String sourceHeadline(ConfigSource source, ParsedVpnProfile? profile) {
  if (source.isSubscription && source.hasMultipleProfiles) {
    return sourceSubscriptionTitle(source);
  }

  final title = profile?.remark?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  if (profile != null) {
    return profile.endpointLabel;
  }
  return sourceFragmentTitle(source) ??
      sourceDisplayName(source) ??
      sourceFallbackTitle(source);
}

String sourceSubscriptionTitle(ConfigSource source) {
  return sourceFragmentTitle(source) ??
      sourceDisplayName(source) ??
      sourceFallbackTitle(source);
}

String? sourceDisplayName(ConfigSource source) {
  final displayName = source.displayName?.trim();
  if (displayName == null || displayName.isEmpty) {
    return null;
  }
  return displayName;
}

String? sourceFragmentTitle(ConfigSource source) {
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

String sourceSubtitle(
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
        singBoxProtocolLabel(strings, profile),
        profileNetworkMode(strings, profile),
      ];
      final flowLabel = profileFlowLabel(profile.flow);
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
        xrayProtocolLabel(strings, profile),
        profileNetworkMode(strings, profile),
      ];
      final flowLabel = profileFlowLabel(profile.flow);
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
  final networkMode = profileNetworkMode(strings, profile);
  final parts = <String>[
    if (core != null) strings.coreName(core),
    strings.protocolName(profile.protocol),
    networkMode,
  ];
  return parts.join(' / ');
}

String profileNetworkMode(AppStrings strings, ParsedVpnProfile profile) {
  return profile.tlsMode == TlsMode.reality
      ? strings.tlsName(profile.tlsMode)
      : strings.transportName(profile.transport);
}

String singBoxProtocolLabel(AppStrings strings, ParsedVpnProfile profile) {
  final outboundType = profile.singBoxOutboundType?.trim().toLowerCase();
  return switch (outboundType) {
    'vless' => strings.protocolName(LinkProtocol.vless),
    'vmess' => strings.protocolName(LinkProtocol.vmess),
    'trojan' => strings.protocolName(LinkProtocol.trojan),
    'shadowsocks' => strings.protocolName(LinkProtocol.shadowsocks),
    String value when value.isNotEmpty => formatSingBoxType(value),
    _ => strings.protocolName(profile.protocol),
  };
}

String xrayProtocolLabel(AppStrings strings, ParsedVpnProfile profile) {
  final outboundProtocol = profile.xrayOutboundProtocol?.trim().toLowerCase();
  return switch (outboundProtocol) {
    'vless' => strings.protocolName(LinkProtocol.vless),
    'vmess' => strings.protocolName(LinkProtocol.vmess),
    'trojan' => strings.protocolName(LinkProtocol.trojan),
    'shadowsocks' => strings.protocolName(LinkProtocol.shadowsocks),
    String value when value.isNotEmpty => formatSingBoxType(value),
    _ => strings.protocolName(profile.protocol),
  };
}

String? profileFlowLabel(String? flow) {
  final normalized = flow?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  if (normalized.toLowerCase().contains('vision')) {
    return 'XTLS Vision';
  }
  return normalized;
}

String formatSingBoxType(String value) {
  return value
      .split(RegExp(r'[-_]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

String profileOptionLabel(AppStrings strings, ParsedVpnProfile profile) {
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

double mobileSourcePageHeight(
  BuildContext context,
  ConfigSource source, {
  required VpnController controller,
  required AppStrings strings,
  required double maxWidth,
}) {
  if (source.isSubscription) {
    final theme = Theme.of(context);
    final visibleRows = source.profiles.length.clamp(1, 4).toInt();
    final rowHeight = mobileProfileCardHeightFor(context);
    final listHeight =
        visibleRows * rowHeight + (visibleRows - 1) * mobileProfileCardSpacing;
    final innerWidth = (maxWidth - mobileSubscriptionPanelPadding * 2)
        .clamp(96.0, double.infinity)
        .toDouble();
    final headerTextWidth =
        (innerWidth -
                mobileSubscriptionHeaderLeftPadding -
                mobileSubscriptionHeaderRightPadding -
                mobileSubscriptionHeaderIconSize -
                mobileSubscriptionHeaderIconGap -
                8 -
                mobileSubscriptionHeaderActionWidth)
            .clamp(48.0, double.infinity)
            .toDouble();
    final headerTitleHeight = measuredTextHeight(
      context,
      sourceSubscriptionTitle(source),
      subscriptionHeaderTitleStyle(theme),
      maxWidth: headerTextWidth,
      maxLines: 1,
    );
    final expiresLabel = sourceTrafficExpiryDateLabel(source);
    final headerTextHeight = expiresLabel == null
        ? headerTitleHeight
        : math.max(
            headerTitleHeight,
            measuredTextHeight(
              context,
              expiresLabel,
              subscriptionHeaderExpiryStyle(theme, theme.colorScheme),
              maxWidth: headerTextWidth,
              maxLines: 1,
            ),
          );
    final headerHeight =
        mobileSubscriptionHeaderBottomPadding +
        math.max(mobileSubscriptionHeaderIconSize, headerTextHeight);

    var height = mobileSubscriptionPanelPadding * 2 + headerHeight + listHeight;

    if (source.lastUpdateError != null) {
      final errorTextWidth = (innerWidth - 16 - 7)
          .clamp(64.0, double.infinity)
          .toDouble();
      final errorHeight = math.max(
        16.0,
        measuredTextHeight(
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
          mobileSubscriptionTrafficTopGap +
          24 +
          mobileSubscriptionTrafficProfileGap;
    } else {
      height += mobileSubscriptionHeaderGap;
    }

    return height.ceilToDouble().clamp(132.0, 620.0).toDouble();
  }

  final theme = Theme.of(context);
  final profile = source.selectedProfile;
  final showSourceState = source.isUpdating || !source.hasMultipleProfiles;
  final actionRowWidth = showSourceState ? 74.0 : 34.0;
  final titleStyle = configCardTitleStyle(theme);
  final subtitleStyle = configCardSubtitleStyle(theme, theme.colorScheme);
  const flagWidth = configCardFlagWidth;
  final textWidth =
      (maxWidth - 18 - configCardFlagGap - flagWidth - 14 - 14 - actionRowWidth)
          .clamp(64.0, double.infinity)
          .toDouble();
  final titleMetrics = measuredTextVisualMetrics(
    context,
    sourceHeadline(source, profile),
    titleStyle,
    maxWidth: textWidth,
    maxLines: 1,
    textHeightBehavior: configCardTextHeightBehavior,
  );
  final subtitleMetrics = measuredTextVisualMetrics(
    context,
    sourceSubtitle(strings, controller.displayCoreForProfile(profile), profile),
    subtitleStyle,
    maxWidth: textWidth,
    maxLines: 2,
    textHeightBehavior: configCardTextHeightBehavior,
  );

  var primaryHeight = configCardPrimaryHeight(
    minHeight: mobileConfigCardMinHeight,
    titleHeight: titleMetrics.visualHeight,
    subtitleHeight: subtitleMetrics.visualHeight,
  );

  final usage = source.trafficUsage;
  if (source.isSubscription && usage != null && usage.hasTotal) {
    primaryHeight += 8 + 24;
    if (usage.expiresAt != null) {
      final expiresLabel = formatCompactDate(usage.expiresAt!);
      final expiresStyle = subscriptionTrafficExpiryStyle(
        theme,
        theme.colorScheme,
      );
      primaryHeight +=
          7 +
          measuredTrafficExpiryHeight(
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
      measuredTextHeight(
        context,
        source.lastUpdateError!,
        theme.textTheme.bodySmall,
        maxWidth: errorTextWidth,
        maxLines: 2,
      ),
    );
    height += 10 + errorHeight + mobileConfigCardVerticalPadding;
  }

  return height
      .ceilToDouble()
      .clamp(mobileConfigCardMinHeight, 360.0)
      .toDouble();
}

double mobileSourcePagerMinHeight(
  BuildContext context,
  List<ConfigSource> sources, {
  required VpnController controller,
  required AppStrings strings,
  required double maxWidth,
}) {
  var height = 0.0;
  for (final source in sources) {
    final sourceHeight = mobileSourcePageHeight(
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
    height += mobileSourcePagerDotGap + mobileSourcePagerDotHeight;
  }
  return height;
}

double mobileProfileCardHeightFor(BuildContext context) {
  final scaledBodySize = MediaQuery.textScalerOf(context).scale(14);
  final extraHeight = math.max(0.0, scaledBodySize - 14) * 2.2;
  return (mobileProfileCardHeight + extraHeight)
      .clamp(mobileProfileCardHeight, 124.0)
      .toDouble();
}

double configCardPrimaryHeight({
  required double minHeight,
  required double titleHeight,
  required double subtitleHeight,
}) {
  return math.max(
    minHeight,
    titleHeight + subtitleHeight + configCardMinSegmentGap * 3,
  );
}

class MeasuredTextVisualMetrics {
  const MeasuredTextVisualMetrics({
    required this.visualTop,
    required this.visualBottom,
  });

  final double visualTop;
  final double visualBottom;

  double get visualHeight => visualBottom - visualTop;
  double get visualCenterY => visualTop + visualHeight / 2;
}

MeasuredTextVisualMetrics measuredTextVisualMetrics(
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
    return MeasuredTextVisualMetrics(
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
  return MeasuredTextVisualMetrics(
    visualTop: visualTop,
    visualBottom: visualBottom,
  );
}

double measuredTextHeight(
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

TextStyle? subscriptionTrafficExpiryStyle(ThemeData theme, ColorScheme scheme) {
  return theme.textTheme.bodySmall?.copyWith(
    color: scheme.onSurface,
    fontSize: 11,
    height: 1.25,
    fontWeight: FontWeight.w500,
  );
}

TextStyle? configCardTitleStyle(ThemeData theme) {
  return theme.textTheme.titleSmall?.copyWith(height: 1);
}

TextStyle? configCardSubtitleStyle(ThemeData theme, ColorScheme scheme) {
  return profileSubtitleStyle(theme, scheme)?.copyWith(height: 1);
}

TextStyle? profileSubtitleStyle(ThemeData theme, ColorScheme scheme) {
  return theme.textTheme.bodyMedium?.copyWith(
    color: scheme.onSurfaceVariant,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.15,
    letterSpacing: 0,
  );
}

Color selectedConfigSurfaceColor(ColorScheme scheme) {
  return scheme.primary.withValues(alpha: 0.24);
}

Color trafficBarTrackColor(ColorScheme scheme) {
  return scheme.primary.withValues(alpha: 0.16);
}

const TextHeightBehavior subscriptionHeaderTextHeightBehavior =
    TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    );

TextStyle? subscriptionHeaderTitleStyle(ThemeData theme) {
  return theme.textTheme.titleSmall?.copyWith(height: 1);
}

TextStyle? subscriptionHeaderExpiryStyle(ThemeData theme, ColorScheme scheme) {
  return subscriptionTrafficExpiryStyle(theme, scheme)?.copyWith(height: 1);
}

String? sourceTrafficExpiryDateLabel(ConfigSource source) {
  final usage = source.trafficUsage;
  final expiresAt = usage?.expiresAt;
  if (usage == null || !usage.hasTotal || expiresAt == null) {
    return null;
  }
  return formatCompactDate(expiresAt);
}

double measuredTrafficExpiryHeight(
  BuildContext context,
  String dateLabel,
  TextStyle? style, {
  required double maxWidth,
}) {
  final textWidth =
      (maxWidth -
              subscriptionTrafficExpiryIconSize -
              subscriptionTrafficExpiryIconGap)
          .clamp(1.0, double.infinity)
          .toDouble();
  final textHeight = measuredTextHeight(
    context,
    dateLabel,
    style,
    maxWidth: textWidth,
    maxLines: 1,
  );
  return math.max(subscriptionTrafficExpiryIconSize, textHeight);
}

String profileChoiceTitle(ParsedVpnProfile profile) {
  final title = profile.remark?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  return profile.endpointLabel;
}

String sourceFallbackTitle(ConfigSource source) {
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

String sourceJsonFileName(ConfigSource source) {
  final title = sourceHeadline(source, source.selectedProfile);
  final kind = source.isSubscription ? 'subscription' : 'config';
  final fallback = '$kind-${source.id}';
  final stem = sanitizeFileStem(title).isEmpty
      ? sanitizeFileStem(fallback)
      : sanitizeFileStem(title);
  return '$stem.json';
}

String sanitizeFileStem(String value) {
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

extension ConfigSourceServerAddress on ConfigSource {
  String get serverAddress => selectedProfile?.server ?? '';
}

Color phaseColor(ConnectionPhase phase, ColorScheme scheme) {
  switch (phase) {
    case ConnectionPhase.connected:
      return connectedColor;
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

String formatTrafficBytes(int bytes) {
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

String formatCompactDate(DateTime date) {
  final local = date.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final year = local.year.toString().padLeft(4, '0');
  return '$day.$month.$year';
}

String formatConnectedDuration(DateTime? connectedAt) {
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
