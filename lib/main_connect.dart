import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'l10n/app_strings.dart';
import 'main_constants.dart';
import 'main_helpers.dart';
import 'main_input.dart';
import 'main_sources.dart';
import 'models/vpn_profile.dart';
import 'services/vpn_controller.dart';

const double _splitConnectTopOffset = 28;

class ConnectPageBody extends StatefulWidget {
  const ConnectPageBody({
    super.key,
    required this.controller,
    required this.strings,
    this.onSwipePastLastSource,
    this.onSwipePastLastSourceDragUpdate,
    this.onSwipePastLastSourceDragEnd,
    this.onSwipePastLastSourceDragCancel,
  });

  final VpnController controller;
  final AppStrings strings;
  final VoidCallback? onSwipePastLastSource;
  final ValueChanged<double>? onSwipePastLastSourceDragUpdate;
  final ValueChanged<double>? onSwipePastLastSourceDragEnd;
  final VoidCallback? onSwipePastLastSourceDragCancel;

  @override
  State<ConnectPageBody> createState() => ConnectPageBodyState();
}

class ConnectPageBodyState extends State<ConnectPageBody> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useSplitLayout =
            widget.controller.hasSources && constraints.maxWidth >= 1080;
        final useMobileSourcePager =
            widget.controller.hasSources &&
            constraints.maxWidth < mobileShellBreakpoint;

        if (useSplitLayout) {
          return SizedBox.expand(
            key: const ValueKey<String>('connect-split-fixed'),
            child: _SplitConnectLayout(
              controller: widget.controller,
              strings: widget.strings,
            ),
          );
        }

        final heroStatus = Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _HeroStatusCard(controller: widget.controller),
          ),
        );
        final quickSwitch = Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: QuickSwitchPanel(
              controller: widget.controller,
              strings: widget.strings,
              fillMobileSwipeArea: useMobileSourcePager,
              onSwipePastLastMobileSource: widget.onSwipePastLastSource,
              onSwipePastLastMobileSourceDragUpdate:
                  widget.onSwipePastLastSourceDragUpdate,
              onSwipePastLastMobileSourceDragEnd:
                  widget.onSwipePastLastSourceDragEnd,
              onSwipePastLastMobileSourceDragCancel:
                  widget.onSwipePastLastSourceDragCancel,
            ),
          ),
        );

        if (useMobileSourcePager) {
          return Column(
            key: const ValueKey<String>('connect-mobile-fixed-layout'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              heroStatus,
              const SizedBox(height: 20),
              Expanded(child: quickSwitch),
            ],
          );
        }

        return SingleChildScrollView(
          key: const PageStorageKey<String>('connect-scroll'),
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.controller.hasSources) ...<Widget>[
                quickSwitch,
                const SizedBox(height: 20),
                heroStatus,
                const SizedBox(height: 20),
              ] else
                heroStatus,
            ],
          ),
        );
      },
    );
  }
}

