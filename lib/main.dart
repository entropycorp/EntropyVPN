import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException, Platform;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:qr_code_dart_decoder/qr_code_dart_decoder.dart' as qrd;

import 'l10n/app_strings.dart';
import 'models/config_source.dart';
import 'models/split_tunnel.dart';
import 'models/vpn_profile.dart';
import 'services/config_source_export.dart';
import 'services/geo_ip_service.dart';
import 'services/vpn_controller.dart';
import 'utils/flag_aspect_ratio.dart';

const _brandImagePath = 'entropylogo.png';
const _brandImageScale = 0.86;
const _seedColor = Color(0xFFEDEDED);
const _connectedColor = Color(0xFF4CAF50);
const _appBackgroundColor = Color(0xFF000000);
const _mobileShellBreakpoint = 620.0;
const _splitPowerButtonDiameter = 196.0;
const _mobilePageTransitionDuration = Duration(milliseconds: 125);
const _qrImageFileExtensions = <String>[
  'png',
  'jpg',
  'jpeg',
  'bmp',
  'gif',
  'webp',
];

enum _HomeSection { connect, add, settings, logs }

enum _QrScanSource { gallery, camera, clipboardImage, imageFile }

const _homeSections = <_HomeSection>[
  _HomeSection.connect,
  _HomeSection.add,
  _HomeSection.settings,
  _HomeSection.logs,
];

final _mobilePageSwipeSpring = SpringDescription.withDurationAndBounce(
  duration: _mobilePageTransitionDuration,
);

enum _SourceMenuAction { exportJson, updateNow, delete }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: _appBackgroundColor,
      systemNavigationBarColor: _appBackgroundColor,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const EntropyVpnApp());
}

class EntropyVpnApp extends StatefulWidget {
  const EntropyVpnApp({super.key});

  @override
  State<EntropyVpnApp> createState() => _EntropyVpnAppState();
}

class _EntropyVpnAppState extends State<EntropyVpnApp> {
  late final VpnController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VpnController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'EntropyVPN',
          locale: _controller.language.locale,
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: _buildTheme(),
          home: VpnHomePage(controller: _controller),
        );
      },
    );
  }

  ThemeData _buildTheme() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ).copyWith(
          primary: Colors.white,
          onPrimary: Colors.black,
          primaryContainer: const Color(0xFFEDEDED),
          onPrimaryContainer: Colors.black,
          secondary: const Color(0xFFD6D6D6),
          onSecondary: Colors.black,
          secondaryContainer: const Color(0xFF242424),
          onSecondaryContainer: Colors.white,
          tertiary: const Color(0xFFBDBDBD),
          onTertiary: Colors.black,
          tertiaryContainer: const Color(0xFF2A2A2A),
          onTertiaryContainer: Colors.white,
          surface: _appBackgroundColor,
          onSurface: Colors.white,
          onSurfaceVariant: const Color(0xFFB8B8B8),
          surfaceContainerLowest: _appBackgroundColor,
          surfaceContainerLow: const Color(0xFF080808),
          surfaceContainer: const Color(0xFF101010),
          surfaceContainerHigh: const Color(0xFF161616),
          surfaceContainerHighest: const Color(0xFF1F1F1F),
          outline: const Color(0xFF666666),
          outlineVariant: const Color(0xFF333333),
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: _appBackgroundColor,
      fontFamily: 'SpaceGrotesk',
    );

    final textTheme = base.textTheme
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontSize: 31,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.45),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            height: 1.4,
            color: scheme.onSurfaceVariant,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          labelMedium: base.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        );

    final inputBorderSide = BorderSide(
      color: scheme.primary.withValues(alpha: 0.5),
      width: 1.25,
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(24),
      borderSide: inputBorderSide,
    );
    final focusedInputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(24),
      borderSide: inputBorderSide,
    );
    final errorInputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(24),
      borderSide: BorderSide(color: scheme.error.withValues(alpha: 0.56)),
    );

    return base.copyWith(
      textTheme: textTheme,
      dividerColor: scheme.outlineVariant,
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        fillColor: Colors.transparent,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        helperStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        disabledBorder: inputBorder,
        focusedBorder: focusedInputBorder,
        errorBorder: errorInputBorder,
        focusedErrorBorder: errorInputBorder,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          textStyle: textTheme.titleSmall,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: scheme.onSurface,
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
          textStyle: textTheme.titleSmall,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.28),
        thickness: 1,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        labelStyle: textTheme.labelMedium?.copyWith(
          fontFamily: 'JetBrainsMono',
          color: scheme.onSurface,
          letterSpacing: 0.2,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
    );
  }
}

class VpnHomePage extends StatefulWidget {
  const VpnHomePage({super.key, required this.controller});

  final VpnController controller;

  @override
  State<VpnHomePage> createState() => _VpnHomePageState();
}

