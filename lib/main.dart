import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_strings.dart';
import 'main_constants.dart';
import 'main_shell.dart';
import 'models/vpn_profile.dart';
import 'services/vpn_controller.dart';

export 'main_shell.dart' show VpnHomePage;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: appBackgroundColor,
      systemNavigationBarColor: appBackgroundColor,
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
          seedColor: seedColor,
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
          surface: appBackgroundColor,
          onSurface: Colors.white,
          onSurfaceVariant: const Color(0xFFB8B8B8),
          surfaceContainerLowest: appBackgroundColor,
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
      scaffoldBackgroundColor: appBackgroundColor,
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