class _SplitConnectLayout extends StatefulWidget {
  const _SplitConnectLayout({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_SplitConnectLayout> createState() => _SplitConnectLayoutState();
}

class _SplitConnectLayoutState extends State<_SplitConnectLayout> {
  final GlobalKey _firstSourceTileKey = const GlobalObjectKey(
    'split-first-source-card',
  );
  final GlobalKey _powerButtonKey = const GlobalObjectKey('split-power-button');
  double? _firstSourceTileHeight;
  double _powerButtonVerticalCorrection = 0;
  bool _sourceAnchorLocked = false;

  @override
  void didUpdateWidget(covariant _SplitConnectLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.sources.length !=
        widget.controller.sources.length) {
      _firstSourceTileHeight = null;
      _powerButtonVerticalCorrection = 0;
      _sourceAnchorLocked = false;
      _scheduleSplitMeasurement();
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSplitMeasurement();
    final sourceAnchorHeight =
        _firstSourceTileHeight ?? _SplitHeroStatusAnchor.fallbackAnchorHeight;
    final splitTopInset = _SplitHeroStatusAnchor.topInsetFor(
      anchorHeight: sourceAnchorHeight,
      verticalCorrection: _powerButtonVerticalCorrection,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.only(
              top: _splitConnectTopOffset,
              right: 14,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: _SplitHeroStatusAnchor(
                  controller: widget.controller,
                  anchorHeight: sourceAnchorHeight,
                  verticalCorrection: _powerButtonVerticalCorrection,
                  powerButtonKey: _powerButtonKey,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          flex: 7,
          child: Padding(
            padding: EdgeInsets.only(
              left: 14,
              top: splitTopInset + _splitConnectTopOffset,
            ),
            child: QuickSwitchPanel(
              controller: widget.controller,
              strings: widget.strings,
              firstTileCardKey: _firstSourceTileKey,
            ),
          ),
        ),
      ],
    );
  }

  void _scheduleSplitMeasurement() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_sourceAnchorLocked) {
        return;
      }
      final cardBox =
          _firstSourceTileKey.currentContext?.findRenderObject() as RenderBox?;
      final buttonBox =
          _powerButtonKey.currentContext?.findRenderObject() as RenderBox?;
      final height = cardBox?.size.height;
      if (cardBox == null || height == null || height <= 0) {
        return;
      }
      final nextHeight = height;
      var nextCorrection = _powerButtonVerticalCorrection;

      if (buttonBox != null && buttonBox.hasSize && buttonBox.size.height > 0) {
        final cardTop = cardBox.localToGlobal(Offset.zero).dy;
        final cardBottom = cardTop + cardBox.size.height;
        final buttonTop = buttonBox.localToGlobal(Offset.zero).dy;
        final buttonBottom = buttonTop + buttonBox.size.height;
        final topGap = cardTop - buttonTop;
        final bottomGap = buttonBottom - cardBottom;
        nextCorrection += (topGap - bottomGap) / 2;
      }

      final heightChanged =
          _firstSourceTileHeight == null ||
          (nextHeight - _firstSourceTileHeight!).abs() >= 0.5;
      final correctionChanged =
          (nextCorrection - _powerButtonVerticalCorrection).abs() >= 0.5;

      if (!heightChanged && !correctionChanged) {
        _sourceAnchorLocked = true;
        return;
      }

      setState(() {
        _firstSourceTileHeight = nextHeight;
        _powerButtonVerticalCorrection = nextCorrection;
      });
    });
  }
}

class _HeroStatusCard extends StatelessWidget {
  const _HeroStatusCard({
    required this.controller,
    this.layout = _HeroStatusLayout.hero,
    this.powerButtonKey,
  });

  final VpnController controller;
  final _HeroStatusLayout layout;
  final Key? powerButtonKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMobileShell =
        MediaQuery.sizeOf(context).width < mobileShellBreakpoint;
    final isSplit = layout == _HeroStatusLayout.split;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobileShell ? 12 : 24,
        isMobileShell ? 16 : 0,
        isMobileShell ? 12 : 24,
        isMobileShell ? 18 : (isSplit ? 0 : 28),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _PowerButton(
            controller: controller,
            diameter: isSplit ? splitPowerButtonDiameter : null,
            buttonKey: powerButtonKey,
          ),
          const SizedBox(height: 22),
          _ConnectionStatusLabel(controller: controller),
          if (controller.runtimeError != null &&
              controller.phase == ConnectionPhase.error) ...<Widget>[
            const SizedBox(height: 20),
            MessageStrip(
              containerColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
              icon: Icons.warning_amber_rounded,
              text: controller.runtimeError!,
            ),
          ],
        ],
      ),
    );
  }
}

class _SplitHeroStatusAnchor extends StatelessWidget {
  const _SplitHeroStatusAnchor({
    required this.controller,
    required this.anchorHeight,
    required this.verticalCorrection,
    required this.powerButtonKey,
  });

  static const double fallbackAnchorHeight = 112;
  static const double _statusReserveHeight = 58;

  final VpnController controller;
  final double anchorHeight;
  final double verticalCorrection;
  final Key powerButtonKey;

