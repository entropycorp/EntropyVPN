import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemException, Platform;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_strings.dart';
import 'main_constants.dart';
import 'main_flags.dart';
import 'main_helpers.dart';
import 'models/config_source.dart';
import 'services/config_source_export.dart';
import 'services/vpn_controller.dart';

class QuickSwitchPanel extends StatelessWidget {
  const QuickSwitchPanel({
    super.key,
    required this.controller,
    required this.strings,
    this.firstTileCardKey,
    this.fillMobileSwipeArea = false,
    this.onSwipePastLastMobileSource,
    this.onSwipePastLastMobileSourceDragUpdate,
    this.onSwipePastLastMobileSourceDragEnd,
    this.onSwipePastLastMobileSourceDragCancel,
  });

  final VpnController controller;
  final AppStrings strings;
  final Key? firstTileCardKey;
  final bool fillMobileSwipeArea;
  final VoidCallback? onSwipePastLastMobileSource;
  final ValueChanged<double>? onSwipePastLastMobileSourceDragUpdate;
  final ValueChanged<double>? onSwipePastLastMobileSourceDragEnd;
  final VoidCallback? onSwipePastLastMobileSourceDragCancel;

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < mobileShellBreakpoint;
    if (isMobile) {
      return _MobileSourcePager(
        controller: controller,
        strings: strings,
        fillSwipeArea: fillMobileSwipeArea,
        onSwipePastLastPage: onSwipePastLastMobileSource,
        onSwipePastLastPageDragUpdate: onSwipePastLastMobileSourceDragUpdate,
        onSwipePastLastPageDragEnd: onSwipePastLastMobileSourceDragEnd,
        onSwipePastLastPageDragCancel: onSwipePastLastMobileSourceDragCancel,
      );
    }

    return _DesktopSourcePager(
      controller: controller,
      strings: strings,
      cardKey: firstTileCardKey,
    );
  }
}

class _SourcePagerSelection {
  _SourcePagerSelection(VpnController controller)
    : currentPage = selectedSourceIndex(controller),
      _lastSelectedSourceId = controller.selectedSource?.id;

  int currentPage;
  String? _lastSelectedSourceId;

  int? controllerUpdatePage(VpnController controller) {
    final selectedId = controller.selectedSource?.id;
    if (selectedId != _lastSelectedSourceId) {
      _lastSelectedSourceId = selectedId;
      return selectedSourceIndex(controller);
    }

    final sources = controller.sources;
    if (sources.isEmpty) {
      return null;
    }

    final clampedPage = pageForSources(sources);
    return clampedPage == currentPage ? null : clampedPage;
  }

  int? targetPage(VpnController controller, int index) {
    final sources = controller.sources;
    if (sources.isEmpty) {
      return null;
    }
    return index.clamp(0, sources.length - 1).toInt();
  }

  bool containsPage(VpnController controller, int index) {
    return index >= 0 && index < controller.sources.length;
  }

  int pageForSources(List<ConfigSource> sources) {
    return currentPage.clamp(0, sources.length - 1).toInt();
  }

  static int selectedSourceIndex(VpnController controller) {
    final sources = controller.sources;
    if (sources.isEmpty) {
      return 0;
    }

    final selectedId = controller.selectedSource?.id;
    final index = sources.indexWhere((source) => source.id == selectedId);
    return index < 0 ? 0 : index;
  }
}

class _DesktopSourcePager extends StatefulWidget {
  const _DesktopSourcePager({
    required this.controller,
    required this.strings,
    this.cardKey,
  });

  final VpnController controller;
  final AppStrings strings;
  final Key? cardKey;

  @override
  State<_DesktopSourcePager> createState() => _DesktopSourcePagerState();
}

class _DesktopSourcePagerState extends State<_DesktopSourcePager> {
  late final _SourcePagerSelection _selection;

  @override
  void initState() {
    super.initState();
    _selection = _SourcePagerSelection(widget.controller);
  }

  @override
  void didUpdateWidget(covariant _DesktopSourcePager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetPage = _selection.controllerUpdatePage(widget.controller);
    if (targetPage != null) {
      _showPage(targetPage);
    }
  }

  void _showPage(int index) {
    final targetPage = _selection.targetPage(widget.controller, index);
    if (targetPage == null || targetPage == _selection.currentPage) {
      return;
    }

    setState(() {
      _selection.currentPage = targetPage;
    });
  }

  void _handlePageSelected(int index) {
    if (!_selection.containsPage(widget.controller, index)) {
      return;
    }

    _showPage(index);
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      return const SizedBox.shrink();
    }

