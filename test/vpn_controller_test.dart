import 'dart:io';

import 'package:entropy_vpn/models/config_source.dart';
import 'package:entropy_vpn/models/split_tunnel.dart';
import 'package:entropy_vpn/models/vpn_profile.dart';
import 'package:entropy_vpn/services/app_state_store.dart';
import 'package:entropy_vpn/services/core_runtime_service.dart';
import 'package:entropy_vpn/services/profile_catalog_service.dart';
import 'package:entropy_vpn/services/vpn_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses profile core selection in desktop TUN mode', () async {
    final controller = VpnController(appStateStore: _MemoryAppStateStore());
    addTearDown(controller.dispose);

    await controller.setTrafficMode(TrafficMode.tun);

    const xrayProfile = ParsedVpnProfile(
      protocol: LinkProtocol.vless,
      server: 'xray.example.com',
      port: 443,
      transport: TransportMode.raw,
      tlsMode: TlsMode.reality,
      userId: '11111111-1111-1111-1111-111111111111',
      publicKey: 'publicKey',
    );
    final singBoxProfile = ParsedVpnProfile.singBoxConfig(
      configJson: '{"inbounds":[],"outbounds":[]}',
      remark: 'Native sing-box',
    );

    expect(controller.coreForProfile(xrayProfile), CoreFlavor.xray);
    expect(controller.coreForProfile(singBoxProfile), CoreFlavor.singBox);
  });

  test(
    'reports native config cores and stable display cores separately',
    () async {
      final controller = VpnController(appStateStore: _MemoryAppStateStore());
      addTearDown(controller.dispose);

      const shareLinkProfile = ParsedVpnProfile(
        protocol: LinkProtocol.vless,
        server: 'profile.example.com',
        port: 443,
        transport: TransportMode.raw,
        tlsMode: TlsMode.tls,
      );
      final singBoxProfile = ParsedVpnProfile.singBoxConfig(
        configJson: '{"route":{},"outbounds":[{"type":"direct"}]}',
      );
      final xrayProfile = ParsedVpnProfile.xrayConfig(
        configJson: '{"routing":{},"outbounds":[{"protocol":"freedom"}]}',
      );

      await controller.setTrafficMode(TrafficMode.tun);

      expect(controller.configCoreForProfile(shareLinkProfile), isNull);
      expect(
        controller.configCoreForProfile(singBoxProfile),
        CoreFlavor.singBox,
      );
      expect(controller.configCoreForProfile(xrayProfile), CoreFlavor.xray);
      expect(controller.coreForProfile(shareLinkProfile), CoreFlavor.xray);
      expect(
        controller.displayCoreForProfile(shareLinkProfile),
        CoreFlavor.xray,
      );
      expect(
        controller.displayCoreForProfile(singBoxProfile),
        CoreFlavor.singBox,
      );
      expect(controller.displayCoreForProfile(xrayProfile), CoreFlavor.xray);
      expect(controller.coreForProfile(xrayProfile), CoreFlavor.xray);
    },
  );

  test('does not remove the source used by the active VPN connection', () async {
    final controller = VpnController(
      appStateStore: _MemoryAppStateStore(),
      runtimeService: _FakeCoreRuntimeService(),
    );
    addTearDown(controller.dispose);

    const activeInput =
        'vless://11111111-1111-1111-1111-111111111111@active.example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsocket&sni=server.example.com#Active';
    const inactiveInput =
        'ss://YWVzLTI1Ni1nY206c2VjcmV0QGluYWN0aXZlLmV4YW1wbGUuY29tOjgzODg=#Inactive';

    controller.setRawInput(activeInput);
    await controller.addSource();
    final activeSourceId = controller.sources.single.id;

    controller.setRawInput(inactiveInput);
    await controller.addSource();
    final inactiveSourceId = controller.sources
        .firstWhere((source) => source.id != activeSourceId)
        .id;

    controller.selectSource(activeSourceId);
    await controller.connect();

    expect(controller.isConnected, isTrue);
    expect(controller.canRemoveSource(activeSourceId), isFalse);
    expect(controller.canRemoveSource(inactiveSourceId), isTrue);

    await controller.removeSource(activeSourceId);
    expect(
      controller.sources.map((source) => source.id),
      contains(activeSourceId),
    );

    await controller.removeSource(inactiveSourceId);
    expect(controller.sources.map((source) => source.id), <String>[
      activeSourceId,
    ]);
  });

  test('shutdown for exit waits for runtime cleanup', () async {
    final runtimeService = _RecordingCoreRuntimeService();
    final controller = VpnController(
      appStateStore: _MemoryAppStateStore(),
      runtimeService: runtimeService,
    );
    addTearDown(controller.dispose);

    await controller.shutdownForExit();

    expect(runtimeService.stopWaitForCleanupValues, <bool>[true]);
    expect(controller.isConnected, isFalse);
  });

  test('auto-adds valid pasted source input silently', () async {
    final controller = VpnController(appStateStore: _MemoryAppStateStore());
    addTearDown(controller.dispose);

    const input =
        'vless://11111111-1111-1111-1111-111111111111@pasted.example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsocket&sni=server.example.com#Pasted';

    final added = await controller.pasteSourceInput(input);

    expect(added, isTrue);
    expect(controller.sources, hasLength(1));
    expect(controller.sources.single.rawInput, input);
    expect(controller.rawInput, isEmpty);
    expect(controller.previewError, isNull);
    expect(controller.didAddSourceRecently, isTrue);
    expect(controller.recentAddSuccessTarget, AddSourceSuccessTarget.paste);
  });

  test('manual add reports add button success target', () async {
    final controller = VpnController(appStateStore: _MemoryAppStateStore());
    addTearDown(controller.dispose);

    const input =
        'vless://11111111-1111-1111-1111-111111111111@manual.example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsocket&sni=server.example.com#Manual';

    controller.setRawInput(input);
    final added = await controller.addSource();

    expect(added, isTrue);
    expect(controller.didAddSourceRecently, isTrue);
    expect(controller.recentAddSuccessTarget, AddSourceSuccessTarget.add);
  });

  test('TCP ping records latency for the selected profile', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final socketSubscription = server.listen((socket) {
      socket.destroy();
    });
    addTearDown(() async {
      await socketSubscription.cancel();
      await server.close();
    });

    final controller = VpnController(
      appStateStore: _MemoryAppStateStore(
        PersistedAppState(
          language: AppLanguage.en,
          trafficMode: TrafficMode.systemProxy,
          tunIpMode: TunIpMode.ipv4,
          selectedSourceId: 'local',
          sources: <ConfigSource>[
            ConfigSource(
              id: 'local',
              rawInput: 'vless://local',
              kind: ConfigSourceKind.config,
              profiles: <ParsedVpnProfile>[
                ParsedVpnProfile(
                  protocol: LinkProtocol.vless,
                  server: InternetAddress.loopbackIPv4.address,
                  port: server.port,
                  transport: TransportMode.raw,
                  tlsMode: TlsMode.tls,
                  userId: '11111111-1111-1111-1111-111111111111',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);

    await controller.pingSource('local');

    final source = controller.sources.single;
    expect(source.isPinging, isFalse);
    expect(source.tcpPingProfileIndex, 0);
    expect(source.tcpPingLatencyMs, isNotNull);
    expect(source.tcpPingLatencyMs!, greaterThan(0));
    expect(controller.runtimeError, isNull);
  });

  test('TCP ping records latency for every subscription profile', () async {
    final firstServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final secondServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final firstSubscription = firstServer.listen((socket) {
      socket.destroy();
    });
    final secondSubscription = secondServer.listen((socket) {
      socket.destroy();
    });
    addTearDown(() async {
      await firstSubscription.cancel();
      await secondSubscription.cancel();
      await firstServer.close();
      await secondServer.close();
    });

    final controller = VpnController(
      appStateStore: _MemoryAppStateStore(
        PersistedAppState(
          language: AppLanguage.en,
          trafficMode: TrafficMode.systemProxy,
          tunIpMode: TunIpMode.ipv4,
          selectedSourceId: 'subscription',
          sources: <ConfigSource>[
            ConfigSource(
              id: 'subscription',
              rawInput: 'https://example.com/subscription',
              kind: ConfigSourceKind.subscription,
              profiles: <ParsedVpnProfile>[
                ParsedVpnProfile(
                  protocol: LinkProtocol.vless,
                  server: InternetAddress.loopbackIPv4.address,
                  port: firstServer.port,
                  transport: TransportMode.raw,
                  tlsMode: TlsMode.tls,
                  userId: '11111111-1111-1111-1111-111111111111',
                  remark: 'First',
                ),
                ParsedVpnProfile(
                  protocol: LinkProtocol.vless,
                  server: InternetAddress.loopbackIPv4.address,
                  port: secondServer.port,
                  transport: TransportMode.raw,
                  tlsMode: TlsMode.tls,
                  userId: '22222222-2222-2222-2222-222222222222',
                  remark: 'Second',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);

    await controller.pingSource('subscription');

    final source = controller.sources.single;
    expect(source.isPinging, isFalse);
    expect(source.tcpPingLatenciesMs.keys, containsAll(<int>[0, 1]));
    expect(source.tcpPingLatencyForProfile(0), isNotNull);
    expect(source.tcpPingLatencyForProfile(1), isNotNull);
    expect(source.tcpPingLatencyForProfile(0), greaterThan(0));
    expect(source.tcpPingLatencyForProfile(1), greaterThan(0));
    expect(controller.runtimeError, isNull);
  });

  test('TCP ping asks runtime to prepare bypass routes for targets', () async {
    final firstServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final secondServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final firstSubscription = firstServer.listen((socket) {
      socket.destroy();
    });
    final secondSubscription = secondServer.listen((socket) {
      socket.destroy();
    });
    addTearDown(() async {
      await firstSubscription.cancel();
      await secondSubscription.cancel();
      await firstServer.close();
      await secondServer.close();
    });

    final runtimeService = _RecordingTcpPingBypassRuntimeService();
    final controller = VpnController(
      runtimeService: runtimeService,
      appStateStore: _MemoryAppStateStore(
        PersistedAppState(
          language: AppLanguage.en,
          trafficMode: TrafficMode.tun,
          tunIpMode: TunIpMode.ipv4,
          selectedSourceId: 'subscription',
          sources: <ConfigSource>[
            ConfigSource(
              id: 'subscription',
              rawInput: 'https://example.com/subscription',
              kind: ConfigSourceKind.subscription,
              profiles: <ParsedVpnProfile>[
                ParsedVpnProfile(
                  protocol: LinkProtocol.vless,
                  server: InternetAddress.loopbackIPv4.address,
                  port: firstServer.port,
                  transport: TransportMode.raw,
                  tlsMode: TlsMode.tls,
                  userId: '11111111-1111-1111-1111-111111111111',
                  remark: 'First',
                ),
                ParsedVpnProfile(
                  protocol: LinkProtocol.vless,
                  server: InternetAddress.loopbackIPv4.address,
                  port: secondServer.port,
                  transport: TransportMode.raw,
                  tlsMode: TlsMode.tls,
                  userId: '22222222-2222-2222-2222-222222222222',
                  remark: 'Second',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);

    await controller.pingSource('subscription');

    expect(runtimeService.tcpPingBypassTrafficModes, <TrafficMode>[
      TrafficMode.tun,
    ]);
    expect(runtimeService.tcpPingBypassTunIpModes, <TunIpMode>[TunIpMode.ipv4]);
    expect(runtimeService.tcpPingBypassPorts.single, <int>[
      firstServer.port,
      secondServer.port,
    ]);
  });

  test('refreshDueSubscriptions respects per-source intervals', () async {
    final now = DateTime.now();
    final staleUpdate = now.subtract(const Duration(hours: 2));
    final recentUpdate = now.subtract(const Duration(minutes: 30));
    final catalogService = _FakeProfileCatalogService();
    final controller = VpnController(
      appStateStore: _MemoryAppStateStore(
        PersistedAppState(
          language: AppLanguage.en,
          trafficMode: TrafficMode.systemProxy,
          tunIpMode: TunIpMode.ipv4,
          selectedSourceId: 'stale',
          sources: <ConfigSource>[
            ConfigSource(
              id: 'stale',
              rawInput: 'https://stale.example/sub',
              kind: ConfigSourceKind.subscription,
              profiles: <ParsedVpnProfile>[_profileFor('stale.example')],
              lastUpdatedAt: staleUpdate,
              autoUpdateIntervalMinutes: 60,
            ),
            ConfigSource(
              id: 'recent',
              rawInput: 'https://recent.example/sub',
              kind: ConfigSourceKind.subscription,
              profiles: <ParsedVpnProfile>[_profileFor('recent.example')],
              lastUpdatedAt: recentUpdate,
              autoUpdateIntervalMinutes: 60,
            ),
          ],
        ),
      ),
      profileCatalogService: catalogService,
    );
    addTearDown(controller.dispose);

    await controller.refreshDueSubscriptions();

    expect(catalogService.resolvedInputs, <String>[
      'https://stale.example/sub',
    ]);
    expect(
      controller.sources
          .firstWhere((source) => source.id == 'stale')
          .lastUpdatedAt!
          .isAfter(staleUpdate),
      isTrue,
    );
    expect(
      controller.sources
          .firstWhere((source) => source.id == 'recent')
          .lastUpdatedAt,
      recentUpdate,
    );
  });

  test('pastes invalid clipboard text without showing an add error', () async {
    final controller = VpnController(appStateStore: _MemoryAppStateStore());
    addTearDown(controller.dispose);

    const input = 'remember to update the server list later';

    final added = await controller.pasteSourceInput(input);

    expect(added, isFalse);
    expect(controller.sources, isEmpty);
    expect(controller.rawInput, input);
    expect(controller.previewError, isNull);
  });

  testWidgets('add source errors clear after three seconds', (tester) async {
    final controller = VpnController(appStateStore: _MemoryAppStateStore());

    try {
      final added = await controller.addSource();

      expect(added, isFalse);
      expect(controller.previewError, isNotNull);

      await tester.pump(const Duration(seconds: 3));

      expect(controller.previewError, isNull);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('connection errors clear phase after three seconds', (
    tester,
  ) async {
    final controller = VpnController(
      appStateStore: _MemoryAppStateStore(),
      runtimeService: _ThrowingCoreRuntimeService(),
    );

    try {
      const input =
          'vless://11111111-1111-1111-1111-111111111111@failed.example.com:443?encryption=none&security=tls&type=ws&host=cdn.example.com&path=%2Fsocket&sni=server.example.com#Failed';

      controller.setRawInput(input);
      expect(await controller.addSource(), isTrue);

      await controller.connect();

      expect(controller.phase, ConnectionPhase.error);
      expect(controller.runtimeError, contains('Connection failed.'));

      await tester.pump(const Duration(seconds: 3));

      expect(controller.runtimeError, isNull);
      expect(controller.phase, ConnectionPhase.disconnected);
    } finally {
      controller.dispose();
    }
  });
}

ParsedVpnProfile _profileFor(String server) {
  return ParsedVpnProfile(
    protocol: LinkProtocol.vless,
    server: server,
    port: 443,
    transport: TransportMode.ws,
    tlsMode: TlsMode.tls,
    userId: '11111111-1111-1111-1111-111111111111',
  );
}

class _MemoryAppStateStore extends AppStateStore {
  _MemoryAppStateStore([this.state]);

  PersistedAppState? state;

  @override
  Future<PersistedAppState?> load() async => state;

  @override
  Future<void> save(PersistedAppState state) async {
    this.state = state;
  }
}

class _FakeProfileCatalogService extends ProfileCatalogService {
  final List<String> resolvedInputs = <String>[];

  @override
  Future<ResolvedProfileCatalog> resolve(String rawInput) async {
    resolvedInputs.add(rawInput);
    return ResolvedProfileCatalog(
      profiles: <ParsedVpnProfile>[
        _profileFor(Uri.tryParse(rawInput)?.host ?? 'updated.example'),
      ],
      isSubscription: true,
    );
  }
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
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
  }) async {}

  @override
  Future<void> stop({bool waitForCleanup = false}) async {}
}

class _RecordingCoreRuntimeService extends _FakeCoreRuntimeService {
  final List<bool> stopWaitForCleanupValues = <bool>[];

  @override
  Future<void> stop({bool waitForCleanup = false}) async {
    stopWaitForCleanupValues.add(waitForCleanup);
  }
}

class _RecordingTcpPingBypassRuntimeService extends _FakeCoreRuntimeService {
  final List<TrafficMode> tcpPingBypassTrafficModes = <TrafficMode>[];
  final List<TunIpMode> tcpPingBypassTunIpModes = <TunIpMode>[];
  final List<List<int>> tcpPingBypassPorts = <List<int>>[];

  @override
  Future<T> withTcpPingBypassRoutes<T>({
    required Iterable<ParsedVpnProfile> profiles,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required Future<T> Function() action,
  }) async {
    final profileList = profiles.toList(growable: false);
    tcpPingBypassTrafficModes.add(trafficMode);
    tcpPingBypassTunIpModes.add(tunIpMode);
    tcpPingBypassPorts.add(
      profileList.map((profile) => profile.port).toList(growable: false),
    );
    return action();
  }
}

class _ThrowingCoreRuntimeService extends CoreRuntimeService {
  @override
  Future<void> start({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TrafficMode trafficMode,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
  }) async {
    throw StateError('Connection failed.');
  }

  @override
  Future<void> stop({bool waitForCleanup = false}) async {}
}
