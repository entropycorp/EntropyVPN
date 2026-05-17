part of 'core_runtime_service.dart';

extension CoreRuntimeServiceAndroid on CoreRuntimeService {
  Future<void> _synchronizeAndroidState() async {
    if (!Platform.isAndroid) {
      return;
    }
    _androidBridge?.onProcessExit = onProcessExit;
    _androidBridge?.onLogUpdated = onLogUpdated;
    await _androidBridge?.refreshState();
  }

  Future<void> _saveAndroidStartPayload({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TunIpMode tunIpMode,
    DnsSettings dnsSettings = const DnsSettings(),
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    final bridge = _androidBridge;
    if (bridge == null) {
      return;
    }

    final payload = _buildAndroidStartPayload(
      core: core,
      profile: profile,
      language: language,
      serverCountryCode: await _resolveAndroidServerCountryCode(profile),
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
    );
    await bridge.saveStartPayload(
      core: payload.core,
      configJson: payload.configJson,
      profileName: payload.profileName,
      serverAddress: payload.serverAddress,
      serverCountryCode: payload.serverCountryCode,
      language: payload.language,
      tunIpMode: payload.tunIpMode,
      dnsServers: payload.dnsServers,
      splitTunnelSettings: payload.splitTunnelSettings,
      socksUsername: payload.socksUsername,
      socksPassword: payload.socksPassword,
    );
  }

  Future<void> _startOnAndroid({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) async {
    final bridge = _androidBridge;
    if (bridge == null) {
      throw StateError('Android VPN bridge is unavailable.');
    }

    bridge.onProcessExit = onProcessExit;
    bridge.onLogUpdated = onLogUpdated;

    final payload = _buildAndroidStartPayload(
      core: core,
      profile: profile,
      language: language,
      serverCountryCode: await _resolveAndroidServerCountryCode(profile),
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
    );
    await bridge.start(
      core: payload.core,
      configJson: payload.configJson,
      profileName: payload.profileName,
      serverAddress: payload.serverAddress,
      serverCountryCode: payload.serverCountryCode,
      language: payload.language,
      tunIpMode: payload.tunIpMode,
      dnsServers: payload.dnsServers,
      splitTunnelSettings: payload.splitTunnelSettings,
      socksUsername: payload.socksUsername,
      socksPassword: payload.socksPassword,
    );
  }

  _AndroidStartPayload _buildAndroidStartPayload({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required AppLanguage language,
    required String? serverCountryCode,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) {
    final effectiveDnsSettings = dnsSettings.normalized;
    // The Android VpnService.Builder.addDnsServer() API requires numeric IPs.
    // DoH/DoT is applied inside the core's config (sing-box/xray) instead, so
    // the bridge always receives the classic IP list regardless of mode.
    final dnsServers = switch (tunIpMode) {
      TunIpMode.ipv4 => effectiveDnsSettings.ipv4Servers,
      TunIpMode.ipv6 => effectiveDnsSettings.ipv6Servers,
      TunIpMode.dualStack => <String>[
        ...effectiveDnsSettings.ipv4Servers,
        ...effectiveDnsSettings.ipv6Servers,
      ],
    };
    if (profile.isSingBoxConfig) {
      final config = _buildNativeSingBoxRuntimeConfig(
        profile: profile,
        tunIpMode: tunIpMode,
      );
      return _AndroidStartPayload(
        core: CoreFlavor.singBox.name,
        configJson: const JsonEncoder.withIndent('  ').convert(config),
        profileName: profile.remark ?? profile.endpointLabel,
        serverAddress: profile.server,
        serverCountryCode: serverCountryCode,
        language: language,
        tunIpMode: tunIpMode,
        dnsServers: dnsServers,
        splitTunnelSettings: splitTunnelSettings.normalized,
      );
    }
    if (profile.isXrayConfig) {
      final config = _buildNativeXrayRuntimeConfig(profile: profile);
      return _AndroidStartPayload(
        core: CoreFlavor.xray.name,
        configJson: const JsonEncoder.withIndent('  ').convert(config),
        profileName: profile.remark ?? profile.endpointLabel,
        serverAddress: profile.server,
        serverCountryCode: serverCountryCode,
        language: language,
        tunIpMode: tunIpMode,
        dnsServers: dnsServers,
        splitTunnelSettings: splitTunnelSettings.normalized,
      );
    }

    final effectiveTrafficMode = core == CoreFlavor.singBox
        ? TrafficMode.tun
        : TrafficMode.systemProxy;
    // Lock down the loopback SOCKS/HTTP inbound xray exposes on Android so
    // other apps on the device cannot proxy through the VPN. See
    // https://habr.com/ru/articles/1020080/ for the disclosed PoC.
    final needsSocksAuth =
        core == CoreFlavor.xray && effectiveTrafficMode == TrafficMode.systemProxy;
    final socksUsername = needsSocksAuth ? _randomSocksToken() : null;
    final socksPassword = needsSocksAuth ? _randomSocksToken() : null;
    final configJson = _configBuilder.buildJsonFor(
      core,
      profile,
      trafficMode: effectiveTrafficMode,
      tunIpMode: tunIpMode,
      dnsSettings: effectiveDnsSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      socksUsername: socksUsername,
      socksPassword: socksPassword,
    );
    return _AndroidStartPayload(
      core: core.name,
      configJson: configJson,
      profileName: profile.remark ?? profile.endpointLabel,
      serverAddress: profile.server,
      serverCountryCode: serverCountryCode,
      language: language,
      tunIpMode: tunIpMode,
      dnsServers: dnsServers,
      splitTunnelSettings: splitTunnelSettings.normalized,
      socksUsername: socksUsername,
      socksPassword: socksPassword,
    );
  }

  static String _randomSocksToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<String?> _resolveAndroidServerCountryCode(
    ParsedVpnProfile profile,
  ) async {
    final server = profile.server.trim();
    if (server.isEmpty) {
      return null;
    }
    try {
      final info = await _geoIpService.resolveServer(server);
      return _normalizeCountryCode(info?.countryCode);
    } catch (_) {
      return null;
    }
  }

  String? _normalizeCountryCode(String? countryCode) {
    final normalized = countryCode?.trim().toUpperCase();
    if (normalized == null || normalized.length != 2) {
      return null;
    }
    final units = normalized.codeUnits;
    if (units.any((unit) => unit < 65 || unit > 90)) {
      return null;
    }
    return normalized;
  }

  Future<void> _stopOnAndroid() async {
    _androidBridge?.onProcessExit = onProcessExit;
    _androidBridge?.onLogUpdated = onLogUpdated;
    await _androidBridge?.stop();
  }

  Future<void> _setKillswitchPreferenceOnAndroid(bool enabled) async {
    final bridge = _androidBridge;
    if (bridge == null) {
      return;
    }
    try {
      await bridge.setKillswitchPreference(enabled);
    } catch (error) {
      _rememberAppLog(
        'Killswitch preference push failed: ${_describeError(error)}',
      );
    }
  }
}

class _AndroidStartPayload {
  const _AndroidStartPayload({
    required this.core,
    required this.configJson,
    required this.profileName,
    required this.serverAddress,
    required this.serverCountryCode,
    required this.language,
    required this.tunIpMode,
    required this.dnsServers,
    required this.splitTunnelSettings,
    this.socksUsername,
    this.socksPassword,
  });

  final String core;
  final String configJson;
  final String profileName;
  final String serverAddress;
  final String? serverCountryCode;
  final AppLanguage language;
  final TunIpMode tunIpMode;
  final List<String> dnsServers;
  final SplitTunnelSettings splitTunnelSettings;
  final String? socksUsername;
  final String? socksPassword;
}