class _VpnHomePageState extends State<VpnHomePage> {
  late final TextEditingController _textController;
  late _HomeSection _section;
  late final bool _startedWithoutSources;
  bool _didAutoSwitchAfterRestore = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.controller.rawInput);
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

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final controller = widget.controller;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: _EntropyBackdrop()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final shellPadding = constraints.maxWidth >= 1700
                    ? 28.0
                    : constraints.maxWidth >= 1300
                    ? 20.0
                    : 16.0;
                if (constraints.maxWidth < _mobileShellBreakpoint) {
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
                                          child: _LanguageSelector(
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
        return;
      }
      _pageController.animateToPage(
        targetIndex,
        duration: _mobilePageTransitionDuration,
        curve: Curves.easeOutCubic,
      );
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
    widget.onChanged(_homeSections[index]);
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
                        child: _LanguageSelector(
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
                    _ConnectPageBody(
                      controller: widget.controller,
                      strings: widget.strings,
                    ),
                    _AddSourcePageBody(
                      controller: widget.controller,
                      strings: widget.strings,
                      textController: widget.textController,
                    ),
                    _SettingsPageBody(
                      controller: widget.controller,
                      strings: widget.strings,
                    ),
                    _LogsPageBody(
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
        _HomeSection.connect => _ConnectPageBody(
          key: const ValueKey<String>('connect'),
          controller: controller,
          strings: strings,
        ),
        _HomeSection.add => _AddSourcePageBody(
          key: const ValueKey<String>('add'),
          controller: controller,
          strings: strings,
          textController: textController,
        ),
        _HomeSection.settings => _SettingsPageBody(
          key: const ValueKey<String>('settings'),
          controller: controller,
          strings: strings,
        ),
        _HomeSection.logs => _LogsPageBody(
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
        color: _appBackgroundColor,
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
    final tileColor = selected
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.9)
        : scheme.surfaceContainer;
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
    final tileColor = selected
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.9)
        : Colors.transparent;
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

class _ConnectPageBody extends StatefulWidget {
  const _ConnectPageBody({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_ConnectPageBody> createState() => _ConnectPageBodyState();
}

class _ConnectPageBodyState extends State<_ConnectPageBody> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useSplitLayout =
            widget.controller.hasSources && constraints.maxWidth >= 1080;
        final useMobileSourcePager =
            widget.controller.hasSources &&
            constraints.maxWidth < _mobileShellBreakpoint;

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
            child: _QuickSwitchPanel(
              controller: widget.controller,
              strings: widget.strings,
              fillMobileSwipeArea: useMobileSourcePager,
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
            padding: const EdgeInsets.only(right: 14),
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
            padding: EdgeInsets.only(left: 14, top: splitTopInset),
            child: _QuickSwitchPanel(
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

class _SettingsPageBody extends StatelessWidget {
  const _SettingsPageBody({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 520;
        final panelMaxWidth = constraints.maxWidth >= 1650
            ? 1120.0
            : constraints.maxWidth >= 1250
            ? 960.0
            : 760.0;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('settings-scroll'),
          padding: EdgeInsets.zero,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: panelMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (controller.supportsTrafficModeSelection) ...<Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isCompact ? 6 : 24,
                        vertical: isCompact ? 6 : 12,
                      ),
                      child: _TrafficModeSelector(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: isCompact ? 8 : 14),
                  ],
                  if (controller.supportsTunIpModeSelection) ...<Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isCompact ? 6 : 24,
                        vertical: isCompact ? 6 : 12,
                      ),
                      child: _TunIpModeSelector(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: isCompact ? 8 : 14),
                  ],
                  if (controller.supportsSplitTunneling) ...<Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isCompact ? 6 : 24,
                        vertical: isCompact ? 6 : 12,
                      ),
                      child: _SplitTunnelSettingsTile(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: isCompact ? 8 : 14),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AddSourcePageBody extends StatelessWidget {
  const _AddSourcePageBody({
    super.key,
    required this.controller,
    required this.strings,
    required this.textController,
  });

  final VpnController controller;
  final AppStrings strings;
  final TextEditingController textController;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelMaxWidth = constraints.maxWidth >= 1250 ? 820.0 : 720.0;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('add-source-scroll'),
          padding: EdgeInsets.zero,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: panelMaxWidth),
              child: _InputPanel(
                controller: controller,
                strings: strings,
                textController: textController,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LogsPageBody extends StatelessWidget {
  const _LogsPageBody({
    super.key,
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelMaxWidth = constraints.maxWidth >= 1650
            ? 1460.0
            : constraints.maxWidth >= 1250
            ? 1220.0
            : 1040.0;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('logs-scroll'),
          padding: EdgeInsets.zero,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: panelMaxWidth),
              child: _RuntimeLogsPanel(
                controller: controller,
                strings: strings,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QuickSwitchPanel extends StatelessWidget {
  const _QuickSwitchPanel({
    required this.controller,
    required this.strings,
    this.firstTileCardKey,
    this.fillMobileSwipeArea = false,
  });

  final VpnController controller;
  final AppStrings strings;
  final Key? firstTileCardKey;
  final bool fillMobileSwipeArea;

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < _mobileShellBreakpoint;
    if (isMobile) {
      return _MobileSourcePager(
        controller: controller,
        strings: strings,
        fillSwipeArea: fillMobileSwipeArea,
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

const double _desktopSourceRailTopInset = 8;
const double _desktopSourceRailItemSize = 34;
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
                        decoration: BoxDecoration(
                          color: isSelected
                              ? scheme.primary.withValues(alpha: 0.16)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected
                                ? scheme.primary.withValues(alpha: 0.68)
                                : Colors.transparent,
                          ),
                          boxShadow: isSelected
                              ? <BoxShadow>[
                                  BoxShadow(
                                    color: scheme.primary.withValues(
                                      alpha: 0.22,
                                    ),
                                    blurRadius: 10,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          source.isSubscription
                              ? Icons.link_rounded
                              : Icons.description_outlined,
                          size: 18,
                          color: isSelected
                              ? scheme.primary
                              : scheme.onSurfaceVariant.withValues(alpha: 0.82),
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
      return _DesktopSubscriptionProfilesPage(
        controller: controller,
        strings: strings,
        source: source,
        selected: selected,
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
  });

  final VpnController controller;
  final AppStrings strings;
  final bool fillSwipeArea;

  @override
  State<_MobileSourcePager> createState() => _MobileSourcePagerState();
}

class _MobileSourcePagerState extends State<_MobileSourcePager> {
  late final PageController _pageController;
  late int _currentPage;
  String? _lastSelectedSourceId;

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

  @override
  Widget build(BuildContext context) {
    final sources = widget.controller.sources;
    if (sources.isEmpty) {
      return const SizedBox.shrink();
    }

    final pagePhysics = widget.controller.canBrowseSources
        ? _FastPageSwipePhysics(
            parent: ScrollConfiguration.of(context).getScrollPhysics(context),
          )
        : const NeverScrollableScrollPhysics();

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
    return PageView.builder(
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
    );
  }

  Widget _buildSourcePage({
    required ConfigSource source,
    required bool selected,
  }) {
    if (source.isSubscription) {
      return _MobileSubscriptionProfilesPage(
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
const double _mobileProfileCardHeight = 72;
const double _mobileProfileCardSpacing = 10;
const double _mobileSubscriptionPanelPadding = 8;
const double _mobileSubscriptionHeaderVerticalPadding = 6;
const double _mobileSubscriptionHeaderGap = 6;
const double _mobileSubscriptionTrafficTopGap = 5;
const double _mobileSubscriptionTrafficProfileGap = 11;
const double _mobileConfigCardVerticalPadding = 12;
const double _mobileConfigCardMinHeight = 72;
const double _configCardFlagSize = 32;
const double _configCardFlagWidth =
    _configCardFlagSize * defaultFlagAspectRatio;
const double _configCardFlagGap = 12;

class _MobileSubscriptionProfilesPage extends StatelessWidget {
  const _MobileSubscriptionProfilesPage({
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
    final scheme = Theme.of(context).colorScheme;
    final trafficUsage = source.trafficUsage;

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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _SubscriptionTrafficUsageBar(
                  usage: trafficUsage,
                  strings: strings,
                ),
              ),
            ],
            SizedBox(
              height: trafficUsage != null && trafficUsage.hasTotal
                  ? _mobileSubscriptionTrafficProfileGap
                  : _mobileSubscriptionHeaderGap,
            ),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                physics: const BouncingScrollPhysics(),
                itemCount: source.profiles.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: _mobileProfileCardSpacing),
                itemBuilder: (context, index) {
                  return _MobileSubscriptionProfileCard(
                    controller: controller,
                    strings: strings,
                    source: source,
                    profileIndex: index,
                    selected: selected && source.selectedProfileIndex == index,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSubscriptionProfilesPage extends StatelessWidget {
  const _DesktopSubscriptionProfilesPage({
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
    final scheme = Theme.of(context).colorScheme;
    final trafficUsage = source.trafficUsage;

    return LayoutBuilder(
      builder: (context, constraints) {
        final containProfileScroll =
            constraints.maxHeight.isFinite && source.profiles.isNotEmpty;

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
              mainAxisSize: MainAxisSize.min,
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
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _SubscriptionTrafficUsageBar(
                      usage: trafficUsage,
                      strings: strings,
                    ),
                  ),
                ],
                if (source.profiles.isNotEmpty) ...<Widget>[
                  SizedBox(
                    height: trafficUsage != null && trafficUsage.hasTotal
                        ? _mobileSubscriptionTrafficProfileGap
                        : _mobileSubscriptionHeaderGap,
                  ),
                  if (containProfileScroll)
                    Flexible(child: _buildContainedProfileList())
                  else
                    ..._buildProfileCards(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContainedProfileList() {
    return Scrollbar(
      child: ListView.separated(
        key: PageStorageKey<String>(
          'desktop-subscription-profiles-${source.id}',
        ),
        primary: false,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const ClampingScrollPhysics(),
        itemCount: source.profiles.length,
        separatorBuilder: (context, index) =>
            const SizedBox(height: _mobileProfileCardSpacing),
        itemBuilder: (context, index) {
          return _MobileSubscriptionProfileCard(
            controller: controller,
            strings: strings,
            source: source,
            profileIndex: index,
            selected: selected && source.selectedProfileIndex == index,
            cardKey: index == 0 ? cardKey : null,
          );
        },
      ),
    );
  }

  List<Widget> _buildProfileCards() {
    return <Widget>[
      for (var i = 0; i < source.profiles.length; i += 1) ...<Widget>[
        _MobileSubscriptionProfileCard(
          controller: controller,
          strings: strings,
          source: source,
          profileIndex: i,
          selected: selected && source.selectedProfileIndex == i,
          cardKey: i == 0 ? cardKey : null,
        ),
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: controller.canEditSources
            ? () => controller.selectSource(source.id)
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            10,
            _mobileSubscriptionHeaderVerticalPadding,
            8,
            _mobileSubscriptionHeaderVerticalPadding,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.18)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.link_rounded,
                  size: 22,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 74,
                height: 34,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
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
                    const SizedBox(width: 6),
                    _SourceMenuButton(
                      controller: controller,
                      strings: strings,
                      source: source,
                      selected: selected,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
          height: _mobileProfileCardHeightFor(context),
          padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.32)
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _profileChoiceTitle(profile),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _sourceSubtitle(strings, core, profile),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
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

class _SourceMenuButton extends StatelessWidget {
  const _SourceMenuButton({
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
    final scheme = Theme.of(context).colorScheme;

    return Builder(
      builder: (buttonContext) {
        return IconButton(
          onPressed: () => _QuickSourceTile(
            controller: controller,
            strings: strings,
            source: source,
            selected: selected,
          )._showSourceMenuAtButton(buttonContext),
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          icon: const Icon(Icons.more_horiz_rounded),
          iconSize: 22,
          style: _compactSourceIconButtonStyle(scheme),
        );
      },
    );
  }
}

ButtonStyle _compactSourceIconButtonStyle(ColorScheme scheme) {
  return IconButton.styleFrom(
    fixedSize: const Size(34, 34),
    minimumSize: const Size(34, 34),
    maximumSize: const Size(34, 34),
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
    final profile = source.selectedProfile;
    final trafficUsage = source.trafficUsage;
    final isMobile = MediaQuery.sizeOf(context).width < _mobileShellBreakpoint;
    final showSourceState =
        source.isUpdating || !(isMobile && source.hasMultipleProfiles);
    final actionRowWidth = showSourceState ? 74.0 : 34.0;
    final verticalPadding = isMobile ? _mobileConfigCardVerticalPadding : 18.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showSourceMenuAtCursor(context, details.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: controller.canEditSources
              ? () => controller.selectSource(source.id)
              : null,
          child: Ink(
            key: cardKey,
            padding: EdgeInsets.fromLTRB(
              18,
              verticalPadding,
              14,
              verticalPadding,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primaryContainer.withValues(alpha: 0.32)
                  : scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Builder(
              builder: (context) {
                final body = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: isMobile
                          ? CrossAxisAlignment.center
                          : CrossAxisAlignment.start,
                      children: <Widget>[
                        _ServerFlagBadge(
                          server: source.serverAddress,
                          selected: selected,
                          size: _configCardFlagSize,
                        ),
                        const SizedBox(width: _configCardFlagGap),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  _sourceHeadline(source, profile),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _sourceSubtitle(
                                    strings,
                                    controller.displayCoreForProfile(profile),
                                    profile,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                if (source.isSubscription &&
                                    trafficUsage != null &&
                                    trafficUsage.hasTotal) ...<Widget>[
                                  const SizedBox(height: 8),
                                  _SubscriptionTrafficUsageBar(
                                    usage: trafficUsage,
                                    strings: strings,
                                  ),
                                ],
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
                                    onPressed: () =>
                                        _showSourceMenuAtButton(buttonContext),
                                    tooltip: MaterialLocalizations.of(
                                      context,
                                    ).showMenuTooltip,
                                    icon: const Icon(Icons.more_horiz_rounded),
                                    iconSize: 22,
                                    style: IconButton.styleFrom(
                                      fixedSize: const Size(34, 34),
                                      minimumSize: const Size(34, 34),
                                      maximumSize: const Size(34, 34),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      foregroundColor: scheme.onSurfaceVariant,
                                      disabledForegroundColor: scheme
                                          .onSurfaceVariant
                                          .withValues(alpha: 0.38),
                                      backgroundColor: Colors.transparent,
                                      hoverColor: scheme.onSurface.withValues(
                                        alpha: 0.12,
                                      ),
                                      highlightColor: scheme.onSurface
                                          .withValues(alpha: 0.16),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (source.lastUpdateError != null) ...<Widget>[
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.error_outline_rounded,
                            size: 16,
                            color: scheme.error,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              source.lastUpdateError!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (selected &&
                        source.hasMultipleProfiles &&
                        !isMobile) ...<Widget>[
                      const SizedBox(height: 14),
                      _ProfileDropdown(
                        controller: controller,
                        strings: strings,
                        source: source,
                      ),
                    ],
                  ],
                );

                return body;
              },
            ),
          ),
        ),
      ),
    );
  }

  List<PopupMenuEntry<_SourceMenuAction>> _sourceMenuItems(
    BuildContext context,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final canRemoveSource = controller.canRemoveSource(source.id);
    final canRefreshSource = source.isSubscription && !source.isUpdating;
    final updateColor = canRefreshSource
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.54);
    final updateTextColor = canRefreshSource
        ? scheme.onSurface
        : scheme.onSurfaceVariant.withValues(alpha: 0.54);
    final removeColor = canRemoveSource
        ? scheme.error
        : scheme.onSurfaceVariant.withValues(alpha: 0.54);
    final items = <PopupMenuEntry<_SourceMenuAction>>[];

    if (source.isSubscription) {
      items.addAll(<PopupMenuEntry<_SourceMenuAction>>[
        PopupMenuItem<_SourceMenuAction>(
          value: _SourceMenuAction.updateNow,
          enabled: canRefreshSource,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.refresh_rounded, color: updateColor),
              const SizedBox(width: 10),
              Text(
                strings.updateNowAction,
                style: TextStyle(color: updateTextColor),
              ),
            ],
          ),
        ),
        _SourceAutoUpdateMenuEntry(
          source: source,
          strings: strings,
          onChanged: (interval) {
            controller.setSourceAutoUpdateInterval(source.id, interval);
          },
        ),
      ]);
    }

    items.add(
      PopupMenuItem<_SourceMenuAction>(
        value: _SourceMenuAction.exportJson,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.file_download_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(strings.exportJsonAction),
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
              style: TextStyle(color: removeColor),
            ),
          ],
        ),
      ),
    );

    return items;
  }

  void _handleSourceMenuAction(BuildContext context, _SourceMenuAction action) {
    switch (action) {
      case _SourceMenuAction.exportJson:
        unawaited(_exportSourceJson(context));
        break;
      case _SourceMenuAction.updateNow:
        unawaited(controller.refreshSource(source.id));
        break;
      case _SourceMenuAction.delete:
        unawaited(controller.removeSource(source.id));
        break;
    }
  }

  Future<void> _exportSourceJson(BuildContext context) async {
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

      _showSourceSnackBar(context, strings.jsonExportedMessage);
    } on PlatformException {
      if (context.mounted) {
        _showSourceSnackBar(context, strings.jsonExportFailedMessage);
      }
    } on FileSystemException {
      if (context.mounted) {
        _showSourceSnackBar(context, strings.jsonExportFailedMessage);
      }
    } catch (_) {
      if (context.mounted) {
        _showSourceSnackBar(context, strings.jsonExportFailedMessage);
      }
    }
  }

  void _showSourceSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }

  Future<void> _showSourceMenuAtCursor(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return;
    }

    final localPosition = overlay.globalToLocal(globalPosition);
    await _showSourceMenuAtRect(
      context,
      Rect.fromPoints(localPosition, localPosition),
      overlay.size,
    );
  }

  Future<void> _showSourceMenuAtButton(BuildContext buttonContext) async {
    final button = buttonContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) {
      return;
    }

    final buttonTopLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    await _showSourceMenuAtRect(
      buttonContext,
      buttonTopLeft & button.size,
      overlay.size,
    );
  }

  Future<void> _showSourceMenuAtRect(
    BuildContext context,
    Rect anchor,
    Size overlaySize,
  ) async {
    final action = await showMenu<_SourceMenuAction>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: _sourceMenuItems(context),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      menuPadding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      popUpAnimationStyle: AnimationStyle.noAnimation,
    );
    if (action != null) {
      if (context.mounted) {
        _handleSourceMenuAction(context, action);
      }
    }
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
    final fillColor = _trafficUsageColor(ratio, scheme);
    final usedLabel = _formatTrafficBytes(usage.usedBytes);
    final totalLabel = _formatTrafficBytes(totalBytes);
    final expiresLabel = usage.expiresAt == null
        ? null
        : strings.subscriptionTrafficExpires(
            _formatCompactDate(usage.expiresAt!),
          );
    final percentLabel = '${(ratio * 100).round().clamp(0, 100)}%';
    final usageLabel = strings.subscriptionTrafficUsedOf(usedLabel, totalLabel);
    const barHeight = 24.0;
    final detailStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurface,
      fontSize: 11,
      height: 1.25,
      fontWeight: FontWeight.w600,
    );
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
      value: '$usageLabel, $percentLabel',
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
                          color: scheme.outlineVariant.withValues(alpha: 0.42),
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
            Text(expiresLabel, style: detailStyle),
          ],
        ],
      ),
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
        theme.popupMenuTheme.textStyle ?? theme.textTheme.labelLarge;
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
                            style: menuLabelStyle?.copyWith(
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

class _RuntimeLogsPanel extends StatelessWidget {
  const _RuntimeLogsPanel({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final logs = controller.runtimeLogs;
    final canCopyLogs = logs.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(strings.logsLabel, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            height: 220,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.44),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.24),
              ),
            ),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 42),
                    child: logs.isEmpty
                        ? Align(
                            alignment: Alignment.topLeft,
                            child: Text(
                              strings.noLogsYet,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : ListView.separated(
                            reverse: true,
                            itemCount: logs.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final line = logs[logs.length - 1 - index];
                              return Text(
                                line,
                                style: _monoStyle(
                                  theme,
                                  color: scheme.onSurface,
                                  fontSize: 12.2,
                                  weight: FontWeight.w500,
                                ),
                              );
                            },
                          ),
                  ),
                ),
                Align(
                  alignment: Alignment.topRight,
                  child: Tooltip(
                    message: strings.copyLogsAction,
                    child: IconButton(
                      onPressed: canCopyLogs
                          ? () async {
                              await Clipboard.setData(
                                ClipboardData(text: controller.runtimeLogsText),
                              );
                              if (!context.mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(strings.logsCopiedMessage),
                                ),
                              );
                            }
                          : null,
                      icon: const Icon(Icons.content_copy_rounded, size: 17),
                      style: IconButton.styleFrom(
                        fixedSize: const Size(34, 34),
                        minimumSize: const Size(34, 34),
                        maximumSize: const Size(34, 34),
                        padding: EdgeInsets.zero,
                        backgroundColor: Colors.transparent,
                        disabledBackgroundColor: Colors.transparent,
                        focusColor: Colors.transparent,
                        hoverColor: scheme.onSurface.withValues(alpha: 0.12),
                        highlightColor: scheme.onSurface.withValues(
                          alpha: 0.16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
        MediaQuery.sizeOf(context).width < _mobileShellBreakpoint;
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
            diameter: isSplit ? _splitPowerButtonDiameter : null,
            buttonKey: powerButtonKey,
          ),
          const SizedBox(height: 22),
          _ConnectionStatusLabel(controller: controller),
          if (controller.runtimeError != null &&
              controller.phase == ConnectionPhase.error) ...<Widget>[
            const SizedBox(height: 20),
            _MessageStrip(
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
        (anchorHeight - _splitPowerButtonDiameter) / 2 + verticalCorrection;
    return math.max(0, -buttonTop);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, _) {
        final buttonSize = _splitPowerButtonDiameter;
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

class _TrafficModeSelector extends StatelessWidget {
  const _TrafficModeSelector({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;

        return Column(
          children: <Widget>[
            if (!compact) ...<Widget>[
              Text(strings.trafficModeLabel, style: theme.textTheme.titleSmall),
              const SizedBox(height: 10),
            ],
            SegmentedButton<TrafficMode>(
              segments: <ButtonSegment<TrafficMode>>[
                ButtonSegment<TrafficMode>(
                  value: TrafficMode.systemProxy,
                  label: Text(strings.systemProxyModeLabel),
                ),
                ButtonSegment<TrafficMode>(
                  value: TrafficMode.tun,
                  label: Text(strings.tunModeLabel),
                ),
              ],
              selected: <TrafficMode>{controller.trafficMode},
              showSelectedIcon: false,
              multiSelectionEnabled: false,
              style: SegmentedButton.styleFrom(
                foregroundColor: scheme.onSurface,
                selectedForegroundColor: scheme.onPrimaryContainer,
                selectedBackgroundColor: scheme.primaryContainer,
                backgroundColor: Colors.transparent,
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.3),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 24 : 16,
                  vertical: compact ? 12 : 14,
                ),
                textStyle: theme.textTheme.titleSmall,
              ),
              onSelectionChanged: controller.canChangeTrafficMode
                  ? (selection) {
                      if (selection.isNotEmpty) {
                        unawaited(
                          controller.setTrafficMode(
                            selection.first,
                            ensureWindowsTunPrivileges: true,
                          ),
                        );
                      }
                    }
                  : null,
            ),
          ],
        );
      },
    );
  }
}

class _TunIpModeSelector extends StatelessWidget {
  const _TunIpModeSelector({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DropdownButtonFormField<TunIpMode>(
          key: ValueKey<TunIpMode>(controller.tunIpMode),
          initialValue: controller.tunIpMode,
          isExpanded: true,
          decoration: InputDecoration(labelText: strings.tunIpModeLabel),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          items: <DropdownMenuItem<TunIpMode>>[
            for (final mode in TunIpMode.values)
              DropdownMenuItem<TunIpMode>(
                value: mode,
                child: Text(strings.tunIpModeName(mode)),
              ),
          ],
          onChanged: controller.canChangeTunIpMode
              ? (mode) {
                  if (mode != null) {
                    controller.setTunIpMode(mode);
                  }
                }
              : null,
        );
      },
    );
  }
}

class _SplitTunnelSettingsTile extends StatelessWidget {
  const _SplitTunnelSettingsTile({
    required this.controller,
    required this.strings,
  });

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canChange = controller.canChangeSplitTunnel;
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);
    final titleColor = canChange ? scheme.onSurface : disabledColor;
    final statusColor = canChange ? scheme.onSurfaceVariant : disabledColor;
    final iconColor = canChange ? scheme.primary : disabledColor;

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: canChange
            ? () => unawaited(_showSplitTunnelDialog(context))
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Icon(Icons.account_tree_rounded, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      strings.splitTunnelLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      strings.splitTunnelModeName(controller.splitTunnelMode),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: statusColor),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSplitTunnelDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) =>
          _SplitTunnelDialog(controller: controller, strings: strings),
    );
  }
}

class _SplitTunnelDialog extends StatefulWidget {
  const _SplitTunnelDialog({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  State<_SplitTunnelDialog> createState() => _SplitTunnelDialogState();
}

class _SplitTunnelDialogState extends State<_SplitTunnelDialog> {
  late Future<List<SplitTunnelApp>> _appsFuture;
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()
      ..addListener(() {
        if (mounted) {
          setState(() {});
        }
      });
    _appsFuture = widget.controller.loadSplitTunnelAppCatalog();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = widget.strings;
    final controller = widget.controller;
    final selectedApps = controller.splitTunnelApps;
    final selectedAppIds = <String>{for (final app in selectedApps) app.id};
    final dialogSize = MediaQuery.sizeOf(context);
    final dialogWidth = (dialogSize.width * 0.82)
        .clamp(360.0, 720.0)
        .toDouble();
    final dialogHeight = (dialogSize.height * 0.72)
        .clamp(420.0, 580.0)
        .toDouble();

    return AlertDialog(
      title: Row(
        children: <Widget>[
          Expanded(child: Text(strings.splitTunnelLabel)),
          IconButton(
            tooltip: strings.splitTunnelRefreshTooltip,
            onPressed: _reloadApps,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SegmentedButton<SplitTunnelMode>(
              segments: <ButtonSegment<SplitTunnelMode>>[
                ButtonSegment<SplitTunnelMode>(
                  value: SplitTunnelMode.off,
                  label: Text(strings.splitTunnelOffModeLabel),
                ),
                ButtonSegment<SplitTunnelMode>(
                  value: SplitTunnelMode.whitelist,
                  label: Text(strings.splitTunnelWhitelistModeLabel),
                ),
                ButtonSegment<SplitTunnelMode>(
                  value: SplitTunnelMode.blacklist,
                  label: Text(strings.splitTunnelBlacklistModeLabel),
                ),
              ],
              selected: <SplitTunnelMode>{controller.splitTunnelMode},
              showSelectedIcon: false,
              multiSelectionEnabled: false,
              onSelectionChanged: controller.canChangeSplitTunnel
                  ? (selection) {
                      if (selection.isEmpty) {
                        return;
                      }
                      setState(() {
                        unawaited(
                          controller.setSplitTunnelMode(
                            selection.first,
                            ensureWindowsTunPrivileges: true,
                          ),
                        );
                      });
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            Text(
              strings.splitTunnelTunHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: strings.splitTunnelSearchHint,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    strings.splitTunnelAppsLabel,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  strings.splitTunnelSelectedCount(selectedApps.length),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<SplitTunnelApp>>(
                future: _appsFuture,
                builder: (context, snapshot) {
                  final apps = _filterApps(
                    _mergeApps(
                      snapshot.data ?? const <SplitTunnelApp>[],
                      selectedApps,
                      selectedAppIds,
                    ),
                  );

                  if (snapshot.connectionState == ConnectionState.waiting &&
                      apps.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (apps.isEmpty) {
                    return Center(
                      child: Text(
                        strings.splitTunnelNoAppsFound,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    itemCount: apps.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final app = apps[index];
                      final selected = selectedAppIds.contains(app.id);
                      final enabled =
                          controller.canChangeSplitTunnel &&
                          controller.splitTunnelMode != SplitTunnelMode.off;
                      return CheckboxListTile(
                        value: selected,
                        enabled: enabled,
                        onChanged: enabled
                            ? (_) {
                                setState(() {
                                  controller.toggleSplitTunnelApp(app);
                                });
                              }
                            : null,
                        title: Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          app.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  void _reloadApps() {
    setState(() {
      _appsFuture = widget.controller.loadSplitTunnelAppCatalog(refresh: true);
    });
  }

  List<SplitTunnelApp> _mergeApps(
    List<SplitTunnelApp> catalogApps,
    List<SplitTunnelApp> selectedApps,
    Set<String> selectedAppIds,
  ) {
    final appsById = <String, SplitTunnelApp>{
      for (final app in selectedApps) app.id: app,
    };
    for (final app in catalogApps) {
      appsById[app.id] = app;
    }
    final apps = appsById.values.toList(growable: false);
    apps.sort(
      (left, right) => _compareSplitTunnelApps(left, right, selectedAppIds),
    );
    return apps;
  }

  int _compareSplitTunnelApps(
    SplitTunnelApp left,
    SplitTunnelApp right,
    Set<String> selectedAppIds,
  ) {
    final leftSelected = selectedAppIds.contains(left.id);
    final rightSelected = selectedAppIds.contains(right.id);
    if (leftSelected != rightSelected) {
      return leftSelected ? -1 : 1;
    }

    final byName = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    if (byName != 0) {
      return byName;
    }
    return left.path.toLowerCase().compareTo(right.path.toLowerCase());
  }

  List<SplitTunnelApp> _filterApps(List<SplitTunnelApp> apps) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return apps;
    }
    return apps
        .where(
          (app) =>
              app.name.toLowerCase().contains(query) ||
              app.path.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }
}

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
    final glowColor = _phaseColor(controller.phase, scheme);
    final buttonColor = switch (controller.phase) {
      ConnectionPhase.disconnected => Colors.white,
      ConnectionPhase.connecting => Colors.white,
      ConnectionPhase.connected => _connectedColor,
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
        '${strings.powerConnectedLabel} ${_formatConnectedDuration(widget.controller.connectedAt)}',
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
        key: ValueKey<String>(statusText),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

class _InputPanel extends StatefulWidget {
  const _InputPanel({
    required this.controller,
    required this.strings,
    required this.textController,
  });

  final VpnController controller;
  final AppStrings strings;
  final TextEditingController textController;

  @override
  State<_InputPanel> createState() => _InputPanelState();
}

class _InputPanelState extends State<_InputPanel> {
  late final FocusNode _inputFocusNode;
  final ImagePicker _imagePicker = ImagePicker();
  final MobileScannerController _imageScannerController =
      MobileScannerController(
        autoStart: false,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );
  final qrd.QrCodeDartDecoder _desktopQrDecoder = qrd.QrCodeDartDecoder(
    formats: const <qrd.BarcodeFormat>[qrd.BarcodeFormat.qrCode],
  );

  @override
  void initState() {
    super.initState();
    _inputFocusNode = FocusNode();
    _inputFocusNode.addListener(_handleInputFocusChanged);
  }

  @override
  void dispose() {
    _inputFocusNode
      ..removeListener(_handleInputFocusChanged)
      ..dispose();
    unawaited(_imageScannerController.dispose());
    super.dispose();
  }

  void _handleInputFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pasteFromClipboard(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final clipboardText = clipboardData?.text ?? '';

    if (clipboardText.trim().isEmpty) {
      messenger?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(widget.strings.clipboardEmptyMessage),
        ),
      );
      return;
    }

    widget.textController.value = TextEditingValue(
      text: clipboardText,
      selection: TextSelection.collapsed(offset: clipboardText.length),
    );
    await widget.controller.pasteSourceInput(clipboardText);
  }

  Future<void> _showQrScanPicker(BuildContext context) async {
    if (Platform.isWindows) {
      await _showWindowsQrImportPicker(context);
      return;
    }

    final source = await showModalBottomSheet<_QrScanSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final strings = widget.strings;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: Text(strings.qrGalleryAction),
                onTap: () => Navigator.of(context).pop(_QrScanSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: Text(strings.qrCameraAction),
                onTap: () => Navigator.of(context).pop(_QrScanSource.camera),
              ),
            ],
          ),
        );
      },
    );

    if (!context.mounted || source == null) {
      return;
    }

    switch (source) {
      case _QrScanSource.gallery:
        await _scanQrFromGallery(context);
        break;
      case _QrScanSource.camera:
        await _scanQrFromCamera(context);
        break;
      case _QrScanSource.clipboardImage:
      case _QrScanSource.imageFile:
        break;
    }
  }

  Future<void> _showWindowsQrImportPicker(BuildContext context) async {
    final source = await showDialog<_QrScanSource>(
      context: context,
      builder: (context) => _WindowsQrImportDialog(strings: widget.strings),
    );

    if (!context.mounted || source == null) {
      return;
    }

    switch (source) {
      case _QrScanSource.clipboardImage:
        await _scanQrFromClipboardImage(context);
        break;
      case _QrScanSource.imageFile:
        await _scanQrFromImageFile(context);
        break;
      case _QrScanSource.gallery:
      case _QrScanSource.camera:
        break;
    }
  }

  Future<void> _scanQrFromGallery(BuildContext context) async {
    try {
      final image = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (!mounted || image == null) {
        return;
      }

      final capture = await _imageScannerController.analyzeImage(
        image.path,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );
      if (!mounted || !context.mounted) {
        return;
      }

      final qrText = _firstQrValue(capture);
      if (qrText == null) {
        _showInputSnackBar(context, widget.strings.qrCodeNotFoundMessage);
        return;
      }

      await _importQrText(context, qrText);
    } catch (_) {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
      }
    }
  }

  Future<void> _scanQrFromClipboardImage(BuildContext context) async {
    try {
      final imageBytes = await _clipboardImageBytes();
      if (!mounted || !context.mounted) {
        return;
      }

      if (imageBytes == null || imageBytes.isEmpty) {
        _showInputSnackBar(
          context,
          widget.strings.qrClipboardImageMissingMessage,
        );
        return;
      }

      await _importQrFromDesktopImageBytes(context, imageBytes);
    } catch (_) {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
      }
    }
  }

  Future<void> _scanQrFromImageFile(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _qrImageFileExtensions,
        withData: true,
      );
      if (!mounted || !context.mounted || result == null) {
        return;
      }

      final imageBytes = await _selectedImageBytes(result.files.single);
      if (!mounted || !context.mounted) {
        return;
      }

      if (imageBytes == null || imageBytes.isEmpty) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
        return;
      }

      await _importQrFromDesktopImageBytes(context, imageBytes);
    } catch (_) {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
      }
    }
  }

  Future<void> _scanQrFromCamera(BuildContext context) async {
    final qrText = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (context) => _QrCameraScannerPage(strings: widget.strings),
      ),
    );
    if (!mounted || !context.mounted || qrText == null) {
      return;
    }

    await _importQrText(context, qrText);
  }

  Future<void> _importQrFromDesktopImageBytes(
    BuildContext context,
    Uint8List imageBytes,
  ) async {
    final result = await _desktopQrDecoder.decodeFile(imageBytes);
    if (!mounted || !context.mounted) {
      return;
    }

    final qrText = result?.text.trim();
    if (qrText == null || qrText.isEmpty) {
      _showInputSnackBar(context, widget.strings.qrCodeNotFoundMessage);
      return;
    }

    await _importQrText(context, qrText);
  }

  Future<void> _importQrText(BuildContext context, String qrText) async {
    widget.textController.value = TextEditingValue(
      text: qrText,
      selection: TextSelection.collapsed(offset: qrText.length),
    );
    _inputFocusNode.unfocus();
    await widget.controller.pasteSourceInput(
      qrText,
      successTarget: AddSourceSuccessTarget.qr,
    );
  }

  Future<Uint8List?> _clipboardImageBytes() async {
    final imageBytes = await Pasteboard.image;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      return imageBytes;
    }

    final files = await Pasteboard.files();
    for (final filePath in files) {
      final path = filePath.trim();
      if (path.isEmpty || !_isQrImageFilePath(path)) {
        continue;
      }

      try {
        final bytes = await File(path).readAsBytes();
        if (bytes.isNotEmpty) {
          return bytes;
        }
      } on FileSystemException {
        continue;
      }
    }

    return null;
  }

  Future<Uint8List?> _selectedImageBytes(PlatformFile file) async {
    final bytes = file.bytes;
    if (bytes != null) {
      return bytes;
    }

    final path = file.path?.trim();
    if (path == null || path.isEmpty) {
      return null;
    }
    return File(path).readAsBytes();
  }

  Future<void> _importFromJson(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
        withData: true,
      );
      if (!mounted || !context.mounted || result == null) {
        return;
      }

      final importedInput = _jsonImportInput(result.files.single);
      if (importedInput == null || importedInput.trim().isEmpty) {
        _showInputSnackBar(context, widget.strings.jsonImportFailedMessage);
        return;
      }

      widget.textController.value = TextEditingValue(
        text: importedInput,
        selection: TextSelection.collapsed(offset: importedInput.length),
      );
      _inputFocusNode.unfocus();
      widget.controller.setRawInput(importedInput);
      await widget.controller.addSource(
        successTarget: AddSourceSuccessTarget.json,
      );
    } on PlatformException {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.jsonImportFailedMessage);
      }
    } on FormatException {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.jsonImportFailedMessage);
      }
    }
  }

  String? _jsonImportInput(PlatformFile file) {
    final path = file.path?.trim();
    if (path != null && path.isNotEmpty) {
      return path;
    }

    final bytes = file.bytes;
    if (bytes == null) {
      return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _showInputSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }

  void _clearInput() {
    widget.textController.clear();
    widget.controller.setRawInput('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = widget.controller;
    final strings = widget.strings;
    final textController = widget.textController;
    final showRecentSuccess =
        controller.didAddSourceRecently && !controller.isAddingSource;
    final showAddLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.add;
    final showPasteLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.paste;
    final showQrLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.qr;
    final showJsonLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.json;
    final showAddSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.add;
    final showPasteSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.paste;
    final showQrSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.qr;
    final showJsonSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.json;
    final actionBackground = showAddSuccess
        ? _connectedColor
        : Colors.transparent;
    final actionForeground = showAddSuccess
        ? Colors.white
        : scheme.onSecondaryContainer;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 620;
        final compact = constraints.maxWidth < 520;
        final isDesktop =
            theme.platform == TargetPlatform.windows ||
            theme.platform == TargetPlatform.macOS ||
            theme.platform == TargetPlatform.linux;
        final titleTopPadding = isDesktop && !compact
            ? 0.0
            : compact
            ? 6.0
            : 12.0;
        final titleInputGap = isDesktop && !compact ? 12.0 : 18.0;
        final inputMinLines = isDesktop && !compact ? 5 : 4;
        final inputMaxLines = isDesktop && !compact ? 7 : 6;
        const actionButtonSize = 36.0;
        const utilityActionSize = 32.0;
        final actionGap = compact ? 5.0 : 7.0;
        final utilityActionGap = compact ? 1.0 : 2.0;
        final titleTrailingInset = isWide ? actionButtonSize + actionGap : 0.0;
        ButtonStyle fullWidthImportStyle({required bool success}) =>
            OutlinedButton.styleFrom(
              backgroundColor: success
                  ? _connectedColor
                  : const Color(0xFF4A4A4A),
              disabledBackgroundColor: success
                  ? _connectedColor
                  : const Color(0xFF2F2F2F),
              foregroundColor: Colors.white,
              disabledForegroundColor: success ? Colors.white : Colors.white54,
              minimumSize: const Size(0, 46),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            );
        final jsonImportAction = SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: controller.canAddSource
                ? () => _importFromJson(context)
                : null,
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: showJsonLoading
                  ? const SizedBox(
                      key: ValueKey<String>('json-loading'),
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      showJsonSuccess
                          ? Icons.check_rounded
                          : Icons.data_object_rounded,
                      key: ValueKey<bool>(showJsonSuccess),
                    ),
            ),
            label: Text(strings.importFromJsonAction),
            style: fullWidthImportStyle(success: showJsonSuccess),
          ),
        );
        final qrAction = Platform.isAndroid || Platform.isWindows
            ? SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: controller.canAddSource
                      ? () => _showQrScanPicker(context)
                      : null,
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: showQrLoading
                        ? SizedBox(
                            key: const ValueKey<String>('qr-loading'),
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: scheme.onSurface,
                            ),
                          )
                        : Icon(
                            showQrSuccess
                                ? Icons.check_rounded
                                : Icons.qr_code_scanner_rounded,
                            key: ValueKey<bool>(showQrSuccess),
                          ),
                  ),
                  label: Text(strings.scanQrAction),
                  style: fullWidthImportStyle(success: showQrSuccess),
                ),
              )
            : null;
        final action = _InputActionTooltip(
          message: strings.addSourceAction,
          child: IconButton.filled(
            onPressed: controller.canAddSource ? controller.addSource : null,
            iconSize: 21,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(actionButtonSize),
              minimumSize: const Size.square(actionButtonSize),
              maximumSize: const Size.square(actionButtonSize),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              backgroundColor: actionBackground,
              foregroundColor: actionForeground,
              disabledBackgroundColor: Colors.transparent,
              disabledForegroundColor: scheme.onSurfaceVariant.withValues(
                alpha: 0.42,
              ),
              hoverColor: showAddSuccess
                  ? _connectedColor.withValues(alpha: 0.82)
                  : scheme.onSurface.withValues(alpha: 0.12),
              highlightColor: showAddSuccess
                  ? _connectedColor.withValues(alpha: 0.9)
                  : scheme.onSurface.withValues(alpha: 0.16),
              shape: const CircleBorder(),
            ),
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: showAddLoading
                  ? SizedBox(
                      key: const ValueKey<String>('loading'),
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: actionForeground,
                      ),
                    )
                  : Icon(
                      showAddSuccess ? Icons.check_rounded : Icons.add_rounded,
                      key: ValueKey<bool>(showAddSuccess),
                      color: actionForeground,
                    ),
            ),
          ),
        );
        ButtonStyle inputActionStyle({bool success = false}) =>
            IconButton.styleFrom(
              fixedSize: const Size.square(utilityActionSize),
              minimumSize: const Size.square(utilityActionSize),
              maximumSize: const Size.square(utilityActionSize),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              foregroundColor: success ? Colors.white : scheme.onSurface,
              disabledForegroundColor: scheme.onSurfaceVariant.withValues(
                alpha: 0.36,
              ),
              backgroundColor: success ? _connectedColor : Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
              focusColor: Colors.transparent,
              hoverColor: success
                  ? _connectedColor.withValues(alpha: 0.82)
                  : scheme.onSurface.withValues(alpha: 0.12),
              highlightColor: success
                  ? _connectedColor.withValues(alpha: 0.9)
                  : scheme.onSurface.withValues(alpha: 0.16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            );
        final pasteAction = _InputActionTooltip(
          message: strings.pasteFromClipboardAction,
          child: IconButton(
            onPressed: controller.canAddSource
                ? () => _pasteFromClipboard(context)
                : null,
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: showPasteLoading
                  ? SizedBox(
                      key: const ValueKey<String>('paste-loading'),
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: scheme.onSurface,
                      ),
                    )
                  : Icon(
                      showPasteSuccess
                          ? Icons.check_rounded
                          : Icons.content_paste_rounded,
                      key: ValueKey<bool>(showPasteSuccess),
                    ),
            ),
            iconSize: 20,
            style: inputActionStyle(success: showPasteSuccess),
          ),
        );
        final clearAction = _InputActionTooltip(
          message: strings.clearInputAction,
          child: IconButton(
            onPressed: controller.canAddSource ? _clearInput : null,
            icon: const Icon(Icons.backspace_outlined),
            iconSize: 20,
            style: inputActionStyle(),
          ),
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 6 : 24,
            titleTopPadding,
            compact ? 6 : 24,
            compact ? 6 : 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!compact) ...<Widget>[
                Padding(
                  padding: EdgeInsets.only(right: titleTrailingInset),
                  child: Text(
                    strings.inputLabel,
                    textAlign: isWide ? TextAlign.center : TextAlign.start,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                SizedBox(height: titleInputGap),
              ],
              TextFieldTapRegion(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: textController,
                        focusNode: _inputFocusNode,
                        minLines: inputMinLines,
                        maxLines: inputMaxLines,
                        enabled: controller.canAddSource,
                        onTapOutside: (_) => _inputFocusNode.unfocus(),
                        style: _monoStyle(
                          theme,
                          color: scheme.onSurface,
                          fontSize: 13.1,
                          weight: FontWeight.w500,
                        ),
                        decoration: InputDecoration(
                          hintText: _inputFocusNode.hasFocus
                              ? null
                              : strings.inputHint,
                          contentPadding: const EdgeInsets.fromLTRB(
                            20,
                            18,
                            20,
                            18,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: actionGap),
                    SizedBox(
                      width: actionButtonSize,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          pasteAction,
                          SizedBox(height: utilityActionGap),
                          action,
                          SizedBox(height: utilityActionGap),
                          clearAction,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (controller.previewError != null) ...<Widget>[
                const SizedBox(height: 14),
                _MessageStrip(
                  containerColor: scheme.errorContainer,
                  foregroundColor: scheme.onErrorContainer,
                  icon: Icons.error_outline_rounded,
                  text: controller.previewError!,
                ),
              ],
              const SizedBox(height: 14),
              jsonImportAction,
              if (qrAction != null) ...<Widget>[
                const SizedBox(height: 14),
                qrAction,
              ],
            ],
          ),
        );
      },
    );
  }
}

