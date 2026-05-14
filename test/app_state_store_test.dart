import 'dart:convert';
import 'dart:io';

import 'package:entropy_vpn/models/config_source.dart';
import 'package:entropy_vpn/models/dns_settings.dart';
import 'package:entropy_vpn/models/split_tunnel.dart';
import 'package:entropy_vpn/models/vpn_profile.dart';
import 'package:entropy_vpn/services/app_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('PersistedAppState round-trips sources and settings', () {
    const profile = ParsedVpnProfile(
      protocol: LinkProtocol.vless,
      server: 'example.com',
      port: 443,
      transport: TransportMode.ws,
      tlsMode: TlsMode.reality,
      remark: 'demo',
      userId: 'uuid',
      host: 'cdn.example.com',
      path: '/ws',
      publicKey: 'pub',
      shortId: 'ab12',
    );

    final state = PersistedAppState(
      language: AppLanguage.ru,
      trafficMode: TrafficMode.tun,
      tunIpMode: TunIpMode.dualStack,
      selectedSourceId: 'source-1',
      dnsSettings: const DnsSettings(
        ipv4Servers: <String>['9.9.9.9', '149.112.112.112'],
        ipv6Servers: <String>['2620:fe::fe', '2620:fe::9'],
      ),
      splitTunnelSettings: const SplitTunnelSettings(
        mode: SplitTunnelMode.blacklist,
        apps: <SplitTunnelApp>[
          SplitTunnelApp(
            id: r'c:\apps\browser.exe',
            name: 'Browser',
            path: r'C:\Apps\browser.exe',
          ),
        ],
      ),
      domainSplitTunnelSettings: DomainSplitTunnelSettings(
        mode: SplitTunnelMode.whitelist,
        domains: <SplitTunnelDomain>[
          SplitTunnelDomain.fromInput('www.Example.ru'),
          SplitTunnelDomain.fromInput('*.рф'),
        ],
      ),
      appUpdateLastCheckedAt: DateTime.utc(2026, 5, 12, 10),
      lastShownAppUpdateTag: 'v1.3.2',
      lastShownAndroidAppUpdateTag: 'v1.3.3',
      showInAppUpdateNotifications: false,
      showAndroidUpdateNotifications: false,
      subscriptionDeviceId: 'entropyvpn-test-device',
      sources: <ConfigSource>[
        ConfigSource(
          id: 'source-1',
          rawInput: 'vless://demo',
          kind: ConfigSourceKind.config,
          profiles: const <ParsedVpnProfile>[profile],
          selectedProfileIndex: 0,
        ),
        ConfigSource(
          id: 'source-2',
          rawInput: 'https://subscriptions.example.com/list',
          kind: ConfigSourceKind.subscription,
          displayName: 'Demo Subscription',
          autoUpdateIntervalMinutes: 120,
          trafficUsage: SubscriptionTrafficUsage(
            uploadBytes: 1024 * 1024 * 1024,
            downloadBytes: 4 * 1024 * 1024 * 1024,
            totalBytes: 10 * 1024 * 1024 * 1024,
            expiresAt: DateTime.utc(2026, 5, 15),
          ),
        ),
      ],
    );

    final restored = PersistedAppState.fromJson(
      Map<String, dynamic>.from(state.toJson()),
    );

    expect(restored.language, AppLanguage.ru);
    expect(restored.trafficMode, TrafficMode.tun);
    expect(restored.tunIpMode, TunIpMode.dualStack);
    expect(restored.dnsSettings.ipv4Servers, <String>[
      '9.9.9.9',
      '149.112.112.112',
    ]);
    expect(restored.dnsSettings.ipv6Servers, <String>[
      '2620:fe::fe',
      '2620:fe::9',
    ]);
    expect(restored.selectedSourceId, 'source-1');
    expect(restored.splitTunnelSettings.mode, SplitTunnelMode.blacklist);
    expect(restored.splitTunnelSettings.apps.single.name, 'Browser');
    expect(
      restored.splitTunnelSettings.apps.single.path,
      r'C:\Apps\browser.exe',
    );
    expect(restored.domainSplitTunnelSettings.mode, SplitTunnelMode.whitelist);
    expect(
      restored.domainSplitTunnelSettings.domains.map((domain) => domain.value),
      <String>['example.ru', '*.рф'],
    );
    expect(restored.appUpdateLastCheckedAt, DateTime.utc(2026, 5, 12, 10));
    expect(restored.lastShownAppUpdateTag, 'v1.3.2');
    expect(restored.lastShownAndroidAppUpdateTag, 'v1.3.3');
    expect(restored.showInAppUpdateNotifications, isFalse);
    expect(restored.showAndroidUpdateNotifications, isFalse);
    expect(restored.subscriptionDeviceId, 'entropyvpn-test-device');
    expect(restored.sources, hasLength(2));
    expect(restored.sources.first.rawInput, 'vless://demo');
    expect(restored.sources.first.selectedProfile?.server, 'example.com');
    expect(restored.sources.first.selectedProfile?.transport, TransportMode.ws);
    expect(restored.sources.first.selectedProfile?.tlsMode, TlsMode.reality);
    expect(restored.sources[1].displayName, 'Demo Subscription');
    expect(restored.sources[1].normalizedAutoUpdateIntervalMinutes, 120);
    expect(restored.sources[1].trafficUsage?.usedBytes, 5 * 1024 * 1024 * 1024);
    expect(
      restored.sources[1].trafficUsage?.totalBytes,
      10 * 1024 * 1024 * 1024,
    );
    expect(
      restored.sources[1].trafficUsage?.expiresAt,
      DateTime.utc(2026, 5, 15),
    );
  });

  test('PersistedAppState round-trips native sing-box configs', () {
    const profile = ParsedVpnProfile(
      protocol: LinkProtocol.vless,
      server: 'vpn.example.com',
      port: 443,
      transport: TransportMode.raw,
      tlsMode: TlsMode.none,
      remark: 'native',
      singBoxConfigJson: '{"inbounds":[{"type":"tun"}],"outbounds":[]}',
      singBoxConfigDirectory: r'C:\Configs',
    );

    final state = PersistedAppState(
      language: AppLanguage.en,
      trafficMode: TrafficMode.tun,
      tunIpMode: TunIpMode.ipv4,
      selectedSourceId: 'source-1',
      sources: const <ConfigSource>[
        ConfigSource(
          id: 'source-1',
          rawInput: r'C:\Configs\config.json',
          kind: ConfigSourceKind.config,
          profiles: <ParsedVpnProfile>[profile],
        ),
      ],
    );

    final restored = PersistedAppState.fromJson(
      Map<String, dynamic>.from(state.toJson()),
    );

    final restoredProfile = restored.sources.single.selectedProfile!;
    expect(restoredProfile.isSingBoxConfig, isTrue);
    expect(restoredProfile.singBoxConfigJson, profile.singBoxConfigJson);
    expect(restoredProfile.singBoxConfigDirectory, r'C:\Configs');
  });

  test('PersistedAppState round-trips native Xray configs', () {
    const profile = ParsedVpnProfile(
      protocol: LinkProtocol.vless,
      server: 'xray.example.com',
      port: 443,
      transport: TransportMode.ws,
      tlsMode: TlsMode.tls,
      remark: 'native-xray',
      xrayOutboundProtocol: 'vless',
      xrayConfigJson: '{"routing":{},"outbounds":[{"protocol":"vless"}]}',
      xrayConfigDirectory: r'C:\XrayConfigs',
    );

    final state = PersistedAppState(
      language: AppLanguage.en,
      trafficMode: TrafficMode.systemProxy,
      tunIpMode: TunIpMode.ipv4,
      selectedSourceId: 'source-1',
      sources: const <ConfigSource>[
        ConfigSource(
          id: 'source-1',
          rawInput: r'C:\XrayConfigs\config.json',
          kind: ConfigSourceKind.config,
          profiles: <ParsedVpnProfile>[profile],
        ),
      ],
    );

    final restored = PersistedAppState.fromJson(
      Map<String, dynamic>.from(state.toJson()),
    );

    final restoredProfile = restored.sources.single.selectedProfile!;
    expect(restoredProfile.isXrayConfig, isTrue);
    expect(restoredProfile.xrayOutboundProtocol, 'vless');
    expect(restoredProfile.xrayConfigJson, profile.xrayConfigJson);
    expect(restoredProfile.xrayConfigDirectory, r'C:\XrayConfigs');
  });

  test('ConfigSource defaults old subscriptions to one-hour auto-update', () {
    final source = ConfigSource.fromJson(<String, dynamic>{
      'id': 'source-1',
      'rawInput': 'https://subscriptions.example.com/list',
      'kind': 'subscription',
    });

    expect(
      source.normalizedAutoUpdateIntervalMinutes,
      defaultSubscriptionAutoUpdateMinutes,
    );
    expect(source.autoUpdateInterval, const Duration(hours: 1));
  });

  test('AppStateStore recovers from a leftover temp state file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'entropy_app_state_store_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final stateFile = File(p.join(directory.path, 'app_state.json'));
    final tempFile = File('${stateFile.path}.tmp');
    final expectedState = _stateWithSubscription('source-1');
    await tempFile.writeAsString(_encodeState(expectedState), flush: true);

    final store = AppStateStore(stateFile: stateFile);
    final restored = await store.load();

    expect(restored?.sources.single.rawInput, 'https://example.com/sub');
    expect(await stateFile.exists(), isTrue);
    expect(await tempFile.exists(), isFalse);
  });

  test('AppStateStore recovers from backup when primary is corrupt', () async {
    final directory = await Directory.systemTemp.createTemp(
      'entropy_app_state_store_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final stateFile = File(p.join(directory.path, 'app_state.json'));
    final backupFile = File('${stateFile.path}.bak');
    final expectedState = _stateWithSubscription('source-2');
    await stateFile.writeAsString('{', flush: true);
    await backupFile.writeAsString(_encodeState(expectedState), flush: true);

    final store = AppStateStore(stateFile: stateFile);
    final restored = await store.load();

    expect(restored?.selectedSourceId, 'source-2');
    expect(restored?.sources.single.kind, ConfigSourceKind.subscription);
    expect(
      PersistedAppState.fromJson(
        jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>,
      ).selectedSourceId,
      'source-2',
    );
  });
}

PersistedAppState _stateWithSubscription(String sourceId) {
  return PersistedAppState(
    language: AppLanguage.en,
    trafficMode: TrafficMode.tun,
    tunIpMode: TunIpMode.dualStack,
    selectedSourceId: sourceId,
    sources: <ConfigSource>[
      ConfigSource(
        id: sourceId,
        rawInput: 'https://example.com/sub',
        kind: ConfigSourceKind.subscription,
        profiles: const <ParsedVpnProfile>[
          ParsedVpnProfile(
            protocol: LinkProtocol.vless,
            server: 'vpn.example.com',
            port: 443,
            transport: TransportMode.ws,
            tlsMode: TlsMode.tls,
            userId: '11111111-1111-1111-1111-111111111111',
          ),
        ],
      ),
    ],
  );
}

String _encodeState(PersistedAppState state) {
  return const JsonEncoder.withIndent('  ').convert(state.toJson());
}
