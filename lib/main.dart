import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException, Platform;
import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

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

part 'main_helpers.dart';
part 'main_flags.dart';
part 'main_shell.dart';
part 'main_sources.dart';
part 'main_settings.dart';

const _seedColor = Color(0xFFEDEDED);
const _connectedColor = Color(0xFF4CAF50);
const _appBackgroundColor = Color(0xFF000000);
const _mobileShellBreakpoint = 620.0;
const _splitPowerButtonDiameter = 196.0;
const _qrImageFileExtensions = <String>[
  'png',
  'jpg',
  'jpeg',
  'bmp',
  'gif',
  'webp',
];

enum _QrScanSource { gallery, camera, clipboardImage, imageFile }

enum _SourceMenuAction { exportJson, delete }

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
  static const MethodChannel _windowsLifecycleChannel = MethodChannel(
    'entropy_vpn/windows_lifecycle',
  );

  late final VpnController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VpnController();
    if (Platform.isWindows) {
      _windowsLifecycleChannel.setMethodCallHandler(_handleWindowsLifecycle);
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _windowsLifecycleChannel.setMethodCallHandler(null);
    }
    _controller.dispose();
    super.dispose();
  }

  Future<Object?> _handleWindowsLifecycle(MethodCall call) async {
    switch (call.method) {
      case 'quit':
        await _controller.shutdownForExit();
        return null;
    }
    throw MissingPluginException();
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
      fontFamily: 'GolosText',
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
            fontWeight: FontWeight.w500,
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

class _ConnectPageBody extends StatefulWidget {
  const _ConnectPageBody({
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
        final settingsHorizontalPadding = isCompact ? 6.0 : 24.0;
        final settingsVerticalPadding = isCompact ? 4.0 : 6.0;
        final settingsGap = isCompact ? 4.0 : 6.0;

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
                        horizontal: settingsHorizontalPadding,
                        vertical: settingsVerticalPadding,
                      ),
                      child: _TrafficModeSelector(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: settingsGap),
                  ],
                  if (controller.supportsTunIpModeSelection) ...<Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: settingsHorizontalPadding,
                        vertical: settingsVerticalPadding,
                      ),
                      child: _TunIpModeSelector(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: settingsGap),
                  ],
                  if (controller.supportsSplitTunneling) ...<Widget>[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: settingsHorizontalPadding,
                        vertical: settingsVerticalPadding,
                      ),
                      child: _SplitTunnelSettingsTile(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: settingsGap),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: settingsHorizontalPadding,
                        vertical: settingsVerticalPadding,
                      ),
                      child: _DomainSplitTunnelSettingsTile(
                        controller: controller,
                        strings: strings,
                      ),
                    ),
                    SizedBox(height: settingsGap),
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
          fontSize: 18,
          fontWeight: FontWeight.w500,
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
            icon: _InputActionIcon(
              loading: showJsonLoading,
              success: showJsonSuccess,
              icon: Icons.data_object_rounded,
              loadingColor: Colors.white,
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
                  icon: _InputActionIcon(
                    loading: showQrLoading,
                    success: showQrSuccess,
                    icon: Icons.qr_code_scanner_rounded,
                    loadingColor: scheme.onSurface,
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
            icon: _InputActionIcon(
              loading: showAddLoading,
              success: showAddSuccess,
              icon: Icons.add_rounded,
              loadingSize: 18,
              strokeWidth: 2.4,
              loadingColor: actionForeground,
              iconColor: actionForeground,
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
            icon: _InputActionIcon(
              loading: showPasteLoading,
              success: showPasteSuccess,
              icon: Icons.content_paste_rounded,
              loadingSize: 16,
              loadingColor: scheme.onSurface,
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

class _InputActionIcon extends StatelessWidget {
  const _InputActionIcon({
    required this.loading,
    required this.success,
    required this.icon,
    this.loadingSize = 17,
    this.strokeWidth = 2.2,
    this.loadingColor,
    this.iconColor,
  });

  final bool loading;
  final bool success;
  final IconData icon;
  final double loadingSize;
  final double strokeWidth;
  final Color? loadingColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: loading
          ? SizedBox(
              key: ValueKey<String>('loading-${icon.codePoint}'),
              width: loadingSize,
              height: loadingSize,
              child: CircularProgressIndicator(
                strokeWidth: strokeWidth,
                color: loadingColor,
              ),
            )
          : Icon(
              success ? Icons.check_rounded : icon,
              key: ValueKey<String>('icon-${icon.codePoint}-$success'),
              color: iconColor,
            ),
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
