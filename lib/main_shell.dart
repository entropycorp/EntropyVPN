import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_strings.dart';
import 'main_connect.dart';
import 'main_constants.dart';
import 'main_flags.dart';
import 'main_pages.dart';
import 'services/vpn_controller.dart';

const _brandImagePath = 'entropylogo.png';
const _brandImageScale = 0.86;

enum _HomeSection { connect, add, settings, logs }

class _ReturnToMainSectionIntent extends Intent {
  const _ReturnToMainSectionIntent();
}

const _homeSections = <_HomeSection>[
  _HomeSection.connect,
  _HomeSection.add,
  _HomeSection.settings,
  _HomeSection.logs,
];

final _mobilePageSwipeSpring = SpringDescription.withDurationAndBounce(
  duration: mobilePageTransitionDuration,
);

class VpnHomePage extends StatefulWidget {
  const VpnHomePage({super.key, required this.controller});

  final VpnController controller;

  @override
  State<VpnHomePage> createState() => _VpnHomePageState();
}

class _VpnHomePageState extends State<VpnHomePage> {
  late final TextEditingController _textController;
  late final FocusNode _windowsShortcutFocusNode;
  late _HomeSection _section;
  late final bool _startedWithoutSources;
  bool _didAutoSwitchAfterRestore = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.controller.rawInput);
    _windowsShortcutFocusNode = FocusNode(
      debugLabel: 'Windows return-to-main shortcuts',
    );
    _textController.addListener(_handleTextChanged);
    widget.controller.addListener(_handleControllerUpdated);
    _startedWithoutSources = !widget.controller.hasSources;
    _section = widget.controller.hasSources
        ? _HomeSection.connect
        : _HomeSection.add;
  }

  @override
  void didUpdateWidget(covariant VpnHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_textController.text != widget.controller.rawInput) {
      _textController.text = widget.controller.rawInput;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerUpdated);
    _textController
      ..removeListener(_handleTextChanged)
      ..dispose();
    _windowsShortcutFocusNode.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (_textController.text != widget.controller.rawInput) {
      widget.controller.setRawInput(_textController.text);
    }
  }

  void _handleControllerUpdated() {
    if ((_section != _HomeSection.add) &&
        (widget.controller.isAddingSource ||
            widget.controller.rawInput.trim().isNotEmpty) &&
        mounted) {
      setState(() {
        _section = _HomeSection.add;
      });
      return;
    }
    if (_startedWithoutSources &&
        !_didAutoSwitchAfterRestore &&
        widget.controller.hasSources &&
        mounted) {
      _didAutoSwitchAfterRestore = true;
      setState(() {
        _section = _HomeSection.connect;
      });
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _setSection(_HomeSection section) {
    if (_section == section) {
      return;
    }
    setState(() {
      _section = section;
    });
  }

  void _handleReturnToMainSection() {
    if (_section == _HomeSection.connect) {
      return;
    }
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != _windowsShortcutFocusNode) {
      primaryFocus?.unfocus();
    }
    _setSection(_HomeSection.connect);
    _restoreWindowsShortcutFocus();
  }

  void _restoreWindowsShortcutFocus() {
    if (!Platform.isWindows) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _windowsShortcutFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final controller = widget.controller;
    final scheme = Theme.of(context).colorScheme;

    final page = Scaffold(
      body: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: appBackgroundColor),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final shellPadding = constraints.maxWidth >= 1700
                    ? 28.0
                    : constraints.maxWidth >= 1300
                    ? 20.0
                    : 16.0;
                if (constraints.maxWidth < mobileShellBreakpoint) {
                  return _MobileShell(
                    selected: _section,
                    controller: controller,
                    strings: strings,
                    onChanged: _setSection,
                    textController: _textController,
                  );
                }

                final sectionContent = _SectionContentSwitcher(
                  section: _section,
                  controller: controller,
                  strings: strings,
                  textController: _textController,
                );

                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    0,
                    0,
                    shellPadding,
                    shellPadding,
                  ),
                  child: SizedBox.expand(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surface.withValues(alpha: 0.84),
                        borderRadius: BorderRadius.circular(36),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.24),
                            blurRadius: 48,
                            offset: const Offset(0, 22),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 24, 24),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final compactShell = constraints.maxWidth < 760;
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                _SectionSelector(
                                  selected: _section,
                                  compact: compactShell,
                                  onChanged: _setSection,
                                ),
                                SizedBox(width: compactShell ? 14 : 22),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 22),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: LanguageSelector(
                                            controller: controller,
                                            strings: strings,
                                          ),
                                        ),
                                        SizedBox(
                                          height: compactShell ? 14 : 20,
                                        ),
                                        Expanded(child: sectionContent),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    if (!Platform.isWindows) {
      return page;
    }

    return FocusableActionDetector(
      autofocus: true,
      focusNode: _windowsShortcutFocusNode,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape):
            _ReturnToMainSectionIntent(),
      },
      actions: <Type, Action<Intent>>{
        _ReturnToMainSectionIntent: CallbackAction<_ReturnToMainSectionIntent>(
          onInvoke: (_) {
            _handleReturnToMainSection();
            return null;
          },
        ),
      },
      child: page,
    );
  }
}

