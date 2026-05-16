part of 'core_runtime_service.dart';

extension CoreRuntimeServiceConfigIo on CoreRuntimeService {
  _RuntimeConfigPayload _buildRuntimeConfigPayload({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? xrayServerAddressOverride,
  }) {
    if (profile.isSingBoxConfig) {
      if (core != CoreFlavor.singBox) {
        throw StateError('Native sing-box configs must be run with sing-box.');
      }
      final decoded = _buildNativeSingBoxRuntimeConfig(
        profile: profile,
        tunIpMode: tunIpMode,
        tunInterfaceName: tunInterfaceName,
      );
      if (splitTunnelSettings.isEnabled ||
          domainSplitTunnelSettings.isEnabled) {
        _rememberAppLog(
          'Native sing-box JSON profile is used as-is; split tunneling is only injected into generated TUN configs.',
        );
      }
      return _RuntimeConfigPayload(
        json: const JsonEncoder.withIndent('  ').convert(decoded),
        summary: _describeConfig(decoded),
        skipValidation: _shouldSkipRuntimeValidation(core, decoded),
      );
    }
    if (profile.isXrayConfig) {
      if (core != CoreFlavor.xray) {
        throw StateError('Native Xray configs must be run with Xray.');
      }
      final decoded = _buildNativeXrayRuntimeConfig(profile: profile);
      if (splitTunnelSettings.isEnabled ||
          domainSplitTunnelSettings.isEnabled) {
        _rememberAppLog(
          'Native Xray JSON profile is used as-is; split tunneling is only injected into generated TUN configs.',
        );
      }
      return _RuntimeConfigPayload(
        json: profile.xrayConfigJson!,
        summary: _describeConfig(decoded),
        skipValidation: _shouldSkipRuntimeValidation(core, decoded),
      );
    }

    final configJson = _configBuilder.buildJsonFor(
      core,
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface:
          core == CoreFlavor.xray || trafficMode != TrafficMode.tun
          ? outboundBindInterface
          : null,
      routeDefaultInterface:
          core == CoreFlavor.singBox && trafficMode == TrafficMode.tun
          ? outboundBindInterface
          : null,
      xrayServerAddressOverride: xrayServerAddressOverride,
    );
    return _RuntimeConfigPayload(
      json: configJson,
      summary: _describeGeneratedRuntimeConfig(
        core: core,
        profile: profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        dnsSettings: dnsSettings,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
        tunInterfaceName: tunInterfaceName,
        outboundBindInterface: outboundBindInterface,
        routeDefaultInterface:
            core == CoreFlavor.singBox && trafficMode == TrafficMode.tun
            ? outboundBindInterface
            : null,
        xrayServerAddressOverride: xrayServerAddressOverride,
      ),
      skipValidation:
          Platform.isWindows &&
          core == CoreFlavor.xray &&
          trafficMode == TrafficMode.tun,
    );
  }

  String _describeGeneratedRuntimeConfig({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
    String? xrayServerAddressOverride,
  }) {
    final splitTunnel = splitTunnelSettings.normalized;
    final domainSplitTunnel = domainSplitTunnelSettings.normalized;
    final fields = <String>[
      'source=generated-native-json',
      'core=${core.name}',
      'traffic=${trafficMode.name}',
      'tun_ip=${tunIpMode.name}',
      'profile=${_describeProfile(profile)}',
      'dns=${dnsSettings.normalized.serversFor(tunIpMode).join('|')}',
    ];
    if (tunInterfaceName?.trim().isNotEmpty == true) {
      fields.add('interface=${tunInterfaceName!.trim()}');
    }
    if (outboundBindInterface?.trim().isNotEmpty == true) {
      fields.add('bind_interface=${outboundBindInterface!.trim()}');
    }
    if (routeDefaultInterface?.trim().isNotEmpty == true) {
      fields.add('route_default_interface=${routeDefaultInterface!.trim()}');
    }
    if (xrayServerAddressOverride?.trim().isNotEmpty == true) {
      fields.add('xray_server_override=${xrayServerAddressOverride!.trim()}');
    }
    if (splitTunnel.isEnabled) {
      fields.add('split=${splitTunnel.mode.name}:${splitTunnel.apps.length}');
    }
    if (domainSplitTunnel.isEnabled) {
      fields.add(
        'domain_split=${domainSplitTunnel.mode.name}:${domainSplitTunnel.domains.length}',
      );
    }
    return fields.join(', ');
  }

  Map<String, dynamic> _buildNativeSingBoxRuntimeConfig({
    required ParsedVpnProfile profile,
    required TunIpMode tunIpMode,
    String? tunInterfaceName,
  }) {
    return _configBuilder.buildSingBox(
      profile,
      tunIpMode: tunIpMode,
      tunInterfaceName: tunInterfaceName,
    );
  }

  Map<String, dynamic> _buildNativeXrayRuntimeConfig({
    required ParsedVpnProfile profile,
  }) {
    final decoded = jsonDecode(profile.xrayConfigJson!);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Native Xray config must be a JSON object.');
    }
    return decoded;
  }

  String? _resolveConfigWorkingDirectory(ParsedVpnProfile profile) {
    final configDirectory =
        profile.singBoxConfigDirectory?.trim() ??
        profile.xrayConfigDirectory?.trim();
    if (configDirectory == null || configDirectory.isEmpty) {
      return null;
    }
    if (!Directory(configDirectory).existsSync()) {
      _rememberAppLog(
        'Configured core working directory does not exist: $configDirectory',
      );
      return null;
    }
    return configDirectory;
  }

  bool _profileConfigHasTunInbound(ParsedVpnProfile profile) {
    if (!profile.isNativeConfig) {
      return false;
    }

    try {
      final decoded = jsonDecode(
        profile.singBoxConfigJson ?? profile.xrayConfigJson!,
      );
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      final inbounds = decoded['inbounds'];
      if (inbounds is! List) {
        return false;
      }
      return inbounds.any((item) {
        if (item is! Map) {
          return false;
        }
        final field = profile.isSingBoxConfig ? 'type' : 'protocol';
        return item[field]?.toString().trim().toLowerCase() == 'tun';
      });
    } catch (_) {
      return false;
    }
  }

  bool _shouldSkipRuntimeValidation(
    CoreFlavor core,
    Map<String, dynamic> config,
  ) {
    return Platform.isWindows &&
        core == CoreFlavor.xray &&
        _configHasXrayTunInbound(config);
  }

  bool _configHasXrayTunInbound(Map<String, dynamic> config) {
    final inbounds = config['inbounds'];
    if (inbounds is! List) {
      return false;
    }
    return inbounds.any((item) {
      if (item is! Map) {
        return false;
      }
      return item['protocol']?.toString().trim().toLowerCase() == 'tun';
    });
  }

}

class _RuntimeConfigPayload {
  const _RuntimeConfigPayload({
    required this.json,
    required this.summary,
    required this.skipValidation,
  });

  final String json;
  final String summary;
  final bool skipValidation;
}