    final pageIndex = _selection.pageForSources(sources);
    final source = sources[pageIndex];
    final hasPager = sources.length > 1;
    final minHeight = hasPager
        ? desktopSourceRailStackHeight(sources.length)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Stack(
          key: const ValueKey<String>('desktop-source-pager-stack'),
          clipBehavior: Clip.none,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.only(left: hasPager ? 54 : 0),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) {
                  return currentChild ?? const SizedBox.shrink();
                },
                child: _DesktopSourcePage(
                  key: ValueKey<String>('desktop-source-page-${source.id}'),
                  controller: widget.controller,
                  strings: widget.strings,
                  source: source,
                  selected: widget.controller.selectedSource?.id == source.id,
                  cardKey: widget.cardKey,
                ),
              ),
            ),
            if (hasPager)
              Positioned(
                top: desktopSourceRailTopInset,
                left: 0,
                child: _DesktopSourcePageRail(
                  sources: sources,
                  selected: pageIndex,
                  onSelected: _handlePageSelected,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

double desktopSourceRailStackHeight(int sourceCount) {
  if (sourceCount <= 0) {
    return 0;
  }
  return desktopSourceRailTopInset +
      desktopSourceRailVerticalPadding * 2 +
      sourceCount * desktopSourceRailItemSize +
      math.max(0, sourceCount - 1) * desktopSourceRailItemGap;
}

class _DesktopSourcePageRail extends StatelessWidget {
  const _DesktopSourcePageRail({
    required this.sources,
    required this.selected,
    required this.onSelected,
  });

  final List<ConfigSource> sources;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      key: const ValueKey<String>('desktop-source-page-rail'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.38),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 5,
          vertical: desktopSourceRailVerticalPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < sources.length; i += 1) ...<Widget>[
              Builder(
                builder: (context) {
                  final source = sources[i];
                  final isSelected = i == selected;
                  final iconColor = isSelected
                      ? scheme.primary
                      : scheme.onSurfaceVariant.withValues(alpha: 0.82);

                  return Tooltip(
                    message: sourceSubscriptionTitle(source),
                    child: InkResponse(
                      key: ValueKey<String>('desktop-source-page-dot-$i'),
                      radius: 20,
                      onTap: () => onSelected(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        width: desktopSourceRailItemSize,
                        height: desktopSourceRailItemSize,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? selectedConfigSurfaceColor(scheme)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(
                            desktopSourceRailItemRadius,
                          ),
                        ),
                        child: source.isSubscription
                            ? Icon(
                                Icons.link_rounded,
                                size: 18,
                                color: iconColor,
                              )
                            : Icon(
                                Icons.description_outlined,
                                size: 18,
                                color: iconColor,
                              ),
                      ),
                    ),
                  );
                },
              ),
              if (i != sources.length - 1)
                const SizedBox(height: desktopSourceRailItemGap),
            ],
          ],
        ),
      ),
    );
  }
}