class _MobileShell extends StatefulWidget {
  const _MobileShell({
    required this.selected,
    required this.controller,
    required this.strings,
    required this.onChanged,
    required this.textController,
  });

  final _HomeSection selected;
  final VpnController controller;
  final AppStrings strings;
  final ValueChanged<_HomeSection> onChanged;
  final TextEditingController textController;

  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  late final PageController _pageController;
  int? _programmaticPageTarget;
  int? _sourceOverflowDragStartIndex;
  int _pageSyncGeneration = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: _homeSections.indexOf(widget.selected),
    );
  }

  @override
  void didUpdateWidget(covariant _MobileShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _syncPageToSelected();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _syncPageToSelected() {
    final targetIndex = _homeSections.indexOf(widget.selected);

    void animateWhenReady() {
      if (!mounted || !_pageController.hasClients) {
        return;
      }
      final currentPage = _pageController.page;
      if (currentPage != null && currentPage.round() == targetIndex) {
        _programmaticPageTarget = null;
        return;
      }
      final syncGeneration = ++_pageSyncGeneration;
      _programmaticPageTarget = targetIndex;
      _pageController
          .animateToPage(
            targetIndex,
            duration: mobilePageTransitionDuration,
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted || syncGeneration != _pageSyncGeneration) {
              return;
            }
            _programmaticPageTarget = null;
          });
    }

    if (_pageController.hasClients) {
      animateWhenReady();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => animateWhenReady());
    }
  }

  void _handlePageChanged(int index) {
    if (index < 0 || index >= _homeSections.length) {
      return;
    }
    if (_sourceOverflowDragStartIndex != null) {
      return;
    }
    final programmaticPageTarget = _programmaticPageTarget;
    if (programmaticPageTarget != null) {
      if (index != programmaticPageTarget) {
        return;
      }
      _programmaticPageTarget = null;
    }
    widget.onChanged(_homeSections[index]);
  }

  void _handleConnectSourcePagerOverflow() {
    final currentIndex = _homeSections.indexOf(widget.selected);
    if (currentIndex < 0 || currentIndex >= _homeSections.length - 1) {
      return;
    }
    widget.onChanged(_homeSections[currentIndex + 1]);
  }

  void _handleConnectSourcePagerOverflowDragUpdate(double deltaDx) {
    if (!_pageController.hasClients) {
      return;
    }

    final currentIndex = _homeSections.indexOf(widget.selected);
    if (currentIndex < 0 || currentIndex >= _homeSections.length - 1) {
      return;
    }

    final startIndex = _sourceOverflowDragStartIndex ?? currentIndex;
    if (_sourceOverflowDragStartIndex == null) {
      _pageSyncGeneration += 1;
      _programmaticPageTarget = null;
      _sourceOverflowDragStartIndex = startIndex;
    }

    final position = _pageController.position;
    final viewport = position.viewportDimension;
    if (viewport <= 0) {
      return;
    }

    final startPixels = startIndex * viewport;
    final targetPixels = (startIndex + 1) * viewport;
    final nextPixels = (position.pixels - deltaDx)
        .clamp(startPixels, targetPixels)
        .toDouble();
    position.jumpTo(nextPixels);
  }

  void _handleConnectSourcePagerOverflowDragEnd(double velocityDx) {
    final startIndex = _sourceOverflowDragStartIndex;
    if (startIndex == null) {
      _handleConnectSourcePagerOverflow();
      return;
    }
    if (!_pageController.hasClients || startIndex >= _homeSections.length - 1) {
      _sourceOverflowDragStartIndex = null;
      return;
    }

    final position = _pageController.position;
    final viewport = position.viewportDimension;
    final draggedPixels = viewport <= 0
        ? 0.0
        : position.pixels - startIndex * viewport;
    final completeByVelocity =
        velocityDx <= -mobileSourcePagerSwipeVelocityThreshold;
    final cancelByVelocity =
        velocityDx >= mobileSourcePagerSwipeVelocityThreshold;
    final shouldComplete =
        completeByVelocity ||
        (!cancelByVelocity &&
            draggedPixels >= mobileSourcePagerSwipeDistanceThreshold);
    _settleConnectSourcePagerOverflowDrag(
      shouldComplete ? startIndex + 1 : startIndex,
    );
  }

  void _handleConnectSourcePagerOverflowDragCancel() {
    final startIndex = _sourceOverflowDragStartIndex;
    if (startIndex == null) {
      return;
    }
    _settleConnectSourcePagerOverflowDrag(startIndex);
  }

  void _settleConnectSourcePagerOverflowDrag(int targetIndex) {
    final startIndex = _sourceOverflowDragStartIndex;
    if (startIndex == null || !_pageController.hasClients) {
      _sourceOverflowDragStartIndex = null;
      return;
    }

    final clampedTargetIndex = targetIndex
        .clamp(0, _homeSections.length - 1)
        .toInt();
    final completesOverflow = clampedTargetIndex != startIndex;
    final syncGeneration = ++_pageSyncGeneration;
    _programmaticPageTarget = clampedTargetIndex;
    _pageController
        .animateToPage(
          clampedTargetIndex,
          duration: mobilePageTransitionDuration,
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          if (!mounted || syncGeneration != _pageSyncGeneration) {
            return;
          }
          _programmaticPageTarget = null;
          _sourceOverflowDragStartIndex = null;
          if (completesOverflow) {
            widget.onChanged(_homeSections[clampedTargetIndex]);
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pagePhysics = _FastPageSwipePhysics(
      parent: ScrollConfiguration.of(context).getScrollPhysics(context),
    );

    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.84)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Row(
                children: <Widget>[
                  const _BrandLogo(size: 74, radius: 24),
                  const Spacer(),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: LanguageSelector(
                          controller: widget.controller,
                          strings: widget.strings,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _MobileSectionSelector(
                selected: widget.selected,
                onChanged: widget.onChanged,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: PageView(
                  controller: _pageController,
                  physics: pagePhysics,
                  onPageChanged: _handlePageChanged,
                  children: <Widget>[
                    ConnectPageBody(
                      controller: widget.controller,
                      strings: widget.strings,
                      onSwipePastLastSource: _handleConnectSourcePagerOverflow,
                      onSwipePastLastSourceDragUpdate:
                          _handleConnectSourcePagerOverflowDragUpdate,
                      onSwipePastLastSourceDragEnd:
                          _handleConnectSourcePagerOverflowDragEnd,
                      onSwipePastLastSourceDragCancel:
                          _handleConnectSourcePagerOverflowDragCancel,
                    ),
                    AddSourcePageBody(
                      controller: widget.controller,
                      strings: widget.strings,
                      textController: widget.textController,
                    ),
                    SettingsPageBody(
                      controller: widget.controller,
                      strings: widget.strings,
                    ),
                    LogsPageBody(
                      controller: widget.controller,
                      strings: widget.strings,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FastPageSwipePhysics extends ScrollPhysics {
  const _FastPageSwipePhysics({super.parent});

  @override
  _FastPageSwipePhysics applyTo(ScrollPhysics? ancestor) {
    return _FastPageSwipePhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => _mobilePageSwipeSpring;
}

class _SectionContentSwitcher extends StatelessWidget {
  const _SectionContentSwitcher({
    required this.section,
    required this.controller,
    required this.strings,
    required this.textController,
  });

  final _HomeSection section;
  final VpnController controller;
  final AppStrings strings;
  final TextEditingController textController;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        final children = <Widget>[...previousChildren];
        if (currentChild != null) {
          children.add(currentChild);
        }
        return Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: children,
        );
      },
      transitionBuilder: (child, animation) {
        final offsetAnimation = Tween<Offset>(
          begin: const Offset(0.02, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offsetAnimation, child: child),
        );
      },
      child: switch (section) {
        _HomeSection.connect => ConnectPageBody(
          key: const ValueKey<String>('connect'),
          controller: controller,
          strings: strings,
        ),
        _HomeSection.add => AddSourcePageBody(
          key: const ValueKey<String>('add'),
          controller: controller,
          strings: strings,
          textController: textController,
        ),
        _HomeSection.settings => SettingsPageBody(
          key: const ValueKey<String>('settings'),
          controller: controller,
          strings: strings,
        ),
        _HomeSection.logs => LogsPageBody(
          key: const ValueKey<String>('logs'),
          controller: controller,
          strings: strings,
        ),
      },
    );
  }
}

class _BrandLogo extends StatelessWidget {
  const _BrandLogo({required this.size, required this.radius});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: ColoredBox(
        color: appBackgroundColor,
        child: Transform.scale(
          scale: _brandImageScale,
          child: Image.asset(_brandImagePath, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _SectionSelector extends StatelessWidget {
  const _SectionSelector({
    required this.selected,
    required this.compact,
    required this.onChanged,
  });

  final _HomeSection selected;
  final bool compact;
  final ValueChanged<_HomeSection> onChanged;

  @override
  Widget build(BuildContext context) {
    final railWidth = compact ? 82.0 : 112.0;
    final logoSize = compact ? 68.0 : 104.0;
    final logoRadius = compact ? 22.0 : 32.0;

    return SizedBox(
      width: railWidth,
      child: Padding(
        padding: EdgeInsets.only(bottom: compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _BrandLogo(size: logoSize, radius: logoRadius),
            SizedBox(height: compact ? 18 : 28),
            _SectionRailButton(
              icon: Icons.power_settings_new_rounded,
              selected: selected == _HomeSection.connect,
              compact: compact,
              onPressed: () => onChanged(_HomeSection.connect),
            ),
            SizedBox(height: compact ? 8 : 10),
            _SectionRailButton(
              icon: Icons.add_rounded,
              selected: selected == _HomeSection.add,
              compact: compact,
              onPressed: () => onChanged(_HomeSection.add),
            ),
            SizedBox(height: compact ? 8 : 10),
            _SectionRailButton(
              icon: Icons.settings_rounded,
              selected: selected == _HomeSection.settings,
              compact: compact,
              onPressed: () => onChanged(_HomeSection.settings),
            ),
            SizedBox(height: compact ? 8 : 10),
            _SectionRailButton(
              icon: Icons.receipt_long_outlined,
              selected: selected == _HomeSection.logs,
              compact: compact,
              onPressed: () => onChanged(_HomeSection.logs),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileSectionSelector extends StatelessWidget {
  const _MobileSectionSelector({
    required this.selected,
    required this.onChanged,
  });

  final _HomeSection selected;
  final ValueChanged<_HomeSection> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _MobileSectionButton(
            icon: Icons.power_settings_new_rounded,
            selected: selected == _HomeSection.connect,
            onPressed: () => onChanged(_HomeSection.connect),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MobileSectionButton(
            icon: Icons.add_rounded,
            selected: selected == _HomeSection.add,
            onPressed: () => onChanged(_HomeSection.add),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MobileSectionButton(
            icon: Icons.settings_rounded,
            selected: selected == _HomeSection.settings,
            onPressed: () => onChanged(_HomeSection.settings),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MobileSectionButton(
            icon: Icons.receipt_long_outlined,
            selected: selected == _HomeSection.logs,
            onPressed: () => onChanged(_HomeSection.logs),
          ),
        ),
      ],
    );
  }
}

class _MobileSectionButton extends StatelessWidget {
  const _MobileSectionButton({
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final indicatorColor = selected ? scheme.primary : Colors.transparent;
    final tileColor = _sectionButtonTileColor(scheme, selected);
    final iconColor = selected ? scheme.onSurface : scheme.onSurfaceVariant;

    return SizedBox(
      height: 50,
      child: Material(
        color: tileColor,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: selected ? null : onPressed,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Positioned(
                left: 18,
                right: 18,
                bottom: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  height: 3,
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              AnimatedScale(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                scale: selected ? 1.06 : 1,
                child: Icon(icon, size: 23, color: iconColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _sectionButtonTileColor(ColorScheme scheme, bool selected) {
  return selected
      ? scheme.surfaceContainerHighest.withValues(alpha: 0.9)
      : Colors.transparent;
}

class _SectionRailButton extends StatelessWidget {
  const _SectionRailButton({
    required this.icon,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });

  final IconData icon;
  final bool selected;
  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itemHeight = compact ? 46.0 : 52.0;
    final indicatorColor = selected ? scheme.primary : Colors.transparent;
    final tileColor = _sectionButtonTileColor(scheme, selected);
    final iconColor = selected ? scheme.onSurface : scheme.onSurfaceVariant;

    return SizedBox(
      height: itemHeight,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned(
            left: 0,
            top: 14,
            bottom: 14,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: 3,
              decoration: BoxDecoration(
                color: indicatorColor,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Positioned.fill(
            left: compact ? 6 : 8,
            child: Material(
              color: tileColor,
              borderRadius: BorderRadius.circular(compact ? 15 : 17),
              child: InkWell(
                borderRadius: BorderRadius.circular(compact ? 15 : 17),
                onTap: selected ? null : onPressed,
                child: Center(
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    scale: selected ? 1.06 : 1,
                    child: Icon(
                      icon,
                      size: compact ? 21 : 23,
                      color: iconColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
