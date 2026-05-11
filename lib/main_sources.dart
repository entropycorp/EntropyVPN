part of 'main.dart';

class _QuickSwitchPanel extends StatelessWidget {
  const _QuickSwitchPanel({
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
    final isMobile = MediaQuery.sizeOf(context).width < _mobileShellBreakpoint;
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
  late int _currentPage;
  String? _lastSelectedSourceId;

  @override
  void initState() {
    super.initState();
    _currentPage = _selectedSourceIndex;
    _lastSelectedSourceId = widget.controller.selectedSource?.id;
  }

  @override
  void didUpdateWidget(covariant _DesktopSourcePager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectedId = widget.controller.selectedSource?.id;
    if (selectedId != _lastSelectedSourceId) {
      _lastSelectedSourceId = selectedId;
      _showPage(_selectedSourceIndex);
      return;
    }

    if (widget.controller.sources.isEmpty) {
      return;
    }

    final clampedPage = _currentPage
        .clamp(0, widget.controller.sources.length - 1)
        .toInt();
    if (clampedPage != _currentPage) {
      _showPage(clampedPage);
    }
  }

  int get _selectedSourceIndex {
    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      return 0;
    }

    final selectedId = widget.controller.selectedSource?.id;
    final index = sources.indexWhere((source) => source.id == selectedId);
    return index < 0 ? 0 : index;
  }

  void _showPage(int index) {
    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      return;
    }

    final targetPage = index.clamp(0, sources.length - 1).toInt();
    if (targetPage == _currentPage) {
      return;
    }

    setState(() {
      _currentPage = targetPage;
    });
  }