class _DesktopSourcePage extends StatelessWidget {
  const _DesktopSourcePage({
    super.key,
    required this.controller,
    required this.strings,
    required this.source,
    required this.selected,
    this.cardKey,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;
  final bool selected;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    if (source.isSubscription) {
      return _SubscriptionProfilesPage(
        controller: controller,
        strings: strings,
        source: source,
        selected: selected,
        desktop: true,
        cardKey: cardKey,
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: UnconstrainedBox(
        constrainedAxis: Axis.horizontal,
        alignment: Alignment.topCenter,
        child: _QuickSourceTile(
          controller: controller,
          strings: strings,
          source: source,
          selected: selected,
          cardKey: cardKey,
        ),
      ),
    );
  }
}

class _MobileSourcePager extends StatefulWidget {
  const _MobileSourcePager({
    required this.controller,
    required this.strings,
    required this.fillSwipeArea,
    this.onSwipePastLastPage,
    this.onSwipePastLastPageDragUpdate,
    this.onSwipePastLastPageDragEnd,
    this.onSwipePastLastPageDragCancel,
  });

  final VpnController controller;
  final AppStrings strings;
  final bool fillSwipeArea;
  final VoidCallback? onSwipePastLastPage;
  final ValueChanged<double>? onSwipePastLastPageDragUpdate;
  final ValueChanged<double>? onSwipePastLastPageDragEnd;
  final VoidCallback? onSwipePastLastPageDragCancel;

  @override
  State<_MobileSourcePager> createState() => _MobileSourcePagerState();
}

class _MobileSourcePagerState extends State<_MobileSourcePager> {
  late final PageController _pageController;
  late final _SourcePagerSelection _selection;
  double _sourceDragDx = 0;
  bool _isDraggingPastLastPage = false;

  @override
  void initState() {
    super.initState();
    _selection = _SourcePagerSelection(widget.controller);
    _pageController = PageController(initialPage: _selection.currentPage);
  }

  @override
  void didUpdateWidget(covariant _MobileSourcePager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetPage = _selection.controllerUpdatePage(widget.controller);
    if (targetPage != null) {
      _showPage(targetPage);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _syncPage(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) {
        return;
      }
      final current = _pageController.page;
      if (current != null && current.round() == page) {
        return;
      }
      _pageController.animateToPage(
        page,
        duration: mobilePageTransitionDuration,
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showPage(int index) {
    final targetPage = _selection.targetPage(widget.controller, index);
    if (targetPage == null || targetPage == _selection.currentPage) {
      return;
    }

    setState(() {
      _selection.currentPage = targetPage;
    });
    _syncPage(targetPage);
  }

  void _handlePageChanged(int index) {
    if (!_selection.containsPage(widget.controller, index)) {
      return;
    }
    setState(() {
      _selection.currentPage = index;
    });
  }

  void _handleSourceDragStart(DragStartDetails details) {
    _sourceDragDx = 0;
    _isDraggingPastLastPage = false;
  }

  void _handleSourceDragUpdate(DragUpdateDetails details) {
    final deltaDx = details.primaryDelta ?? details.delta.dx;
    _sourceDragDx += deltaDx;
    if (_isDraggingPastLastPage || _shouldDragPastLastPage(deltaDx)) {
      _isDraggingPastLastPage = true;
      widget.onSwipePastLastPageDragUpdate?.call(deltaDx);
    }
  }

  void _handleSourceDragCancel() {
    _sourceDragDx = 0;
    if (_isDraggingPastLastPage) {
      _isDraggingPastLastPage = false;
      widget.onSwipePastLastPageDragCancel?.call();
    }
  }

  bool _shouldDragPastLastPage(double deltaDx) {
    if (deltaDx >= 0 && _sourceDragDx >= 0) {
      return false;
    }

    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      return false;
    }

    final pageIndex = _selection.pageForSources(sources);
    return pageIndex == sources.length - 1;
  }

  void _handleSourceDragEnd(DragEndDetails details) {
    if (!widget.controller.canBrowseSources) {
      _sourceDragDx = 0;
      if (_isDraggingPastLastPage) {
        _isDraggingPastLastPage = false;
        widget.onSwipePastLastPageDragCancel?.call();
      }
      return;
    }

    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      _sourceDragDx = 0;
      if (_isDraggingPastLastPage) {
        _isDraggingPastLastPage = false;
        widget.onSwipePastLastPageDragCancel?.call();
      }
      return;
    }

    final velocityDx =
        details.primaryVelocity ?? details.velocity.pixelsPerSecond.dx;
    final wasDraggingPastLastPage = _isDraggingPastLastPage;
    _isDraggingPastLastPage = false;
    int direction = 0;
    if (velocityDx.abs() >= mobileSourcePagerSwipeVelocityThreshold) {
      direction = velocityDx < 0 ? -1 : 1;
    } else if (_sourceDragDx.abs() >= mobileSourcePagerSwipeDistanceThreshold) {
      direction = _sourceDragDx < 0 ? -1 : 1;
    }
    _sourceDragDx = 0;

    if (direction == 0) {
      if (wasDraggingPastLastPage) {
        if (widget.onSwipePastLastPageDragEnd != null) {
          widget.onSwipePastLastPageDragEnd!(velocityDx);
        } else {
          widget.onSwipePastLastPageDragCancel?.call();
        }
      }
      return;
    }

    final pageIndex = _selection.pageForSources(sources);
    if (direction < 0) {
      if (pageIndex < sources.length - 1) {
        _showPage(pageIndex + 1);
      } else if (wasDraggingPastLastPage) {
        if (widget.onSwipePastLastPageDragEnd != null) {
          widget.onSwipePastLastPageDragEnd!(velocityDx);
        } else {
          widget.onSwipePastLastPage?.call();
        }
      } else {
        widget.onSwipePastLastPage?.call();
      }
      return;
    }

    if (wasDraggingPastLastPage) {
      widget.onSwipePastLastPageDragCancel?.call();
    }
    if (pageIndex > 0) {
      _showPage(pageIndex - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      return const SizedBox.shrink();
    }

    const pagePhysics = ProgrammaticPageSwipePhysics();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pageIndex = _selection.pageForSources(sources);
          final availableWidth = constraints.maxWidth;
          final pageHeight = mobileSourcePageHeight(
            context,
            sources[pageIndex],
            controller: widget.controller,
            strings: widget.strings,
            maxWidth: availableWidth,
          );

          if (widget.fillSwipeArea) {
            final pagerHeaderHeight = sources.length > 1
                ? mobileSourcePagerHeaderHeight
                : 0.0;
            final minHeight = mobileSourcePagerMinHeight(
              context,
              sources,
              controller: widget.controller,
              strings: widget.strings,
              maxWidth: availableWidth,
            );
            final availableHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : minHeight;
            final height = availableHeight < minHeight
                ? minHeight
                : availableHeight;

            return SizedBox(
              height: height,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    top: pagerHeaderHeight,
                    child: _buildSourcePageView(
                      sources: sources,
                      physics: pagePhysics,
                      fillViewport: true,
                      availableWidth: availableWidth,
                    ),
                  ),
                  if (sources.length > 1)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: IgnorePointer(
                        child: _SourcePagerDots(
                          count: sources.length,
                          selected: pageIndex,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }

          return Column(
            children: <Widget>[
              if (sources.length > 1) ...<Widget>[
                _SourcePagerDots(count: sources.length, selected: pageIndex),
                const SizedBox(height: mobileSourcePagerDotGap),
              ],
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                height: pageHeight,
                child: _buildSourcePageView(
                  sources: sources,
                  physics: pagePhysics,
                  fillViewport: false,
                  availableWidth: availableWidth,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSourcePageView({
    required List<ConfigSource> sources,
    required ScrollPhysics physics,
    required bool fillViewport,
    required double availableWidth,
  }) {
    final canBrowseSources = widget.controller.canBrowseSources;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: canBrowseSources ? _handleSourceDragStart : null,
      onHorizontalDragUpdate: canBrowseSources ? _handleSourceDragUpdate : null,
      onHorizontalDragEnd: canBrowseSources ? _handleSourceDragEnd : null,
      onHorizontalDragCancel: canBrowseSources ? _handleSourceDragCancel : null,
      child: PageView.builder(
        controller: _pageController,
        key: const ValueKey<String>('mobile-connect-source-bottom-swipe-area'),
        physics: physics,
        onPageChanged: _handlePageChanged,
        itemCount: sources.length,
        itemBuilder: (context, index) {
          final source = sources[index];
          final selected = widget.controller.selectedSource?.id == source.id;
          final page = _buildSourcePage(source: source, selected: selected);
          if (!fillViewport) {
            return page;
          }

          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: mobileSourcePageHeight(
                context,
                source,
                controller: widget.controller,
                strings: widget.strings,
                maxWidth: availableWidth,
              ),
              child: page,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSourcePage({
    required ConfigSource source,
    required bool selected,
  }) {
    if (source.isSubscription) {
      return _SubscriptionProfilesPage(
        controller: widget.controller,
        strings: widget.strings,
        source: source,
        selected: selected,
      );
    }
    return _QuickSourceTile(
      controller: widget.controller,
      strings: widget.strings,
      source: source,
      selected: selected,
    );
  }
}

class _SourcePagerDots extends StatelessWidget {
  const _SourcePagerDots({required this.count, required this.selected});

  final int count;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (var i = 0; i < count; i += 1) ...<Widget>[
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            width: i == selected ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == selected
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          if (i != count - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _SubscriptionProfilesPage extends StatelessWidget {
  const _SubscriptionProfilesPage({
    required this.controller,
    required this.strings,
    required this.source,
    required this.selected,
    this.desktop = false,
    this.cardKey,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;
  final bool selected;
  final bool desktop;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trafficUsage = source.trafficUsage;

    Widget buildPanel({required bool containProfileScroll}) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.16)
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Padding(
          padding: const EdgeInsets.all(mobileSubscriptionPanelPadding),
          child: Column(
            mainAxisSize: desktop ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _MobileSubscriptionHeader(
                controller: controller,
                strings: strings,
                source: source,
                selected: selected,
              ),
              if (source.lastUpdateError != null) ...<Widget>[
                const SizedBox(height: 10),
                _SourceUpdateErrorBanner(message: source.lastUpdateError!),
              ],
              if (trafficUsage != null && trafficUsage.hasTotal) ...<Widget>[
                const SizedBox(height: mobileSubscriptionTrafficTopGap),
                _SubscriptionTrafficUsageBar(
                  key: ValueKey<String>('subscription-traffic-${source.id}'),
                  usage: trafficUsage,
                  strings: strings,
                ),
              ],
              if (!desktop || source.profiles.isNotEmpty) ...<Widget>[
                SizedBox(
                  height: trafficUsage != null && trafficUsage.hasTotal
                      ? mobileSubscriptionTrafficProfileGap
                      : mobileSubscriptionHeaderGap,
                ),
                if (!desktop)
                  Expanded(child: _buildMobileProfileList())
                else if (containProfileScroll)
                  Flexible(child: _buildDesktopProfileList())
                else
                  ..._buildProfileCards(),
              ],
            ],
          ),
        ),
      );
    }

    if (!desktop) {
      return buildPanel(containProfileScroll: false);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return buildPanel(
          containProfileScroll:
              constraints.maxHeight.isFinite && source.profiles.isNotEmpty,
        );
      },
    );
  }

  Widget _buildMobileProfileList() {
    return _buildProfileList(physics: const BouncingScrollPhysics());
  }

  Widget _buildDesktopProfileList() {
    return Scrollbar(
      child: _buildProfileList(
        key: PageStorageKey<String>(
          'desktop-subscription-profiles-${source.id}',
        ),
        physics: const ClampingScrollPhysics(),
        primary: false,
        shrinkWrap: true,
      ),
    );
  }

  Widget _buildProfileList({
    Key? key,
    required ScrollPhysics physics,
    bool? primary,
    bool shrinkWrap = false,
  }) {
    return ListView.separated(
      key: key,
      primary: primary,
      shrinkWrap: shrinkWrap,
      padding: EdgeInsets.zero,
      physics: physics,
      itemCount: source.profiles.length,
      separatorBuilder: (context, index) =>
          const SizedBox(height: mobileProfileCardSpacing),
      itemBuilder: (context, index) => _buildProfileCard(index),
    );
  }

  Widget _buildProfileCard(int index) {
    return _MobileSubscriptionProfileCard(
      controller: controller,
      strings: strings,
      source: source,
      profileIndex: index,
      selected: selected && source.selectedProfileIndex == index,
      cardKey: desktop && index == 0 ? cardKey : null,
    );
  }

  List<Widget> _buildProfileCards() {
    return <Widget>[
      for (var i = 0; i < source.profiles.length; i += 1) ...<Widget>[
        _buildProfileCard(i),
        if (i != source.profiles.length - 1)
          const SizedBox(height: mobileProfileCardSpacing),
      ],
    ];
  }
}

class _MobileSubscriptionHeader extends StatelessWidget {
  const _MobileSubscriptionHeader({
    required this.controller,
    required this.strings,
    required this.source,
    required this.selected,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = sourceSubscriptionTitle(source);
    final titleStyle = subscriptionHeaderTitleStyle(theme);
    final hasAbout = sourceHasAboutInfo(source);
    final actionWidth = mobileSubscriptionHeaderActionsWidth(hasAbout: hasAbout);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        mobileSubscriptionHeaderLeftPadding,
        0,
        mobileSubscriptionHeaderRightPadding,
        mobileSubscriptionHeaderBottomPadding,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: mobileSubscriptionHeaderIconSize,
            height: mobileSubscriptionHeaderIconSize,
            decoration: BoxDecoration(
              color: selected
                  ? selectedConfigSurfaceColor(scheme)
                  : scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.link_rounded,
              size: 22,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: mobileSubscriptionHeaderIconGap),
          Expanded(
            child: SizedBox(
              height: mobileSubscriptionHeaderIconSize,
              child: Baseline(
                baseline: mobileSubscriptionHeaderTextBaseline,
                baselineType: TextBaseline.alphabetic,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                  textHeightBehavior: subscriptionHeaderTextHeightBehavior,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: actionWidth,
            height: compactSourceActionSize,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (hasAbout) ...<Widget>[
                  _AboutSubscriptionButton(strings: strings, source: source),
                  const SizedBox(width: compactSourceActionGap),
                ],
                SizedBox(
                  width: compactSourceActionSize,
                  height: compactSourceActionSize,
                  child: Center(
                    child: source.isUpdating
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.3,
                              color: scheme.tertiary,
                            ),
                          )
                        : IconButton(
                            onPressed: source.isSubscription
                                ? () => unawaited(
                                    controller.refreshSource(source.id),
                                  )
                                : null,
                            tooltip: strings.updateNowAction,
                            icon: const Icon(Icons.refresh_rounded),
                            iconSize: 21,
                            style: _compactSourceIconButtonStyle(scheme),
                          ),
                  ),
                ),
                const SizedBox(width: compactSourceActionGap),
                _SourcePingButton(
                  controller: controller,
                  strings: strings,
                  source: source,
                ),
                const SizedBox(width: compactSourceActionGap),
                _SourceMenuButton(
                  controller: controller,
                  strings: strings,
                  source: source,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileSubscriptionProfileCard extends StatelessWidget {
  const _MobileSubscriptionProfileCard({
    required this.controller,
    required this.strings,
    required this.source,
    required this.profileIndex,
    required this.selected,
    this.cardKey,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;
  final int profileIndex;
  final bool selected;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profile = source.profiles[profileIndex];
    final core = controller.displayCoreForProfile(profile);
    final cardHeight = mobileProfileCardHeightFor(context);
    final title = profileChoiceTitle(profile);
    final subtitle = sourceSubtitle(strings, core, profile);
    final titleStyle = configCardTitleStyle(theme);
    final subtitleStyle = configCardSubtitleStyle(
      theme,
      scheme,
    )?.copyWith(fontSize: mobileProfileSubtitleFontSize);
    final tcpPingLatency = source.tcpPingLatencyForProfile(profileIndex);
    final showPingResult = tcpPingLatency != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: controller.canEditSources
            ? () {
                controller.selectSource(source.id);
                controller.setSelectedProfileIndex(profileIndex);
              }
            : null,
        child: Ink(
          key: cardKey,
          height: cardHeight,
          padding: const EdgeInsets.fromLTRB(18, 0, 14, 0),
          decoration: BoxDecoration(
            color: selected
                ? selectedConfigSurfaceColor(scheme)
                : scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(22),
          ),
          child: _SourceCardPrimaryRow(
            height: cardHeight,
            server: profile.server,
            selected: selected,
            flagKey: ValueKey<String>(
              'mobile-profile-flag-${source.id}-$profileIndex',
            ),
            flagOffset: const Offset(-3, -8),
            title: title,
            subtitle: subtitle,
            titleStyle: titleStyle,
            subtitleStyle: subtitleStyle,
            subtitleMaxLines: 1,
            trailingGap: 12,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (showPingResult) ...<Widget>[
                  _TcpPingResultLabel(milliseconds: tcpPingLatency),
                  const SizedBox(width: 8),
                ],
                _SourceCardSelectionIndicator(selected: selected),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceCardPrimaryRow extends StatelessWidget {
  const _SourceCardPrimaryRow({
    required this.height,
    required this.server,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.titleStyle,
    required this.subtitleStyle,
    required this.subtitleMaxLines,
    required this.trailing,
    this.flagKey,
    this.flagOffset = Offset.zero,
    this.trailingGap = 14,
    this.titleMetrics,
    this.subtitleMetrics,
  });

  final double height;
  final String server;
  final bool selected;
  final String title;
  final String subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final int subtitleMaxLines;
  final Widget trailing;
  final Key? flagKey;
  final Offset flagOffset;
  final double trailingGap;
  final MeasuredTextVisualMetrics? titleMetrics;
  final MeasuredTextVisualMetrics? subtitleMetrics;

  @override
  Widget build(BuildContext context) {
    Widget flag = ServerFlagBadge(
      key: flagKey,
      server: server,
      selected: selected,
      size: configCardFlagSize,
    );
    if (flagOffset != Offset.zero) {
      flag = Transform.translate(offset: flagOffset, child: flag);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        flag,
        const SizedBox(width: configCardFlagGap),
        Expanded(
          child: _SourceCardTextStack(
            height: height,
            title: title,
            subtitle: subtitle,
            titleStyle: titleStyle,
            subtitleStyle: subtitleStyle,
            subtitleMaxLines: subtitleMaxLines,
            titleMetrics: titleMetrics,
            subtitleMetrics: subtitleMetrics,
          ),
        ),
        SizedBox(width: trailingGap),
        trailing,
      ],
    );
  }
}

class _SourceCardTextStack extends StatelessWidget {
  const _SourceCardTextStack({
    required this.height,
    required this.title,
    required this.subtitle,
    required this.titleStyle,
    required this.subtitleStyle,
    required this.subtitleMaxLines,
    this.titleMetrics,
    this.subtitleMetrics,
  });

  final double height;
  final String title;
  final String subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final int subtitleMaxLines;
  final MeasuredTextVisualMetrics? titleMetrics;
  final MeasuredTextVisualMetrics? subtitleMetrics;

  @override
  Widget build(BuildContext context) {
    final titleMetrics = this.titleMetrics;
    final subtitleMetrics = this.subtitleMetrics;
    if (titleMetrics != null && subtitleMetrics != null) {
      return _buildPositionedText(titleMetrics, subtitleMetrics);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = constraints.maxWidth
            .clamp(64.0, double.infinity)
            .toDouble();
        final titleMetrics = measuredTextVisualMetrics(
          context,
          title,
          titleStyle,
          maxWidth: textWidth,
          maxLines: 1,
          textHeightBehavior: configCardTextHeightBehavior,
        );
        final subtitleMetrics = measuredTextVisualMetrics(
          context,
          subtitle,
          subtitleStyle,
          maxWidth: textWidth,
          maxLines: subtitleMaxLines,
          textHeightBehavior: configCardTextHeightBehavior,
        );
        return _buildPositionedText(titleMetrics, subtitleMetrics);
      },
    );
  }

  Widget _buildPositionedText(
    MeasuredTextVisualMetrics titleMetrics,
    MeasuredTextVisualMetrics subtitleMetrics,
  ) {
    final titleCenterY = height / 3;
    final subtitleCenterY = height * 2 / 3;

    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            top: titleCenterY - titleMetrics.visualCenterY,
            right: 0,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
              textHeightBehavior: configCardTextHeightBehavior,
            ),
          ),
          Positioned(
            left: 0,
            top: subtitleCenterY - subtitleMetrics.visualCenterY,
            right: 0,
            child: Text(
              subtitle,
              maxLines: subtitleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
              textHeightBehavior: configCardTextHeightBehavior,
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCardSelectionIndicator extends StatelessWidget {
  const _SourceCardSelectionIndicator({
    required this.selected,
    this.updating = false,
  });

  final bool selected;
  final bool updating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 34,
      height: 34,
      child: Center(
        child: updating
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.3,
                  color: scheme.tertiary,
                ),
              )
            : Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: selected ? scheme.primary : scheme.outline,
              ),
      ),
    );
  }
}

class _TcpPingResultLabel extends StatelessWidget {
  const _TcpPingResultLabel({required this.milliseconds});

  final int milliseconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latencyColor = _tcpPingLatencyColor(milliseconds);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 64),
      child: Text(
        '$milliseconds ms',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: latencyColor,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    );
  }
}

Color _tcpPingLatencyColor(int milliseconds) {
  if (milliseconds <= 50) {
    return const Color(0xFF4CAF50);
  }
  if (milliseconds <= 100) {
    return const Color(0xFF8BC34A);
  }
  if (milliseconds <= 150) {
    return const Color(0xFFFFD54F);
  }
  if (milliseconds <= 200) {
    return const Color(0xFFFF9800);
  }
  return const Color(0xFFF44336);
}

class _SourceMenuButton extends StatelessWidget {
  const _SourceMenuButton({
    required this.controller,
    required this.strings,
    required this.source,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sourceMenu = _SourceMenuController(
      controller: controller,
      strings: strings,
      source: source,
    );

    return Builder(
      builder: (buttonContext) {
        return IconButton(
          onPressed: () => unawaited(sourceMenu.showAtButton(buttonContext)),
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          icon: const Icon(Icons.more_horiz_rounded),
          iconSize: 22,
          style: _compactSourceIconButtonStyle(scheme),
        );
      },
    );
  }
}

class _SourceMenuController {
  const _SourceMenuController({
    required this.controller,
    required this.strings,
    required this.source,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;

  List<PopupMenuEntry<SourceMenuAction>> items(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final menuLabelStyle =
        (theme.popupMenuTheme.textStyle ??
                theme.textTheme.labelLarge ??
                const TextStyle())
            .copyWith(fontWeight: FontWeight.w600);
    final canRemoveSource = controller.canRemoveSource(source.id);
    final removeColor = canRemoveSource
        ? scheme.error
        : scheme.onSurfaceVariant.withValues(alpha: 0.54);
    final items = <PopupMenuEntry<SourceMenuAction>>[];

    if (source.isSubscription) {
      items.add(
        _SourceAutoUpdateMenuEntry(
          source: source,
          strings: strings,
          onChanged: (interval) {
            controller.setSourceAutoUpdateInterval(source.id, interval);
          },
        ),
      );
    }

    items.add(
      PopupMenuItem<SourceMenuAction>(
        value: SourceMenuAction.exportJson,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.file_download_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(strings.exportJsonAction, style: menuLabelStyle),
          ],
        ),
      ),
    );

    items.add(
      PopupMenuItem<SourceMenuAction>(
        value: SourceMenuAction.delete,
        enabled: canRemoveSource,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.delete_outline_rounded, color: removeColor),
            const SizedBox(width: 10),
            Text(
              strings.removeSourceAction,
              style: menuLabelStyle.copyWith(color: removeColor),
            ),
          ],
        ),
      ),
    );

    return items;
  }

  void handleAction(BuildContext context, SourceMenuAction action) {
    switch (action) {
      case SourceMenuAction.exportJson:
        unawaited(_exportJson(context));
        break;
      case SourceMenuAction.delete:
        unawaited(controller.removeSource(source.id));
        break;
    }
  }

  Future<void> showAtCursor(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }

    final localPosition = overlay.globalToLocal(globalPosition);
    await showAtRect(
      context,
      Rect.fromPoints(localPosition, localPosition),
      overlay.size,
    );
  }

  Future<void> showAtButton(BuildContext buttonContext) async {
    final button = buttonContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) {
      return;
    }

    final buttonTopLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    await showAtRect(buttonContext, buttonTopLeft & button.size, overlay.size);
  }

  Future<void> showAtRect(
    BuildContext context,
    Rect anchor,
    Size overlaySize,
  ) async {
    final action = await showMenu<SourceMenuAction>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: items(context),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      menuPadding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      popUpAnimationStyle: AnimationStyle.noAnimation,
    );
    if (action != null && context.mounted) {
      handleAction(context, action);
    }
  }

  Future<void> _exportJson(BuildContext context) async {
    try {
      final bytes = Uint8List.fromList(
        utf8.encode('${ConfigSourceExport.encode(source)}\n'),
      );
      final savedPath = await FilePicker.saveFile(
        dialogTitle: strings.exportJsonAction,
        fileName: sourceJsonFileName(source),
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
        bytes: bytes,
        lockParentWindow: Platform.isWindows,
      );
      if (!context.mounted || savedPath == null) {
        return;
      }

      _showSnackBar(context, strings.jsonExportedMessage);
    } on PlatformException {
      if (context.mounted) {
        _showSnackBar(context, strings.jsonExportFailedMessage);
      }
    } on FileSystemException {
      if (context.mounted) {
        _showSnackBar(context, strings.jsonExportFailedMessage);
      }
    } catch (_) {
      if (context.mounted) {
        _showSnackBar(context, strings.jsonExportFailedMessage);
      }
    }
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }
}

class _SourcePingButton extends StatelessWidget {
  const _SourcePingButton({
    required this.controller,
    required this.strings,
    required this.source,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: compactSourceActionSize,
      height: compactSourceActionSize,
      child: Center(
        child: source.isPinging
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.3,
                  color: scheme.tertiary,
                ),
              )
            : IconButton(
                onPressed: controller.canPingSource(source.id)
                    ? () => unawaited(controller.pingSource(source.id))
                    : null,
                tooltip: strings.tcpPingAction,
                icon: const Icon(Icons.rss_feed_rounded),
                iconSize: 21,
                style: _compactSourceIconButtonStyle(scheme),
              ),
      ),
    );
  }
}

ButtonStyle _compactSourceIconButtonStyle(ColorScheme scheme) {
  return IconButton.styleFrom(
    fixedSize: const Size(compactSourceActionSize, compactSourceActionSize),
    minimumSize: const Size(compactSourceActionSize, compactSourceActionSize),
    maximumSize: const Size(compactSourceActionSize, compactSourceActionSize),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    foregroundColor: scheme.onSurfaceVariant,
    disabledForegroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.38),
    backgroundColor: Colors.transparent,
    hoverColor: scheme.onSurface.withValues(alpha: 0.12),
    highlightColor: scheme.onSurface.withValues(alpha: 0.16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
  );
}

class _SourceUpdateErrorBanner extends StatelessWidget {
  const _SourceUpdateErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: <Widget>[
        Icon(Icons.error_outline_rounded, size: 16, color: scheme.error),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ),
      ],
    );
  }
}

class _QuickSourceTile extends StatelessWidget {
  const _QuickSourceTile({
    required this.controller,
    required this.strings,
    required this.source,
    required this.selected,
    this.cardKey,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;
  final bool selected;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sourceMenu = _SourceMenuController(
      controller: controller,
      strings: strings,
      source: source,
    );
    final profile = source.selectedProfile;
    final trafficUsage = source.trafficUsage;
    final isMobile = MediaQuery.sizeOf(context).width < mobileShellBreakpoint;
    final showSourceState =
        source.isUpdating || !(isMobile && source.hasMultipleProfiles);
    final tcpPingLatency = source.tcpPingLatencyForProfile(
      source.selectedProfileIndex,
    );
    final showPingResult = tcpPingLatency != null;
    final showAbout = sourceHasAboutInfo(source);
    final actionRowWidth =
        34.0 +
        (showSourceState ? 40.0 : 0.0) +
        (showPingResult ? 72.0 : 0.0) +
        (showAbout ? 40.0 : 0.0);
    final title = sourceHeadline(source, profile);
    final subtitle = sourceSubtitle(
      strings,
      controller.displayCoreForProfile(profile),
      profile,
    );
    final titleStyle = configCardTitleStyle(theme);
    final subtitleStyle = configCardSubtitleStyle(theme, scheme);
    final minPrimaryHeight = isMobile
        ? mobileConfigCardMinHeight
        : desktopConfigCardMinHeight;
    final extraContentBottomPadding = isMobile
        ? mobileConfigCardVerticalPadding
        : 18.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final textWidth =
            (availableWidth -
                    18 -
                    configCardFlagWidth -
                    configCardFlagGap -
                    14 -
                    14 -
                    actionRowWidth)
                .clamp(64.0, double.infinity)
                .toDouble();
        final titleMetrics = measuredTextVisualMetrics(
          context,
          title,
          titleStyle,
          maxWidth: textWidth,
          maxLines: 1,
          textHeightBehavior: configCardTextHeightBehavior,
        );
        final subtitleMetrics = measuredTextVisualMetrics(
          context,
          subtitle,
          subtitleStyle,
          maxWidth: textWidth,
          maxLines: 2,
          textHeightBehavior: configCardTextHeightBehavior,
        );
        final primaryHeight = configCardPrimaryHeight(
          minHeight: minPrimaryHeight,
          titleHeight: titleMetrics.visualHeight,
          subtitleHeight: subtitleMetrics.visualHeight,
        );
        final hasTrafficUsage =
            source.isSubscription &&
            trafficUsage != null &&
            trafficUsage.hasTotal;
        final hasProfileDropdown =
            selected && source.hasMultipleProfiles && !isMobile;
        final hasExtraContent =
            source.lastUpdateError != null ||
            hasTrafficUsage ||
            hasProfileDropdown;

        final body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: primaryHeight,
              child: _SourceCardPrimaryRow(
                height: primaryHeight,
                server: source.serverAddress,
                selected: selected,
                title: title,
                subtitle: subtitle,
                titleStyle: titleStyle,
                subtitleStyle: subtitleStyle,
                subtitleMaxLines: 2,
                titleMetrics: titleMetrics,
                subtitleMetrics: subtitleMetrics,
                trailing: SizedBox(
                  width: actionRowWidth,
                  height: 34,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      if (showPingResult) ...<Widget>[
                        _TcpPingResultLabel(milliseconds: tcpPingLatency),
                        const SizedBox(width: 8),
                      ],
                      if (showSourceState) ...<Widget>[
                        _SourceCardSelectionIndicator(
                          selected: selected,
                          updating: source.isUpdating,
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (showAbout) ...<Widget>[
                        _AboutSubscriptionButton(
                          strings: strings,
                          source: source,
                        ),
                        const SizedBox(width: 6),
                      ],
                      _SourceMenuButton(
                        controller: controller,
                        strings: strings,
                        source: source,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (source.lastUpdateError != null) ...<Widget>[
              const SizedBox(height: 10),
              _SourceUpdateErrorBanner(message: source.lastUpdateError!),
            ],
            if (hasTrafficUsage) ...<Widget>[
              const SizedBox(height: 8),
              _SubscriptionTrafficUsageBar(
                usage: trafficUsage,
                strings: strings,
              ),
            ],
            if (hasProfileDropdown) ...<Widget>[
              const SizedBox(height: 14),
              _ProfileDropdown(
                controller: controller,
                strings: strings,
                source: source,
              ),
            ],
            if (hasExtraContent) SizedBox(height: extraContentBottomPadding),
          ],
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown: (details) => unawaited(
            sourceMenu.showAtCursor(context, details.globalPosition),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: controller.canEditSources
                  ? () => controller.selectSource(source.id)
                  : null,
              child: Ink(
                key: cardKey,
                padding: const EdgeInsets.fromLTRB(18, 0, 14, 0),
                decoration: BoxDecoration(
                  color: selected
                      ? selectedConfigSurfaceColor(scheme)
                      : scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: body,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProfileDropdown extends StatelessWidget {
  const _ProfileDropdown({
    required this.controller,
    required this.strings,
    required this.source,
  });

  final VpnController controller;
  final AppStrings strings;
  final ConfigSource source;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DropdownMenu<int>(
          key: ValueKey<String>(
            '${source.id}:${source.selectedProfileIndex}:${source.profiles.length}',
          ),
          width: constraints.maxWidth,
          enabled: controller.canEditSources,
          initialSelection: source.selectedProfileIndex,
          label: Text(strings.profileSelectorLabel),
          helperText: strings.profileSelectorHelper(source.profiles.length),
          dropdownMenuEntries: <DropdownMenuEntry<int>>[
            for (var i = 0; i < source.profiles.length; i += 1)
              DropdownMenuEntry<int>(
                value: i,
                label: profileOptionLabel(strings, source.profiles[i]),
              ),
          ],
          onSelected: (value) {
            if (value != null) {
              controller.setSelectedProfileIndex(value);
            }
          },
        );
      },
    );
  }
}

class _SubscriptionTrafficUsageBar extends StatelessWidget {
  const _SubscriptionTrafficUsageBar({
    super.key,
    required this.usage,
    required this.strings,
  });

  final SubscriptionTrafficUsage usage;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final ratio = usage.usageRatio;
    final totalBytes = usage.totalBytes;
    if (ratio == null || totalBytes == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const fillColor = connectedColor;
    final usedLabel = formatTrafficBytes(usage.usedBytes);
    final totalLabel = formatTrafficBytes(totalBytes);
    final percentLabel = '${(ratio * 100).round().clamp(0, 100)}%';
    final usageLabel = strings.subscriptionTrafficUsedOf(usedLabel, totalLabel);
    final semanticValue = <String>[usageLabel, percentLabel].join(', ');
    const barHeight = 24.0;
    final barLabelStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'Trebuchet MS',
      color: Colors.white,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      height: 1,
      letterSpacing: 0,
      shadows: <Shadow>[
        Shadow(
          color: Colors.black.withValues(alpha: 0.36),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ],
    );

    return Semantics(
      label: strings.subscriptionTrafficLabel,
      value: semanticValue,
      child: SizedBox(
        height: barHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final rawWidth = constraints.maxWidth * ratio;
            final minVisibleWidth = constraints.maxWidth < 4
                ? constraints.maxWidth
                : math.min(barHeight, constraints.maxWidth);
            final fillWidth = ratio <= 0
                ? 0.0
                : rawWidth
                      .clamp(minVisibleWidth, constraints.maxWidth)
                      .toDouble();

            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: trafficBarTrackColor(scheme),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  width: fillWidth,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: LinearGradient(
                      colors: <Color>[
                        fillColor.withValues(alpha: 0.76),
                        fillColor,
                      ],
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Center(
                      child: Text(
                        usageLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: barLabelStyle,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AboutSubscriptionButton extends StatelessWidget {
  const _AboutSubscriptionButton({required this.strings, required this.source});

  final AppStrings strings;
  final ConfigSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: () => unawaited(
        _showAboutSubscriptionDialog(
          context,
          strings: strings,
          source: source,
        ),
      ),
      tooltip: strings.aboutSubscriptionAction,
      icon: const Icon(Icons.info_outline_rounded),
      iconSize: 21,
      style: _compactSourceIconButtonStyle(scheme),
    );
  }
}

Future<void> _showAboutSubscriptionDialog(
  BuildContext context, {
  required AppStrings strings,
  required ConfigSource source,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _AboutSubscriptionDialog(strings: strings, source: source),
  );
}

class _AboutSubscriptionDialog extends StatelessWidget {
  const _AboutSubscriptionDialog({required this.strings, required this.source});

  final AppStrings strings;
  final ConfigSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = <MapEntry<String, String>>[];
    final expiresLabel = sourceTrafficExpiryDateLabel(source);
    if (expiresLabel != null) {
      entries.add(
        MapEntry(strings.subscriptionExpiresLabel, expiresLabel),
      );
    }

    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.w600,
    );

    return AlertDialog(
      title: Text(strings.aboutSubscriptionDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final entry in entries) ...<Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(entry.key, style: labelStyle),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: valueStyle,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.closeAction),
        ),
      ],
    );
  }
}

class _SourceAutoUpdateMenuEntry extends PopupMenuEntry<SourceMenuAction> {
  const _SourceAutoUpdateMenuEntry({
    required this.source,
    required this.strings,
    required this.onChanged,
  });

  final ConfigSource source;
  final AppStrings strings;
  final ValueChanged<Duration> onChanged;

  @override
  double get height => 64;

  @override
  bool represents(SourceMenuAction? value) => false;

  @override
  State<_SourceAutoUpdateMenuEntry> createState() =>
      _SourceAutoUpdateMenuEntryState();
}

class _SourceAutoUpdateMenuEntryState
    extends State<_SourceAutoUpdateMenuEntry> {
  late int _minutes;

  @override
  void initState() {
    super.initState();
    _minutes = widget.source.normalizedAutoUpdateIntervalMinutes;
  }

  @override
  void didUpdateWidget(covariant _SourceAutoUpdateMenuEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id) {
      _minutes = widget.source.normalizedAutoUpdateIntervalMinutes;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final menuLabelStyle =
        (theme.popupMenuTheme.textStyle ??
                theme.textTheme.labelLarge ??
                const TextStyle())
            .copyWith(fontWeight: FontWeight.w600);
    final valueText = widget.strings.autoUpdateIntervalValue(
      Duration(minutes: _minutes),
    );

    return SizedBox(
      width: 224,
      height: widget.height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.timer_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FittedBox(
                    alignment: Alignment.centerLeft,
                    fit: BoxFit.scaleDown,
                    child: Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: widget.strings.autoUpdateLabel,
                            style: menuLabelStyle.copyWith(
                              color: scheme.onSurface,
                            ),
                          ),
                          TextSpan(
                            text: ' $valueText',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 28,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  padding: EdgeInsets.zero,
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 10,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 15,
                  ),
                ),
                child: Slider(
                  min: minSubscriptionAutoUpdateMinutes.toDouble(),
                  max: maxSubscriptionAutoUpdateMinutes.toDouble(),
                  divisions:
                      (maxSubscriptionAutoUpdateMinutes -
                          minSubscriptionAutoUpdateMinutes) ~/
                      subscriptionAutoUpdateStepMinutes,
                  value: _minutes
                      .clamp(
                        minSubscriptionAutoUpdateMinutes,
                        maxSubscriptionAutoUpdateMinutes,
                      )
                      .toDouble(),
                  label: valueText,
                  onChanged: _handleSliderChanged,
                  onChangeEnd: _handleSliderChangeEnd,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleSliderChanged(double value) {
    final minutes = normalizeSubscriptionAutoUpdateMinutes(value.round());
    if (_minutes == minutes) {
      return;
    }
    setState(() {
      _minutes = minutes;
    });
  }

  void _handleSliderChangeEnd(double value) {
    final minutes = normalizeSubscriptionAutoUpdateMinutes(value.round());
    widget.onChanged(Duration(minutes: minutes));
  }
}