  static double topInsetFor({
    required double anchorHeight,
    required double verticalCorrection,
  }) {
    final buttonTop =
        (anchorHeight - splitPowerButtonDiameter) / 2 + verticalCorrection;
    return math.max(0, -buttonTop);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, _) {
        final buttonSize = splitPowerButtonDiameter;
        final rawButtonTop =
            (anchorHeight - buttonSize) / 2 + verticalCorrection;
        final topInset = topInsetFor(
          anchorHeight: anchorHeight,
          verticalCorrection: verticalCorrection,
        );
        final buttonTop = rawButtonTop + topInset;
        final height = math.max(
          topInset + anchorHeight,
          buttonTop + buttonSize + _statusReserveHeight,
        );

        return SizedBox(
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: <Widget>[
              Positioned(
                top: buttonTop,
                child: _HeroStatusCard(
                  controller: controller,
                  layout: _HeroStatusLayout.split,
                  powerButtonKey: powerButtonKey,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _HeroStatusLayout { hero, split }

class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.controller, this.diameter, this.buttonKey});

  final VpnController controller;
  final double? diameter;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isBusy = controller.isBusy;
    final isConnected = controller.isConnected;
    final glowColor = phaseColor(controller.phase, scheme);
    final buttonColor = switch (controller.phase) {
      ConnectionPhase.disconnected => Colors.white,
      ConnectionPhase.connecting => Colors.white,
      ConnectionPhase.connected => connectedColor,
      ConnectionPhase.disconnecting => const Color(0xFFE6E6E6),
      ConnectionPhase.error => scheme.error,
    };
    final foregroundColor = switch (controller.phase) {
      ConnectionPhase.disconnected => Colors.black,
      ConnectionPhase.connecting => Colors.black,
      ConnectionPhase.connected => Colors.white,
      ConnectionPhase.disconnecting => Colors.black,
      ConnectionPhase.error => scheme.onError,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 520.0;
        final buttonSize = diameter ?? _powerButtonSizeForWidth(availableWidth);
        final innerSize = buttonSize * 0.87;
        final iconSize = buttonSize * 0.4;
        final progressSize = buttonSize * 0.2;

        return Center(
          child: AnimatedContainer(
            key: buttonKey,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            width: buttonSize,
            height: buttonSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  glowColor.withValues(alpha: isConnected ? 0.28 : 0.18),
                  glowColor.withValues(alpha: 0.02),
                ],
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: glowColor.withValues(
                    alpha: isConnected
                        ? 0.38
                        : controller.phase == ConnectionPhase.connecting
                        ? 0.26
                        : 0.14,
                  ),
                  blurRadius: isConnected ? 48 : 28,
                  spreadRadius: isConnected ? 6 : 1,
                ),
              ],
            ),
            child: _CircularHitTestArea(
              child: Semantics(
                button: true,
                enabled: !isBusy,
                child: Material(
                  color: buttonColor,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    mouseCursor: isBusy
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.click,
                    onTap: isBusy ? null : controller.toggleConnection,
                    child: SizedBox.expand(
                      child: Center(
                        child: SizedBox(
                          width: innerSize,
                          height: innerSize,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              isBusy
                                  ? SizedBox(
                                      width: progressSize,
                                      height: progressSize,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: foregroundColor,
                                      ),
                                    )
                                  : Icon(
                                      Icons.power_settings_new_rounded,
                                      size: iconSize,
                                      color: foregroundColor,
                                    ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CircularHitTestArea extends SingleChildRenderObjectWidget {
  const _CircularHitTestArea({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCircularHitTestArea();
  }
}

class _RenderCircularHitTestArea extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final offset = position - center;
    if (offset.distanceSquared > radius * radius) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}

double _powerButtonSizeForWidth(double availableWidth) {
  return availableWidth < 360
      ? 176.0
      : availableWidth < 520
      ? 196.0
      : 216.0;
}

class _ConnectionStatusLabel extends StatefulWidget {
  const _ConnectionStatusLabel({required this.controller});

  final VpnController controller;

  @override
  State<_ConnectionStatusLabel> createState() => _ConnectionStatusLabelState();
}

class _ConnectionStatusLabelState extends State<_ConnectionStatusLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _ConnectionStatusLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    if (widget.controller.isConnected && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
      return;
    }
    if (!widget.controller.isConnected && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusText = switch (widget.controller.phase) {
      ConnectionPhase.connected =>
        '${strings.powerConnectedLabel} ${formatConnectedDuration(widget.controller.connectedAt)}',
      ConnectionPhase.disconnected => strings.powerDisconnectedLabel,
      ConnectionPhase.connecting => strings.connectingLabel,
      ConnectionPhase.disconnecting => strings.disconnectingLabel,
      ConnectionPhase.error => strings.failedLabel,
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: Text(
        statusText,
        key: ValueKey<ConnectionPhase>(widget.controller.phase),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