  void _handlePageSelected(int index) {
    if (index < 0 || index >= widget.controller.sources.length) {
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

    final pageIndex = _currentPage.clamp(0, sources.length - 1).toInt();
    final source = sources[pageIndex];
    final hasPager = sources.length > 1;
    final minHeight = hasPager
        ? _desktopSourceRailStackHeight(sources.length)
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
                top: _desktopSourceRailTopInset,
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

const double _desktopSourceRailTopInset = 0;
const double _desktopSourceRailItemSize = 34;
const double _desktopSourceRailItemRadius = _desktopSourceRailItemSize / 2;
const double _desktopSourceRailItemGap = 4;
const double _desktopSourceRailVerticalPadding = 6;

double _desktopSourceRailStackHeight(int sourceCount) {
  if (sourceCount <= 0) {
    return 0;
  }
  return _desktopSourceRailTopInset +
      _desktopSourceRailVerticalPadding * 2 +
      sourceCount * _desktopSourceRailItemSize +
      math.max(0, sourceCount - 1) * _desktopSourceRailItemGap;
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
          vertical: _desktopSourceRailVerticalPadding,
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
                    message: _sourceSubscriptionTitle(source),
                    child: InkResponse(
                      key: ValueKey<String>('desktop-source-page-dot-$i'),
                      radius: 20,
                      onTap: () => onSelected(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        width: _desktopSourceRailItemSize,
                        height: _desktopSourceRailItemSize,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _selectedConfigSurfaceColor(scheme)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(
                            _desktopSourceRailItemRadius,
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
                const SizedBox(height: _desktopSourceRailItemGap),
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
  late int _currentPage;
  String? _lastSelectedSourceId;
  double _sourceDragDx = 0;
  bool _isDraggingPastLastPage = false;

  @override
  void initState() {
    super.initState();
    _currentPage = _selectedSourceIndex;
    _lastSelectedSourceId = widget.controller.selectedSource?.id;
    _pageController = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(covariant _MobileSourcePager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectedId = widget.controller.selectedSource?.id;
    if (selectedId != _lastSelectedSourceId) {
      _lastSelectedSourceId = selectedId;
      _showPage(_selectedSourceIndex);
      return;
    }

    if (widget.controller.sources.isEmpty) {
      return;
    }

    final clampedPage = _currentPage
        .clamp(0, widget.controller.sources.length - 1)
        .toInt();
    if (clampedPage != _currentPage) {
      _showPage(clampedPage);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  int get _selectedSourceIndex {
    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      return 0;
    }

    final selectedId = widget.controller.selectedSource?.id;
    final index = sources.indexWhere((source) => source.id == selectedId);
    return index < 0 ? 0 : index;
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
        duration: _mobilePageTransitionDuration,
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showPage(int index) {
    if (widget.controller.sources.isEmpty) {
      return;
    }

    final targetPage = index
        .clamp(0, widget.controller.sources.length - 1)
        .toInt();
    if (targetPage == _currentPage) {
      return;
    }

    setState(() {
      _currentPage = targetPage;
    });
    _syncPage(targetPage);
  }

  void _handlePageChanged(int index) {
    if (index < 0 || index >= widget.controller.sources.length) {
      return;
    }
    setState(() {
      _currentPage = index;
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

    final pageIndex = _currentPage.clamp(0, sources.length - 1).toInt();
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
    if (velocityDx.abs() >= _mobileSourcePagerSwipeVelocityThreshold) {
      direction = velocityDx < 0 ? -1 : 1;
    } else if (_sourceDragDx.abs() >=
        _mobileSourcePagerSwipeDistanceThreshold) {
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

    final pageIndex = _currentPage.clamp(0, sources.length - 1).toInt();
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

    const pagePhysics = _ProgrammaticPageSwipePhysics();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pageIndex = _currentPage.clamp(0, sources.length - 1).toInt();
          final availableWidth = constraints.maxWidth;
          final pageHeight = _mobileSourcePageHeight(
            context,
            sources[pageIndex],
            controller: widget.controller,
            strings: widget.strings,
            maxWidth: availableWidth,
          );

          if (widget.fillSwipeArea) {
            final pagerHeaderHeight = sources.length > 1
                ? _mobileSourcePagerHeaderHeight
                : 0.0;
            final minHeight = _mobileSourcePagerMinHeight(
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
                const SizedBox(height: _mobileSourcePagerDotGap),
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
              height: _mobileSourcePageHeight(
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

const double _mobileSourcePagerDotGap = 10;
const double _mobileSourcePagerDotHeight = 6;
const double _mobileSourcePagerHeaderHeight =
    _mobileSourcePagerDotHeight + _mobileSourcePagerDotGap;
const double _mobileSourcePagerSwipeDistanceThreshold = 56;
const double _mobileSourcePagerSwipeVelocityThreshold = 500;
const double _mobileProfileCardHeight = 72;
const double _mobileProfileCardSpacing = 10;
const double _mobileSubscriptionPanelPadding = 8;
const double _mobileSubscriptionHeaderLeftPadding = 0;
const double _mobileSubscriptionHeaderRightPadding = 0;
const double _mobileSubscriptionHeaderBottomPadding = 6;
const double _mobileSubscriptionHeaderIconSize = 38;
const double _mobileSubscriptionHeaderIconGap = 10;
// Place the header row by baseline so font metrics, not paragraph-box centering,
// determine how the text sits against the 38px subscription icon.
const double _mobileSubscriptionHeaderTextBaseline = 21;
const double _mobileSubscriptionHeaderGap = 6;
const double _mobileSubscriptionTrafficTopGap = 5;
const double _mobileSubscriptionTrafficProfileGap = 11;
const double _mobileConfigCardVerticalPadding = 12;
const double _mobileConfigCardMinHeight = 72;
const double _desktopConfigCardMinHeight = 74;
const double _configCardMinSegmentGap = 4;
const double _configCardFlagSize = 32;
const double _configCardFlagWidth =
    _configCardFlagSize * defaultFlagAspectRatio;
const double _configCardFlagGap = 10;
const TextHeightBehavior _configCardTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: false,
  applyHeightToLastDescent: false,
);
const double _mobileProfileSubtitleFontSize = 13;
const double _compactSourceActionSize = 34;
const double _compactSourceActionGap = 3;
const double _mobileSubscriptionHeaderActionWidth =
    _compactSourceActionSize * 3 + _compactSourceActionGap * 2;

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
          padding: const EdgeInsets.all(_mobileSubscriptionPanelPadding),
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
                const SizedBox(height: _mobileSubscriptionTrafficTopGap),
                _SubscriptionTrafficUsageBar(
                  key: ValueKey<String>('subscription-traffic-${source.id}'),
                  usage: trafficUsage,
                  strings: strings,
                  showExpiryDate: false,
                ),
              ],
              if (!desktop || source.profiles.isNotEmpty) ...<Widget>[
                SizedBox(
                  height: trafficUsage != null && trafficUsage.hasTotal
                      ? _mobileSubscriptionTrafficProfileGap
                      : _mobileSubscriptionHeaderGap,
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
          const SizedBox(height: _mobileProfileCardSpacing),
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
          const SizedBox(height: _mobileProfileCardSpacing),
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
    final title = _sourceSubscriptionTitle(source);
    final expiresLabel = _sourceTrafficExpiryDateLabel(source);
    final titleStyle = _subscriptionHeaderTitleStyle(theme);
    final expiresStyle = _subscriptionHeaderExpiryStyle(theme, scheme);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _mobileSubscriptionHeaderLeftPadding,
        0,
        _mobileSubscriptionHeaderRightPadding,
        _mobileSubscriptionHeaderBottomPadding,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: _mobileSubscriptionHeaderIconSize,
            height: _mobileSubscriptionHeaderIconSize,
            decoration: BoxDecoration(
              color: selected
                  ? _selectedConfigSurfaceColor(scheme)
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
          const SizedBox(width: _mobileSubscriptionHeaderIconGap),
          Expanded(
            child: SizedBox(
              height: _mobileSubscriptionHeaderIconSize,
              child: Baseline(
                baseline: _mobileSubscriptionHeaderTextBaseline,
                baselineType: TextBaseline.alphabetic,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                        textHeightBehavior:
                            _subscriptionHeaderTextHeightBehavior,
                      ),
                    ),
                    if (expiresLabel != null) ...<Widget>[
                      const SizedBox(width: 8),
                      Text(
                        '|',
                        style: expiresStyle,
                        textHeightBehavior:
                            _subscriptionHeaderTextHeightBehavior,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          expiresLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: expiresStyle,
                          textHeightBehavior:
                              _subscriptionHeaderTextHeightBehavior,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: _mobileSubscriptionHeaderActionWidth,
            height: _compactSourceActionSize,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                SizedBox(
                  width: _compactSourceActionSize,
                  height: _compactSourceActionSize,
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
                const SizedBox(width: _compactSourceActionGap),
                _SourcePingButton(
                  controller: controller,
                  strings: strings,
                  source: source,
                ),
                const SizedBox(width: _compactSourceActionGap),
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
    final cardHeight = _mobileProfileCardHeightFor(context);
    final title = _profileChoiceTitle(profile);
    final subtitle = _sourceSubtitle(strings, core, profile);
    final titleStyle = _configCardTitleStyle(theme);
    final subtitleStyle = _configCardSubtitleStyle(
      theme,
      scheme,
    )?.copyWith(fontSize: _mobileProfileSubtitleFontSize);
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
                ? _selectedConfigSurfaceColor(scheme)
                : scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Transform.translate(
                offset: const Offset(-3, -8),
                child: _ServerFlagBadge(
                  key: ValueKey<String>(
                    'mobile-profile-flag-${source.id}-$profileIndex',
                  ),
                  server: profile.server,
                  selected: selected,
                  size: _configCardFlagSize,
                ),
              ),
              const SizedBox(width: _configCardFlagGap),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final textWidth = constraints.maxWidth
                        .clamp(64.0, double.infinity)
                        .toDouble();
                    final titleMetrics = _measuredTextVisualMetrics(
                      context,
                      title,
                      titleStyle,
                      maxWidth: textWidth,
                      maxLines: 1,
                      textHeightBehavior: _configCardTextHeightBehavior,
                    );
                    final subtitleMetrics = _measuredTextVisualMetrics(
                      context,
                      subtitle,
                      subtitleStyle,
                      maxWidth: textWidth,
                      maxLines: 1,
                      textHeightBehavior: _configCardTextHeightBehavior,
                    );
                    final titleCenterY = cardHeight / 3;
                    final subtitleCenterY = cardHeight * 2 / 3;

                    return SizedBox(
                      height: cardHeight,
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
                              textHeightBehavior: _configCardTextHeightBehavior,
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top:
                                subtitleCenterY - subtitleMetrics.visualCenterY,
                            right: 0,
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: subtitleStyle,
                              textHeightBehavior: _configCardTextHeightBehavior,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              if (showPingResult) ...<Widget>[
                _TcpPingResultLabel(milliseconds: tcpPingLatency),
                const SizedBox(width: 8),
              ],
              SizedBox(
                width: 34,
                height: 34,
                child: Center(
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 22,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ),
              ),
            ],
          ),
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

  List<PopupMenuEntry<_SourceMenuAction>> items(BuildContext context) {
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
    final items = <PopupMenuEntry<_SourceMenuAction>>[];

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
      PopupMenuItem<_SourceMenuAction>(
        value: _SourceMenuAction.exportJson,
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
      PopupMenuItem<_SourceMenuAction>(
        value: _SourceMenuAction.delete,
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

  void handleAction(BuildContext context, _SourceMenuAction action) {
    switch (action) {
      case _SourceMenuAction.exportJson:
        unawaited(_exportJson(context));
        break;
      case _SourceMenuAction.delete:
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
    final action = await showMenu<_SourceMenuAction>(
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
        fileName: _sourceJsonFileName(source),
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
      width: _compactSourceActionSize,
      height: _compactSourceActionSize,
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
    fixedSize: const Size(_compactSourceActionSize, _compactSourceActionSize),
    minimumSize: const Size(_compactSourceActionSize, _compactSourceActionSize),
    maximumSize: const Size(_compactSourceActionSize, _compactSourceActionSize),
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
    final isMobile = MediaQuery.sizeOf(context).width < _mobileShellBreakpoint;
    final showSourceState =
        source.isUpdating || !(isMobile && source.hasMultipleProfiles);
    final tcpPingLatency = source.tcpPingLatencyForProfile(
      source.selectedProfileIndex,
    );
    final showPingResult = tcpPingLatency != null;
    final actionRowWidth =
        34.0 + (showSourceState ? 40.0 : 0.0) + (showPingResult ? 72.0 : 0.0);
    final title = _sourceHeadline(source, profile);
    final subtitle = _sourceSubtitle(
      strings,
      controller.displayCoreForProfile(profile),
      profile,
    );
    final titleStyle = _configCardTitleStyle(theme);
    final subtitleStyle = _configCardSubtitleStyle(theme, scheme);
    final minPrimaryHeight = isMobile
        ? _mobileConfigCardMinHeight
        : _desktopConfigCardMinHeight;
    final extraContentBottomPadding = isMobile
        ? _mobileConfigCardVerticalPadding
        : 18.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final textWidth =
            (availableWidth -
                    18 -
                    _configCardFlagWidth -
                    _configCardFlagGap -
                    14 -
                    14 -
                    actionRowWidth)
                .clamp(64.0, double.infinity)
                .toDouble();
        final titleMetrics = _measuredTextVisualMetrics(
          context,
          title,
          titleStyle,
          maxWidth: textWidth,
          maxLines: 1,
          textHeightBehavior: _configCardTextHeightBehavior,
        );
        final subtitleMetrics = _measuredTextVisualMetrics(
          context,
          subtitle,
          subtitleStyle,
          maxWidth: textWidth,
          maxLines: 2,
          textHeightBehavior: _configCardTextHeightBehavior,
        );
        final primaryHeight = _configCardPrimaryHeight(
          minHeight: minPrimaryHeight,
          titleHeight: titleMetrics.visualHeight,
          subtitleHeight: subtitleMetrics.visualHeight,
        );
        final titleCenterY = primaryHeight / 3;
        final subtitleCenterY = primaryHeight * 2 / 3;
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  _ServerFlagBadge(
                    server: source.serverAddress,
                    selected: selected,
                    size: _configCardFlagSize,
                  ),
                  const SizedBox(width: _configCardFlagGap),
                  Expanded(
                    child: SizedBox(
                      height: primaryHeight,
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
                              textHeightBehavior: _configCardTextHeightBehavior,
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top:
                                subtitleCenterY - subtitleMetrics.visualCenterY,
                            right: 0,
                            child: Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: subtitleStyle,
                              textHeightBehavior: _configCardTextHeightBehavior,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  SizedBox(
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
                          SizedBox(
                            width: 34,
                            height: 34,
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
                                  : Icon(
                                      selected
                                          ? Icons.check_circle_rounded
                                          : Icons
                                                .radio_button_unchecked_rounded,
                                      size: 22,
                                      color: selected
                                          ? scheme.primary
                                          : scheme.outline,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Builder(
                          builder: (buttonContext) {
                            return IconButton(
                              onPressed: () => unawaited(
                                sourceMenu.showAtButton(buttonContext),
                              ),
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).showMenuTooltip,
                              icon: const Icon(Icons.more_horiz_rounded),
                              iconSize: 22,
                              style: _compactSourceIconButtonStyle(scheme),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
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
                      ? _selectedConfigSurfaceColor(scheme)
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
                label: _profileOptionLabel(strings, source.profiles[i]),
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
    this.showExpiryDate = true,
  });

  final SubscriptionTrafficUsage usage;
  final AppStrings strings;
  final bool showExpiryDate;

  @override
  Widget build(BuildContext context) {
    final ratio = usage.usageRatio;
    final totalBytes = usage.totalBytes;
    if (ratio == null || totalBytes == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const fillColor = _connectedColor;
    final usedLabel = _formatTrafficBytes(usage.usedBytes);
    final totalLabel = _formatTrafficBytes(totalBytes);
    final expiresLabel = !showExpiryDate || usage.expiresAt == null
        ? null
        : _formatCompactDate(usage.expiresAt!);
    final percentLabel = '${(ratio * 100).round().clamp(0, 100)}%';
    final usageLabel = strings.subscriptionTrafficUsedOf(usedLabel, totalLabel);
    final semanticValue = <String>[
      usageLabel,
      percentLabel,
      if (expiresLabel != null)
        strings.subscriptionTrafficExpires(expiresLabel),
    ].join(', ');
    const barHeight = 24.0;
    final detailStyle = _subscriptionTrafficExpiryStyle(theme, scheme);
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
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
                          color: _trafficBarTrackColor(scheme),
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
          if (expiresLabel != null) ...<Widget>[
            const SizedBox(height: 7),
            _SubscriptionTrafficExpiryDate(
              dateLabel: expiresLabel,
              style: detailStyle,
            ),
          ],
        ],
      ),
    );
  }
}

const double _subscriptionTrafficExpiryIconSize = 13;
const double _subscriptionTrafficExpiryIconGap = 4;

class _SubscriptionTrafficExpiryDate extends StatelessWidget {
  const _SubscriptionTrafficExpiryDate({
    required this.dateLabel,
    required this.style,
  });

  final String dateLabel;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = style?.color ?? scheme.onSurface;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(
          Icons.calendar_today_outlined,
          size: _subscriptionTrafficExpiryIconSize,
          color: color,
        ),
        const SizedBox(width: _subscriptionTrafficExpiryIconGap),
        Expanded(
          child: Text(
            dateLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

class _SourceAutoUpdateMenuEntry extends PopupMenuEntry<_SourceMenuAction> {
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
  bool represents(_SourceMenuAction? value) => false;

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
