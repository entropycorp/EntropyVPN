import 'dart:ui' show Color, TextHeightBehavior;

import 'utils/flag_aspect_ratio.dart';

const seedColor = Color(0xFFEDEDED);
const connectedColor = Color(0xFF4CAF50);
const appBackgroundColor = Color(0xFF000000);
const mobileShellBreakpoint = 620.0;
const splitPowerButtonDiameter = 196.0;
const mobilePageTransitionDuration = Duration(milliseconds: 125);
const qrImageFileExtensions = <String>[
  'png',
  'jpg',
  'jpeg',
  'bmp',
  'gif',
  'webp',
];

enum QrScanSource { gallery, camera, clipboardImage, imageFile }

enum SourceMenuAction { exportJson, delete }

const double desktopSourceRailTopInset = 0;
const double desktopSourceRailItemSize = 34;
const double desktopSourceRailItemRadius = desktopSourceRailItemSize / 2;
const double desktopSourceRailItemGap = 4;
const double desktopSourceRailVerticalPadding = 6;

const double mobileSourcePagerDotGap = 10;
const double mobileSourcePagerDotHeight = 6;
const double mobileSourcePagerHeaderHeight =
    mobileSourcePagerDotHeight + mobileSourcePagerDotGap;
const double mobileSourcePagerSwipeDistanceThreshold = 56;
const double mobileSourcePagerSwipeVelocityThreshold = 500;
const double mobileProfileCardHeight = 72;
const double mobileProfileCardSpacing = 10;
const double mobileSubscriptionPanelPadding = 8;
const double mobileSubscriptionHeaderLeftPadding = 0;
const double mobileSubscriptionHeaderRightPadding = 0;
const double mobileSubscriptionHeaderBottomPadding = 6;
const double mobileSubscriptionHeaderIconSize = 38;
const double mobileSubscriptionHeaderIconGap = 10;
// Place the header row by baseline so font metrics, not paragraph-box centering,
// determine how the text sits against the 38px subscription icon.
const double mobileSubscriptionHeaderTextBaseline = 21;
const double mobileSubscriptionHeaderGap = 6;
const double mobileSubscriptionTrafficTopGap = 5;
const double mobileSubscriptionTrafficProfileGap = 11;
const double mobileConfigCardVerticalPadding = 12;
const double mobileConfigCardMinHeight = 72;
const double desktopConfigCardMinHeight = 74;
const double configCardMinSegmentGap = 4;
const double configCardFlagSize = 32;
const double configCardFlagWidth = configCardFlagSize * defaultFlagAspectRatio;
const double configCardFlagGap = 10;
const TextHeightBehavior configCardTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: false,
  applyHeightToLastDescent: false,
);
const double mobileProfileSubtitleFontSize = 13;
const double compactSourceActionSize = 34;
const double compactSourceActionGap = 3;

double mobileSubscriptionHeaderActionsWidth({required bool hasAbout}) {
  final buttons = hasAbout ? 4 : 3;
  return compactSourceActionSize * buttons + compactSourceActionGap * (buttons - 1);
}
