import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:entropy_vpn/l10n/app_strings.dart';
import 'package:entropy_vpn/main.dart';
import 'package:entropy_vpn/models/config_source.dart';
import 'package:entropy_vpn/models/split_tunnel.dart';
import 'package:entropy_vpn/models/vpn_profile.dart';
import 'package:entropy_vpn/services/app_state_store.dart';
import 'package:entropy_vpn/services/core_runtime_service.dart';
import 'package:entropy_vpn/services/vpn_controller.dart';

Finder _powerButtonSurface() {
  return find.ancestor(
    of: find.byIcon(Icons.power_settings_new_rounded),
    matching: find.byWidgetPredicate(
      (widget) => widget is Material && widget.shape is CircleBorder,
      description: 'circular power button Material',
    ),
  );
}

void main() {
  testWidgets('app shell renders navigation icons', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EntropyVpnApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byIcon(Icons.power_settings_new_rounded), findsWidgets);
    expect(find.byIcon(Icons.settings_rounded), findsOneWidget);
    expect(find.byIcon(Icons.receipt_long_outlined), findsOneWidget);
    expect(find.text('EntropyVPN'), findsNothing);
  });

  testWidgets('add source hint is hidden only while the input is focused', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EntropyVpnApp());
    await tester.pump();

    const hint =
        'Paste a vless://, vmess://, trojan://, ss://, hysteria://, hy2:// link, sing-box:// import link, sing-box JSON, or an http(s) subscription URL';

    expect(find.text(hint), findsOneWidget);
    expect(find.text('Import from JSON'), findsOneWidget);

    await tester.tap(find.byType(TextField).last);
    await tester.pump();

    expect(find.text(hint), findsNothing);

    await tester.tapAt(const Offset(8, 8));
    await tester.pump();

    expect(find.text(hint), findsOneWidget);
  });

  testWidgets('input action tooltips do not block adjacent actions', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const EntropyVpnApp());
    await tester.pump();

    final pasteButton = find.ancestor(
      of: find.byIcon(Icons.content_paste_rounded),
      matching: find.byType(IconButton),
    );
    final addButton = find.ancestor(
      of: find.byIcon(Icons.add_rounded).last,
      matching: find.byType(IconButton),
    );
    expect(pasteButton, findsOneWidget);
    expect(addButton, findsOneWidget);
    final actionColumnRect = tester
        .getRect(pasteButton)
        .expandToInclude(tester.getRect(addButton));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(pasteButton));
    await tester.pumpAndSettle(const Duration(milliseconds: 700));

    final pasteTooltip = find.text('Paste from clipboard');
    expect(pasteTooltip, findsOneWidget);
    final pasteTooltipRect = tester.getRect(pasteTooltip);
    expect(pasteTooltipRect.overlaps(actionColumnRect), isFalse);
    expect(pasteTooltipRect.left, greaterThanOrEqualTo(actionColumnRect.right));

    await gesture.moveTo(tester.getCenter(addButton));
    await tester.pumpAndSettle(const Duration(milliseconds: 700));

    expect(find.text('Add'), findsOneWidget);

    await gesture.removePointer();
  });

  testWidgets('source card actions stay compact and centered on mobile', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(340, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _configController();

    try {
      await tester.pumpWidget(
        _subscriptionApp(
          controller,
          size: const Size(340, 820),
          textScaler: const TextScaler.linear(1.15),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final selectedIcon = find.byIcon(Icons.check_circle_rounded);
      final menuButton = find.ancestor(
        of: find.byIcon(Icons.more_horiz_rounded),
        matching: find.byType(IconButton),
      );

      expect(selectedIcon, findsOneWidget);
      expect(menuButton, findsOneWidget);
      expect(tester.getSize(menuButton), const Size.square(34));
      expect(
        tester.getCenter(menuButton).dx - tester.getCenter(selectedIcon).dx,
        closeTo(40, 0.1),
      );

      final sourceCard = find.ancestor(
        of: find.text('Config profile'),
        matching: find.byType(InkWell),
      );
      expect(sourceCard, findsOneWidget);
      expect(
        tester.getCenter(menuButton).dy,
        closeTo(tester.getCenter(selectedIcon).dy, 1),
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile subscription profiles render as a vertical config list', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final nl = String.fromCharCodes(<int>[0x1F1F3, 0x1F1F1]);
    final de = String.fromCharCodes(<int>[0x1F1E9, 0x1F1EA]);
    final controller = _subscriptionController(
      profiles: <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: '$nl Netherlands 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'de.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '22222222-2222-2222-2222-222222222222',
          remark: '$de Germany 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl-backup.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '33333333-3333-3333-3333-333333333333',
          remark: '$nl Netherlands 2',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('subscription'), findsOneWidget);
      expect(find.text('$nl Netherlands 1'), findsOneWidget);
      expect(find.text('$de Germany 1'), findsOneWidget);
      expect(find.text('$nl Netherlands 2'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

      final firstProfileCard = find.ancestor(
        of: find.text('$nl Netherlands 1'),
        matching: find.byType(InkWell),
      );
      final firstProfileFlag = find.byKey(
        const ValueKey<String>('mobile-profile-flag-subscription-0'),
      );
      expect(firstProfileCard, findsOneWidget);
      expect(firstProfileFlag, findsOneWidget);
      final firstProfileCardRect = tester.getRect(firstProfileCard);
      expect(
        tester.getRect(firstProfileFlag).center.dy,
        closeTo(firstProfileCardRect.center.dy - 8, 1),
      );
      final firstProfileFlagSize = tester.getSize(firstProfileFlag);
      expect(firstProfileFlagSize.height, 32);
      expect(firstProfileFlagSize.width / firstProfileFlagSize.height, 4 / 3);

      await tester.tap(find.text('$de Germany 1'));
      await tester.pumpAndSettle();

      expect(controller.previewProfile?.server, 'de.example.com');
    } finally {
      controller.dispose();
    }
  });

  testWidgets('desktop subscription groups render every imported profile', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1260, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _subscriptionController(
      profiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'de.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '22222222-2222-2222-2222-222222222222',
          remark: 'Germany 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.trojan,
          server: 'pl.example.com',
          port: 443,
          transport: TransportMode.ws,
          tlsMode: TlsMode.tls,
          password: 'secret',
          remark: 'Poland 1',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(1260, 720)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('subscription'), findsOneWidget);
      expect(find.text('Netherlands 1'), findsOneWidget);
      expect(find.text('Germany 1'), findsOneWidget);
      expect(find.text('Poland 1'), findsOneWidget);
      expect(find.byType(DropdownMenu<int>), findsNothing);

      await tester.tap(find.text('Germany 1'));
      await tester.pumpAndSettle();

      expect(controller.previewProfile?.server, 'de.example.com');
    } finally {
      controller.dispose();
    }
  });

  testWidgets('desktop source rail switches between category pages', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1180, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _multiSourceController(
      subscriptionProfiles: <ParsedVpnProfile>[
        for (var i = 0; i < 12; i += 1)
          ParsedVpnProfile(
            protocol: LinkProtocol.vless,
            server: 'nl-$i.example.com',
            port: 443,
            transport: TransportMode.raw,
            tlsMode: TlsMode.tls,
            userId: '11111111-1111-1111-1111-111111111111',
            remark: 'Netherlands ${i + 1}',
          ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(1180, 720)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final railFinder = find.byKey(
        const ValueKey<String>('desktop-source-page-rail'),
      );
      expect(railFinder, findsOneWidget);
      final railRect = tester.getRect(railFinder);
      expect(railRect.top, lessThan(170));
      expect(railRect.width, greaterThanOrEqualTo(40));
      expect(controller.selectedSource?.id, 'ethical');
      expect(find.text('ethical'), findsWidgets);
      expect(
        railRect.right,
        lessThan(tester.getRect(find.text('ethical').last).left),
      );
      expect(find.text('Netherlands 1'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('desktop-source-page-dot-1')),
      );
      await tester.pumpAndSettle();

      expect(controller.selectedSource?.id, 'ethical');
      expect(find.text('Netherlands 1'), findsOneWidget);
      expect(find.text('Netherlands 12'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
      final switchedRailRect = tester.getRect(railFinder);
      expect(switchedRailRect.top, lessThan(170));
      expect(
        switchedRailRect.right,
        lessThan(tester.getRect(find.text('Netherlands 1')).left),
      );

      await tester.tap(find.text('Netherlands 1'));
      await tester.pumpAndSettle();

      expect(controller.selectedSource?.id, 'subscription');
      expect(controller.selectedSource?.selectedProfileIndex, 0);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('desktop source rail is not clipped by short config pages', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(860, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _manyConfigSourceController();

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(860, 620)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final railFinder = find.byKey(
        const ValueKey<String>('desktop-source-page-rail'),
      );
      final pagerStackFinder = find.byKey(
        const ValueKey<String>('desktop-source-pager-stack'),
      );
      expect(railFinder, findsOneWidget);
      expect(pagerStackFinder, findsOneWidget);
      expect(find.text('Config 1'), findsOneWidget);

      final railRect = tester.getRect(railFinder);
      final pagerStackRect = tester.getRect(pagerStackFinder);
      expect(railRect.bottom, lessThanOrEqualTo(pagerStackRect.bottom + 0.1));

      await tester.tap(
        find.byKey(const ValueKey<String>('desktop-source-page-dot-4')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Config 5'), findsOneWidget);
      final switchedRailRect = tester.getRect(railFinder);
      final switchedPagerStackRect = tester.getRect(pagerStackFinder);
      expect(
        switchedRailRect.bottom,
        lessThanOrEqualTo(switchedPagerStackRect.bottom + 0.1),
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets('split power button stays fixed across source page selection', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1260, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _multiSourceController(
      subscriptionProfiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'de.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '22222222-2222-2222-2222-222222222222',
          remark: 'Germany 1',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(1260, 720)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      final powerButton = _powerButtonSurface();
      expect(powerButton, findsOneWidget);
      final initialRect = tester.getRect(powerButton);

      await tester.tap(
        find.byKey(const ValueKey<String>('desktop-source-page-dot-1')),
      );
      await tester.pumpAndSettle();
      final browsedRect = tester.getRect(powerButton);

      expect(browsedRect.top, closeTo(initialRect.top, 1));
      expect(browsedRect.center.dy, closeTo(initialRect.center.dy, 1));
      expect(controller.selectedSource?.id, 'ethical');

      await tester.tap(find.text('Netherlands 1'));
      await tester.pumpAndSettle();
      final selectedRect = tester.getRect(powerButton);

      expect(controller.selectedSource?.id, 'subscription');
      expect(selectedRect.top, closeTo(initialRect.top, 1));
      expect(selectedRect.center.dy, closeTo(initialRect.center.dy, 1));
    } finally {
      controller.dispose();
    }
  });

  testWidgets('split power button accepts taps across the visible circle', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1260, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _multiSourceController(
      runtimeService: _FakeCoreRuntimeService(),
      subscriptionProfiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands 1',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(1260, 720)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      final powerButton = _powerButtonSurface();
      expect(powerButton, findsOneWidget);

      final powerRect = tester.getRect(powerButton);
      await tester.tapAt(powerRect.topRight + const Offset(-18, 18));
      await tester.pumpAndSettle();

      expect(controller.phase, ConnectionPhase.disconnected);

      await tester.tapAt(powerRect.topCenter + const Offset(0, 18));
      await tester.pumpAndSettle();

      expect(controller.phase, ConnectionPhase.connected);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile subscription actions live in the group header', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _subscriptionController(
      profiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'de.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '22222222-2222-2222-2222-222222222222',
          remark: 'Germany 1',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('subscription'), findsOneWidget);
      expect(find.textContaining('Profiles found'), findsNothing);
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

      final menuButton = find.ancestor(
        of: find.byIcon(Icons.more_horiz_rounded),
        matching: find.byType(IconButton),
      );
      expect(menuButton, findsOneWidget);

      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      expect(find.text('Update'), findsOneWidget);
      expect(
        find.textContaining('Auto-update', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Remove'), findsOneWidget);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile subscription header prefers URL fragment names', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _subscriptionController(
      rawInput: 'https://ru.api.blook.so/sub/176449930893983717#BlookVPN',
      displayName: '176449930893983717',
      profiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'de.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '22222222-2222-2222-2222-222222222222',
          remark: 'Germany 1',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('BlookVPN'), findsOneWidget);
      expect(find.text('176449930893983717'), findsNothing);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile sources swipe between subscription sub-pages', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final nl = String.fromCharCodes(<int>[0x1F1F3, 0x1F1F1]);
    final controller = _multiSourceController(
      subscriptionProfiles: <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: '$nl Netherlands 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl-backup.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '22222222-2222-2222-2222-222222222222',
          remark: '$nl Netherlands 2',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.selectedSource?.id, 'ethical');

      await tester.drag(
        find.byKey(
          const ValueKey<String>('mobile-connect-source-bottom-swipe-area'),
        ),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();

      expect(controller.selectedSource?.id, 'ethical');
      expect(controller.previewProfile?.server, 'ethical.example.com');
      expect(find.text('$nl Netherlands 1'), findsWidgets);
      expect(find.text('$nl Netherlands 2'), findsOneWidget);

      await tester.tap(find.text('$nl Netherlands 2'));
      await tester.pumpAndSettle();

      expect(controller.selectedSource?.id, 'subscription');
      expect(controller.previewProfile?.server, 'nl-backup.example.com');
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile source pager swipes while VPN is connected', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _multiSourceController(
      runtimeService: _FakeCoreRuntimeService(),
      subscriptionProfiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands',
        ),
      ],
    );

    try {
      await controller.connect();
      expect(controller.isConnected, isTrue);

      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final sourcePager = find.byKey(
        const ValueKey<String>('mobile-connect-source-bottom-swipe-area'),
      );
      expect(sourcePager, findsOneWidget);
      expect(
        tester.widget<PageView>(sourcePager).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );

      await tester.drag(sourcePager, const Offset(-320, 0));
      await tester.pumpAndSettle();

      expect(find.text('Netherlands'), findsOneWidget);
      expect(tester.getRect(find.text('Netherlands')).left, lessThan(390));
      expect(controller.selectedSource?.id, 'ethical');
      expect(controller.previewProfile?.server, 'ethical.example.com');

      await tester.tap(find.text('Netherlands'));
      await tester.pumpAndSettle();

      expect(controller.selectedSource?.id, 'ethical');
      expect(controller.previewProfile?.server, 'ethical.example.com');
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile lower source zone stays on source pager', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _multiSourceController(
      subscriptionProfiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final sourcePager = find.byKey(
        const ValueKey<String>('mobile-connect-source-bottom-swipe-area'),
      );
      final sourceCard = find.ancestor(
        of: find.text('ethical'),
        matching: find.byType(InkWell),
      );
      expect(sourcePager, findsOneWidget);
      expect(sourceCard, findsOneWidget);

      final pagerRect = tester.getRect(sourcePager);
      final cardRect = tester.getRect(sourceCard);
      final swipeStart = Offset(pagerRect.right - 56, cardRect.bottom + 42);

      expect(pagerRect.contains(swipeStart), isTrue);

      await tester.dragFrom(swipeStart, const Offset(-320, 0));
      await tester.pumpAndSettle();

      expect(find.text('Import from JSON'), findsNothing);
      expect(find.text('Netherlands'), findsOneWidget);
      expect(controller.selectedSource?.id, 'ethical');
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile top-area vertical swipe does not scroll hero away', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _subscriptionController(
      profiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'jp.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.reality,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Japan 1',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'tr.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.reality,
          userId: '22222222-2222-2222-2222-222222222222',
          remark: 'Turkey 8',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'tr-backup.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.reality,
          userId: '33333333-3333-3333-3333-333333333333',
          remark: 'Turkey Reserve 2',
        ),
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'fr.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.reality,
          userId: '44444444-4444-4444-4444-444444444444',
          remark: 'France 1',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final powerButton = _powerButtonSurface();
      final statusLabel = find.text('Disconnected');
      final firstProfile = find.text('Japan 1');

      expect(powerButton, findsOneWidget);
      expect(statusLabel, findsOneWidget);
      expect(firstProfile, findsOneWidget);

      final initialPowerRect = tester.getRect(powerButton);
      final initialStatusRect = tester.getRect(statusLabel);
      final initialProfileRect = tester.getRect(firstProfile);
      final swipeStart = Offset(
        initialPowerRect.center.dx,
        initialPowerRect.top - 8,
      );

      await tester.dragFrom(swipeStart, const Offset(0, -260));
      await tester.pumpAndSettle();

      final currentPowerRect = tester.getRect(powerButton);
      final currentStatusRect = tester.getRect(statusLabel);
      final currentProfileRect = tester.getRect(firstProfile);

      expect(currentPowerRect.top, closeTo(initialPowerRect.top, 1));
      expect(currentStatusRect.top, closeTo(initialStatusRect.top, 1));
      expect(currentProfileRect.top, closeTo(initialProfileRect.top, 1));
      expect(currentStatusRect.bottom, lessThan(currentProfileRect.top));
    } finally {
      controller.dispose();
    }
  });

  testWidgets('mobile top swipe still changes main pages', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _multiSourceController(
      subscriptionProfiles: const <ParsedVpnProfile>[
        ParsedVpnProfile(
          protocol: LinkProtocol.vless,
          server: 'nl.example.com',
          port: 443,
          transport: TransportMode.raw,
          tlsMode: TlsMode.tls,
          userId: '11111111-1111-1111-1111-111111111111',
          remark: 'Netherlands',
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.dragFrom(const Offset(195, 360), const Offset(-320, 0));
      await tester.pumpAndSettle();

      expect(find.text('Import from JSON'), findsOneWidget);
    } finally {
      controller.dispose();
    }
  });

  testWidgets(
    'power control and status align with config card in split layout',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1260, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = _subscriptionController(
        trafficUsage: const SubscriptionTrafficUsage(
          uploadBytes: 0,
          downloadBytes: 5 * 1024 * 1024 * 1024,
          totalBytes: 10 * 1024 * 1024 * 1024,
        ),
      );

      try {
        await tester.pumpWidget(
          _subscriptionApp(controller, size: const Size(1260, 720)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        final powerButton = _powerButtonSurface();
        final sourceCard = find.byKey(
          const GlobalObjectKey('split-first-source-card'),
        );
        final statusLabel = find.text('Disconnected');

        expect(powerButton, findsOneWidget);
        expect(sourceCard, findsOneWidget);
        expect(statusLabel, findsOneWidget);

        final sourceCardRect = tester.getRect(sourceCard);
        final powerButtonRect = tester.getRect(powerButton);
        final statusLabelRect = tester.getRect(statusLabel);
        final topOverhang = sourceCardRect.top - powerButtonRect.top;
        final bottomOverhang = powerButtonRect.bottom - sourceCardRect.bottom;

        expect(powerButtonRect.left, greaterThan(0));
        expect(powerButtonRect.width, closeTo(196, 1));
        expect(powerButtonRect.height, closeTo(196, 1));
        expect(
          statusLabelRect.center.dx,
          closeTo(powerButtonRect.center.dx, 1),
        );
        expect(statusLabelRect.top, greaterThan(powerButtonRect.bottom));
        expect(powerButtonRect.top, lessThan(sourceCardRect.top));
        expect(powerButtonRect.bottom, greaterThan(sourceCardRect.bottom));
        expect(topOverhang, closeTo(bottomOverhang, 2));
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('subscription card shows traffic usage when available', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _subscriptionController(
      trafficUsage: const SubscriptionTrafficUsage(
        uploadBytes: 1024 * 1024 * 1024,
        downloadBytes: 4 * 1024 * 1024 * 1024,
        totalBytes: 10 * 1024 * 1024 * 1024,
      ),
    );

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('5 GB / 10 GB'), findsOneWidget);
      expect(find.text('5 GB left'), findsNothing);
    } finally {
      controller.dispose();
    }
  });

  testWidgets(
    'mobile subscription group keeps traffic bar above profile rows',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(340, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = _subscriptionController(
        trafficUsage: const SubscriptionTrafficUsage(
          uploadBytes: 1024 * 1024 * 1024,
          downloadBytes: 4 * 1024 * 1024 * 1024,
          totalBytes: 10 * 1024 * 1024 * 1024,
        ),
        profiles: const <ParsedVpnProfile>[
          ParsedVpnProfile(
            protocol: LinkProtocol.vless,
            server: 'ethical.example.com',
            port: 443,
            transport: TransportMode.raw,
            tlsMode: TlsMode.reality,
            userId: '11111111-1111-1111-1111-111111111111',
            remark: 'ethical',
          ),
        ],
      );

      try {
        await tester.pumpWidget(
          _subscriptionApp(
            controller,
            size: const Size(340, 820),
            textScaler: const TextScaler.linear(1.25),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final sourceCard = find.ancestor(
          of: find.text('ethical'),
          matching: find.byType(InkWell),
        );
        final trafficLabel = find.text('5 GB / 10 GB');

        expect(sourceCard, findsOneWidget);
        expect(trafficLabel, findsOneWidget);

        final cardRect = tester.getRect(sourceCard);
        final trafficRect = tester.getRect(trafficLabel);

        expect(trafficRect.bottom, lessThan(cardRect.top));
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('auto-update slider menu does not reserve dead space', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _subscriptionController();

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final menuButton = find.ancestor(
        of: find.byIcon(Icons.more_horiz_rounded),
        matching: find.byType(IconButton),
      );
      expect(menuButton, findsOneWidget);

      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      final slider = find.byType(Slider);
      final exportJsonAction = find.text('Save as JSON');
      expect(slider, findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsNothing);
      expect(
        find.textContaining('Auto-update', findRichText: true),
        findsOneWidget,
      );
      expect(exportJsonAction, findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);

      final sliderRect = tester.getRect(slider);
      final exportJsonActionRect = tester.getRect(exportJsonAction);
      expect(
        exportJsonActionRect.top - sliderRect.bottom,
        lessThanOrEqualTo(28),
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets('config cards expose save as JSON in their menu', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = _configController();

    try {
      await tester.pumpWidget(
        _subscriptionApp(controller, size: const Size(390, 820)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final menuButton = find.ancestor(
        of: find.byIcon(Icons.more_horiz_rounded),
        matching: find.byType(IconButton),
      );
      expect(menuButton, findsOneWidget);

      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      expect(find.text('Save as JSON'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    } finally {
      controller.dispose();
    }
  });
}

VpnController _subscriptionController({
  SubscriptionTrafficUsage? trafficUsage,
  String rawInput = 'https://example.com/subscription',
  String? displayName,
  List<ParsedVpnProfile> profiles = const <ParsedVpnProfile>[
    ParsedVpnProfile(
      protocol: LinkProtocol.vless,
      server: '209.99.191.16',
      port: 443,
      transport: TransportMode.raw,
      tlsMode: TlsMode.tls,
      userId: '11111111-1111-1111-1111-111111111111',
      remark: 'Sing-box config',
    ),
  ],
}) {
  return VpnController(
    appStateStore: _WidgetMemoryAppStateStore(
      PersistedAppState(
        language: AppLanguage.en,
        trafficMode: TrafficMode.tun,
        tunIpMode: TunIpMode.dualStack,
        selectedSourceId: 'subscription',
        sources: <ConfigSource>[
          ConfigSource(
            id: 'subscription',
            rawInput: rawInput,
            kind: ConfigSourceKind.subscription,
            displayName: displayName,
            profiles: profiles,
            lastUpdatedAt: DateTime(2026, 5, 1),
            trafficUsage: trafficUsage,
          ),
        ],
      ),
    ),
  );
}

VpnController _configController() {
  return VpnController(
    appStateStore: _WidgetMemoryAppStateStore(
      PersistedAppState(
        language: AppLanguage.en,
        trafficMode: TrafficMode.systemProxy,
        tunIpMode: TunIpMode.ipv4,
        selectedSourceId: 'config',
        sources: const <ConfigSource>[
          ConfigSource(
            id: 'config',
            rawInput:
                'vless://11111111-1111-1111-1111-111111111111@example.com',
            kind: ConfigSourceKind.config,
            profiles: <ParsedVpnProfile>[
              ParsedVpnProfile(
                protocol: LinkProtocol.vless,
                server: 'example.com',
                port: 443,
                transport: TransportMode.raw,
                tlsMode: TlsMode.tls,
                userId: '11111111-1111-1111-1111-111111111111',
                remark: 'Config profile',
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

VpnController _manyConfigSourceController() {
  return VpnController(
    appStateStore: _WidgetMemoryAppStateStore(
      PersistedAppState(
        language: AppLanguage.en,
        trafficMode: TrafficMode.systemProxy,
        tunIpMode: TunIpMode.ipv4,
        selectedSourceId: 'config-0',
        sources: <ConfigSource>[
          for (var index = 0; index < 5; index += 1)
            ConfigSource(
              id: 'config-$index',
              rawInput:
                  'vless://11111111-1111-1111-1111-111111111111@config-$index.example.com',
              kind: ConfigSourceKind.config,
              profiles: <ParsedVpnProfile>[
                ParsedVpnProfile(
                  protocol: LinkProtocol.vless,
                  server: 'config-$index.example.com',
                  port: 443,
                  transport: TransportMode.raw,
                  tlsMode: TlsMode.reality,
                  userId: '11111111-1111-1111-1111-111111111111',
                  remark: 'Config ${index + 1}',
                ),
              ],
            ),
        ],
      ),
    ),
  );
}

VpnController _multiSourceController({
  required List<ParsedVpnProfile> subscriptionProfiles,
  CoreRuntimeService? runtimeService,
}) {
  return VpnController(
    runtimeService: runtimeService,
    appStateStore: _WidgetMemoryAppStateStore(
      PersistedAppState(
        language: AppLanguage.en,
        trafficMode: TrafficMode.tun,
        tunIpMode: TunIpMode.dualStack,
        selectedSourceId: 'ethical',
        sources: <ConfigSource>[
          const ConfigSource(
            id: 'ethical',
            rawInput: 'https://example.com/ethical.json',
            kind: ConfigSourceKind.config,
            profiles: <ParsedVpnProfile>[
              ParsedVpnProfile(
                protocol: LinkProtocol.vless,
                server: 'ethical.example.com',
                port: 443,
                transport: TransportMode.raw,
                tlsMode: TlsMode.reality,
                userId: '00000000-0000-0000-0000-000000000000',
                remark: 'ethical',
              ),
            ],
          ),
          ConfigSource(
            id: 'subscription',
            rawInput: 'https://example.com/subscription',
            kind: ConfigSourceKind.subscription,
            profiles: subscriptionProfiles,
            lastUpdatedAt: DateTime(2026, 5, 1),
          ),
        ],
      ),
    ),
  );
}

class _FakeCoreRuntimeService extends CoreRuntimeService {
  @override
  Future<void> start({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TrafficMode trafficMode,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
  }) async {}

  @override
  Future<void> stop() async {}
}

Widget _subscriptionApp(
  VpnController controller, {
  required Size size,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MediaQuery(
    data: MediaQueryData(size: size, textScaler: textScaler),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        platform: TargetPlatform.android,
      ),
      home: VpnHomePage(controller: controller),
    ),
  );
}

class _WidgetMemoryAppStateStore extends AppStateStore {
  _WidgetMemoryAppStateStore([this.state]);

  PersistedAppState? state;

  @override
  Future<PersistedAppState?> load() async => state;

  @override
  Future<void> save(PersistedAppState state) async {
    this.state = state;
  }
}
