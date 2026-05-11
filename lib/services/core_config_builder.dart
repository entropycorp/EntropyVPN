import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/split_tunnel.dart';
import '../models/vpn_profile.dart';
import 'core_config_native_tun.dart';

part 'sing_box_config_builder.dart';
part 'xray_config_builder.dart';
part 'core_config_tun_routing.dart';

class CoreConfigBuilder {
  static const int singBoxMixedPort = 2080;
  static const int xraySocksPort = 2080;
  static const int xrayHttpPort = 2081;
  static const int tunMtu = 1400;
  static const String androidTunStack = 'gvisor';
  static const String desktopTunStack = 'mixed';

  Map<String, dynamic> buildFor(
    CoreFlavor core,
    ParsedVpnProfile profile, {
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
    String? xrayServerAddressOverride,
  }) {
    return switch (core) {
      CoreFlavor.xray => buildXray(
        profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
        tunInterfaceName: tunInterfaceName,
        outboundBindInterface: outboundBindInterface,
        serverAddressOverride: xrayServerAddressOverride,
      ),
      CoreFlavor.singBox => buildSingBox(
        profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
        tunInterfaceName: tunInterfaceName,
        outboundBindInterface: outboundBindInterface,
        routeDefaultInterface: routeDefaultInterface,
      ),
    };
  }

  Map<String, dynamic> buildSingBox(
    ParsedVpnProfile profile, {
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
  }) {
    return _buildSingBoxConfig(
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface: outboundBindInterface,
      routeDefaultInterface: routeDefaultInterface,
    );
  }

  Map<String, dynamic> buildXray(
    ParsedVpnProfile profile, {
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? serverAddressOverride,
  }) {
    return _buildXrayConfig(
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface: outboundBindInterface,
      serverAddressOverride: serverAddressOverride,
    );
  }

  bool applyNativeSingBoxTunSettings(
    Map<String, dynamic> config, {
    required TunIpMode tunIpMode,
    String? tunInterfaceName,
    int? mtu,
    bool androidCompatibility = false,
  }) {
    return _applyNativeSingBoxTunSettings(
      config,
      tunIpMode: tunIpMode,
      tunInterfaceName: tunInterfaceName,
      mtu: mtu,
      androidCompatibility: androidCompatibility,
    );
  }
}

String _require(String? value, String name) {
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is missing in the provided link.');
  }
  return value;
}