class _PasteQrImageIntent extends Intent {
  const _PasteQrImageIntent();
}

class _WindowsQrImportDialog extends StatelessWidget {
  const _WindowsQrImportDialog({required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return FocusableActionDetector(
      autofocus: true,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _PasteQrImageIntent(),
      },
      actions: <Type, Action<Intent>>{
        _PasteQrImageIntent: CallbackAction<_PasteQrImageIntent>(
          onInvoke: (_) {
            Navigator.of(context).pop(_QrScanSource.clipboardImage);
            return null;
          },
        ),
      },
      child: AlertDialog(
        title: Text(strings.scanQrAction),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 10),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _WindowsQrImportTile(
                icon: Icons.content_paste_go_rounded,
                title: strings.qrPasteImageAction,
                onTap: () =>
                    Navigator.of(context).pop(_QrScanSource.clipboardImage),
              ),
              Divider(color: scheme.outlineVariant.withValues(alpha: 0.42)),
              _WindowsQrImportTile(
                icon: Icons.image_search_rounded,
                title: strings.qrBrowseImageAction,
                onTap: () => Navigator.of(context).pop(_QrScanSource.imageFile),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _WindowsQrImportTile extends StatelessWidget {
  const _WindowsQrImportTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon),
      title: Text(title),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

class _QrCameraScannerPage extends StatefulWidget {
  const _QrCameraScannerPage({required this.strings});

  final AppStrings strings;

  @override
  State<_QrCameraScannerPage> createState() => _QrCameraScannerPageState();
}

class _QrCameraScannerPageState extends State<_QrCameraScannerPage> {
  late final MobileScannerController _scannerController;
  bool _handledDetection = false;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      cameraResolution: const Size(1920, 1080),
      detectionSpeed: DetectionSpeed.noDuplicates,
      lensType: CameraLensType.normal,
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      autoZoom: true,
    );
  }

  @override
  void dispose() {
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_handledDetection) {
      return;
    }

    final qrText = _firstQrValue(capture);
    if (qrText == null) {
      return;
    }

    _handledDetection = true;
    unawaited(_scannerController.stop());
    Navigator.of(context).pop(qrText);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scanGuide = _scanGuideFor(constraints.biggest);
                return MobileScanner(
                  controller: _scannerController,
                  fit: BoxFit.cover,
                  tapToFocus: true,
                  onDetect: _handleDetect,
                  placeholderBuilder: (context) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorBuilder: (context, error) {
                    final message = error.errorDetails?.message;
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          message?.isNotEmpty == true
                              ? message!
                              : widget.strings.cameraUnavailableMessage,
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                        ),
                      ),
                    );
                  },
                  overlayBuilder: (context, _) {
                    return ScanWindowOverlay(
                      controller: _scannerController,
                      scanWindow: scanGuide,
                      borderColor: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      borderWidth: 3,
                      color: Colors.black.withValues(alpha: 0.56),
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Row(
                  children: <Widget>[
                    _ScannerIconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    ValueListenableBuilder<MobileScannerState>(
                      valueListenable: _scannerController,
                      builder: (context, value, _) {
                        if (value.torchState == TorchState.unavailable) {
                          return const SizedBox.shrink();
                        }
                        final torchOn = value.torchState == TorchState.on;
                        return _ScannerIconButton(
                          tooltip: torchOn
                              ? widget.strings.turnFlashOffAction
                              : widget.strings.turnFlashOnAction,
                          icon: torchOn
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                          onPressed: () =>
                              unawaited(_scannerController.toggleTorch()),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: const SizedBox(height: 120),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Center(
                  child: Text(
                    widget.strings.scanQrAction,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.88),
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

  Rect _scanGuideFor(Size size) {
    final shortestSide = size.shortestSide;
    final windowSize = (shortestSide * 0.84).clamp(260.0, 460.0).toDouble();
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: windowSize,
      height: windowSize,
    );
  }
}

class _ScannerIconButton extends StatelessWidget {
  const _ScannerIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.48),
          foregroundColor: Colors.white,
          fixedSize: const Size.square(44),
          minimumSize: const Size.square(44),
          maximumSize: const Size.square(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

String? _firstQrValue(BarcodeCapture? capture) {
  if (capture == null) {
    return null;
  }

  for (final barcode in capture.barcodes) {
    final rawValue = barcode.rawValue?.trim();
    if (rawValue != null && rawValue.isNotEmpty) {
      return rawValue;
    }

    final displayValue = barcode.displayValue?.trim();
    if (displayValue != null && displayValue.isNotEmpty) {
      return displayValue;
    }
  }

  return null;
}

bool _isQrImageFilePath(String path) {
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == path.length - 1) {
    return false;
  }

  final extension = path.substring(dotIndex + 1).toLowerCase();
  return _qrImageFileExtensions.contains(extension);
}

class _InputActionTooltip extends StatelessWidget {
  const _InputActionTooltip({required this.message, required this.child});

  static const double _gap = 8;

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      positionDelegate: _positionBesideAction,
      child: child,
    );
  }

  static Offset _positionBesideAction(TooltipPositionContext context) {
    final targetRight = context.target.dx + context.targetSize.width / 2;
    final maxDy = (context.overlaySize.height - context.tooltipSize.height)
        .clamp(0.0, double.infinity)
        .toDouble();

    return Offset(
      targetRight + _gap,
      (context.target.dy - context.tooltipSize.height / 2)
          .clamp(0.0, maxDy)
          .toDouble(),
    );
  }
}

class _MessageStrip extends StatelessWidget {
  const _MessageStrip({
    required this.containerColor,
    required this.foregroundColor,
    required this.icon,
    required this.text,
  });

  final Color containerColor;
  final Color foregroundColor;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: foregroundColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foregroundColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerFlagBadge extends StatefulWidget {
  const _ServerFlagBadge({
    super.key,
    required this.server,
    required this.selected,
    required this.size,
  });

  final String server;
  final bool selected;
  final double size;

  @override
  State<_ServerFlagBadge> createState() => _ServerFlagBadgeState();
}

class _ServerFlagBadgeState extends State<_ServerFlagBadge> {
  static final GeoIpService _geoIpService = GeoIpService();

  late Future<GeoIpInfo?> _lookup;

  @override
  void initState() {
    super.initState();
    _lookup = _geoIpService.resolveServer(widget.server);
  }

  @override
  void didUpdateWidget(covariant _ServerFlagBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server != widget.server) {
      _lookup = _geoIpService.resolveServer(widget.server);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final backgroundColor = widget.selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foregroundColor = widget.selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    return FutureBuilder<GeoIpInfo?>(
      future: _lookup,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final fallbackIcon = snapshot.connectionState == ConnectionState.waiting
            ? Icons.travel_explore_rounded
            : Icons.public_rounded;
        final badgeWidth = flagWidthForCountryCode(
          info?.countryCode,
          widget.size,
        );
        final fallbackBadge = SizedBox(
          width: badgeWidth,
          height: widget.size,
          child: Center(
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(widget.size * 0.33),
                border: Border.all(
                  color: widget.selected
                      ? scheme.primary.withValues(alpha: 0.35)
                      : scheme.outlineVariant.withValues(alpha: 0.34),
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                fallbackIcon,
                size: widget.size * 0.46,
                color: foregroundColor,
              ),
            ),
          ),
        );

        final Widget badge;
        if (info == null) {
          badge = fallbackBadge;
        } else {
          final flagWidth = badgeWidth;
          final flagHeight = widget.size;
          final flagRadius = math.min(flagWidth, flagHeight) * 0.2;

          badge = SizedBox(
            width: flagWidth,
            height: flagHeight,
            child: _CountryFlagAssetImage(
              countryCode: info.countryCode,
              borderRadius: flagRadius,
              errorChild: DecoratedBox(
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(flagRadius),
                  border: Border.all(
                    color: widget.selected
                        ? scheme.primary.withValues(alpha: 0.35)
                        : scheme.outlineVariant.withValues(alpha: 0.34),
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.public_rounded,
                    size: math.min(flagWidth, flagHeight) * 0.46,
                    color: foregroundColor,
                  ),
                ),
              ),
            ),
          );
        }

        final child = SizedBox(
          width: badgeWidth,
          height: widget.size,
          child: badge,
        );

        if (info == null) {
          return child;
        }

        return Tooltip(
          message: info.tooltipLabel,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF000000),
            fontSize: 12,
          ),
          child: child,
        );
      },
    );
  }
}

const _flagAssetDirectory = 'assets/flags';

class _CountryFlagAssetImage extends StatelessWidget {
  const _CountryFlagAssetImage({
    required this.countryCode,
    required this.borderRadius,
    required this.errorChild,
  });

  static final ScalableImageCache _cache = ScalableImageCache(size: 80);

  final String countryCode;
  final double borderRadius;
  final Widget errorChild;

  @override
  Widget build(BuildContext context) {
    final flagCode = countryCode.trim().toLowerCase();

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ScalableImageWidget.fromSISource(
        si: ScalableImageSource.fromSvg(
          rootBundle,
          '$_flagAssetDirectory/$flagCode.svg',
          warnF: (_) {},
        ),
        fit: BoxFit.fill,
        cache: _cache,
        onLoading: (_) => errorChild,
        onError: (_) => errorChild,
      ),
    );
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({required this.controller, required this.strings});

  final VpnController controller;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SegmentedButton<AppLanguage>(
      segments: <ButtonSegment<AppLanguage>>[
        ButtonSegment<AppLanguage>(
          value: AppLanguage.ru,
          icon: Tooltip(
            message: strings.russianLabel,
            child: SizedBox(
              width: 24,
              height: 18,
              child: _CountryFlagAssetImage(
                countryCode: 'RU',
                borderRadius: 4,
                errorChild: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        ButtonSegment<AppLanguage>(
          value: AppLanguage.en,
          icon: Tooltip(
            message: strings.englishLabel,
            child: SizedBox(
              width: 24,
              height: 18,
              child: _CountryFlagAssetImage(
                countryCode: 'GB',
                borderRadius: 4,
                errorChild: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ],
      selected: <AppLanguage>{controller.language},
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        selectedForegroundColor: scheme.onSecondaryContainer,
        selectedBackgroundColor: scheme.secondaryContainer,
        backgroundColor: Colors.transparent,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        textStyle: theme.textTheme.titleSmall,
      ),
      onSelectionChanged: (selection) {
        if (selection.isNotEmpty) {
          controller.setLanguage(selection.first);
        }
      },
    );
  }
}

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
    final headerTextWidth = (innerWidth - 10 - 38 - 10 - 8 - 74 - 8)
        .clamp(48.0, double.infinity)
        .toDouble();
    final headerTitleHeight = _measuredTextHeight(
      context,
      _sourceSubscriptionTitle(source),
      theme.textTheme.titleSmall,
      maxWidth: headerTextWidth,
      maxLines: 1,
    );
    final headerHeight =
        _mobileSubscriptionHeaderVerticalPadding * 2 +
        math.max(38.0, headerTitleHeight);

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
      if (usage.expiresAt != null) {
        final expiresLabel = strings.subscriptionTrafficExpires(
          _formatCompactDate(usage.expiresAt!),
        );
        height +=
            7 +
            _measuredTextHeight(
              context,
              expiresLabel,
              theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                height: 1.25,
                fontWeight: FontWeight.w600,
              ),
              maxWidth: innerWidth,
              maxLines: 1,
            );
      }
    } else {
      height += _mobileSubscriptionHeaderGap;
    }

    return height.ceilToDouble().clamp(132.0, 620.0).toDouble();
  }

  final theme = Theme.of(context);
  final profile = source.selectedProfile;
  final showSourceState = source.isUpdating || !source.hasMultipleProfiles;
  final actionRowWidth = showSourceState ? 74.0 : 34.0;
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
  final titleHeight = _measuredTextHeight(
    context,
    _sourceHeadline(source, profile),
    theme.textTheme.titleSmall,
    maxWidth: textWidth,
    maxLines: 1,
  );
  final subtitleHeight = _measuredTextHeight(
    context,
    _sourceSubtitle(
      strings,
      controller.displayCoreForProfile(profile),
      profile,
    ),
    theme.textTheme.bodyMedium,
    maxWidth: textWidth,
    maxLines: 2,
  );

  var textColumnHeight = titleHeight + 4 + subtitleHeight;

  final usage = source.trafficUsage;
  if (source.isSubscription && usage != null && usage.hasTotal) {
    textColumnHeight += 8 + 24;
    if (usage.expiresAt != null) {
      final expiresLabel = strings.subscriptionTrafficExpires(
        _formatCompactDate(usage.expiresAt!),
      );
      textColumnHeight +=
          7 +
          _measuredTextHeight(
            context,
            expiresLabel,
            theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
            maxWidth: textWidth,
            maxLines: 1,
          );
    }
  }

  var height =
      _mobileConfigCardVerticalPadding +
      math.max(_configCardFlagSize, math.max(34.0, textColumnHeight)) +
      _mobileConfigCardVerticalPadding +
      2;

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
    height += 10 + errorHeight;
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

double _measuredTextHeight(
  BuildContext context,
  String text,
  TextStyle? style, {
  required double maxWidth,
  required int maxLines,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: style ?? DefaultTextStyle.of(context).style,
    ),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    maxLines: maxLines,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: maxWidth);
  return painter.size.height;
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

Color _trafficUsageColor(double ratio, ColorScheme scheme) {
  if (ratio >= 0.92) {
    return scheme.error;
  }
  if (ratio >= 0.75) {
    return const Color(0xFFFFC857);
  }
  return _connectedColor;
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
  return '${local.year}-$month-$day';
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
