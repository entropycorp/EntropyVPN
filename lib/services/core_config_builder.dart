import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../models/dns_settings.dart';
import '../models/split_tunnel.dart';
import '../models/vpn_profile.dart';

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
    DnsSettings dnsSettings = const DnsSettings(),
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
    String? xrayServerAddressOverride,
    String? socksUsername,
    String? socksPassword,
  }) {
    final decoded = jsonDecode(
      buildJsonFor(
        core,
        profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        dnsSettings: dnsSettings,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
        tunInterfaceName: tunInterfaceName,
        outboundBindInterface: outboundBindInterface,
        routeDefaultInterface: routeDefaultInterface,
        xrayServerAddressOverride: xrayServerAddressOverride,
        socksUsername: socksUsername,
        socksPassword: socksPassword,
      ),
    );
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Native config builder returned invalid JSON.',
      );
    }
    return decoded;
  }

  String buildJsonFor(
    CoreFlavor core,
    ParsedVpnProfile profile, {
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    DnsSettings dnsSettings = const DnsSettings(),
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
    String? xrayServerAddressOverride,
    String? socksUsername,
    String? socksPassword,
  }) {
    return _NativeCoreConfigBuilder.instance.buildJson(
      core: core,
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface: outboundBindInterface,
      routeDefaultInterface: routeDefaultInterface,
      serverAddressOverride: xrayServerAddressOverride,
      socksUsername: socksUsername,
      socksPassword: socksPassword,
    );
  }

  Map<String, dynamic> buildSingBox(
    ParsedVpnProfile profile, {
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    DnsSettings dnsSettings = const DnsSettings(),
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
  }) {
    return _NativeCoreConfigBuilder.instance.build(
      core: CoreFlavor.singBox,
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
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
    DnsSettings dnsSettings = const DnsSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? serverAddressOverride,
  }) {
    return _NativeCoreConfigBuilder.instance.build(
      core: CoreFlavor.xray,
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      dnsSettings: dnsSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface: outboundBindInterface,
      serverAddressOverride: serverAddressOverride,
    );
  }

}

typedef _NativeBuildCoreConfig =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> profileJson,
      ffi.Pointer<Utf8> optionsJson,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeBuildCoreConfigDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> profileJson,
      ffi.Pointer<Utf8> optionsJson,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeFreeString = ffi.Void Function(ffi.Pointer<Utf8> value);
typedef _NativeFreeStringDart = void Function(ffi.Pointer<Utf8> value);

class _NativeCoreConfigBuilder {
  _NativeCoreConfigBuilder._(this._buildCoreConfig, this._freeString);

  static final _NativeCoreConfigBuilder instance = _NativeCoreConfigBuilder._(
    _openLibrary()
        .lookupFunction<_NativeBuildCoreConfig, _NativeBuildCoreConfigDart>(
          'entropy_build_core_config',
        ),
    _openLibrary().lookupFunction<_NativeFreeString, _NativeFreeStringDart>(
      'entropy_free_string',
    ),
  );

  final _NativeBuildCoreConfigDart _buildCoreConfig;
  final _NativeFreeStringDart _freeString;

  static ffi.DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('libentropy_vpn_native.so');
    }
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('entropy_vpn_native.dll');
    }
    if (Platform.isLinux) {
      return ffi.DynamicLibrary.open('libentropy_vpn_native.so');
    }
    if (Platform.isMacOS) {
      return ffi.DynamicLibrary.open('libentropy_vpn_native.dylib');
    }
    throw UnsupportedError('Native core config builder is unavailable.');
  }

  Map<String, dynamic> build(
    ParsedVpnProfile profile, {
    required CoreFlavor core,
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    DnsSettings dnsSettings = const DnsSettings(),
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
    String? serverAddressOverride,
    String? socksUsername,
    String? socksPassword,
  }) {
    final decoded = jsonDecode(
      buildJson(
        profile,
        core: core,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        dnsSettings: dnsSettings,
        splitTunnelSettings: splitTunnelSettings,
        domainSplitTunnelSettings: domainSplitTunnelSettings,
        tunInterfaceName: tunInterfaceName,
        outboundBindInterface: outboundBindInterface,
        routeDefaultInterface: routeDefaultInterface,
        serverAddressOverride: serverAddressOverride,
        socksUsername: socksUsername,
        socksPassword: socksPassword,
      ),
    );
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Native config builder returned invalid JSON.',
      );
    }
    return decoded;
  }

  String buildJson(
    ParsedVpnProfile profile, {
    required CoreFlavor core,
    TrafficMode trafficMode = TrafficMode.systemProxy,
    TunIpMode tunIpMode = TunIpMode.ipv4,
    DnsSettings dnsSettings = const DnsSettings(),
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    DomainSplitTunnelSettings domainSplitTunnelSettings =
        const DomainSplitTunnelSettings(),
    String? tunInterfaceName,
    String? outboundBindInterface,
    String? routeDefaultInterface,
    String? serverAddressOverride,
    String? socksUsername,
    String? socksPassword,
  }) {
    final splitTunnel = splitTunnelSettings.normalized;
    final domainSplitTunnel = domainSplitTunnelSettings.normalized;
    final normalizedDns = dnsSettings.normalized;
    final profileJson = jsonEncode(profile.toJson()).toNativeUtf8();
    final optionsJson = jsonEncode(<String, Object?>{
      'core': core.name,
      'trafficMode': trafficMode.name,
      'tunIpMode': tunIpMode.name,
      'isAndroid': Platform.isAndroid,
      'isWindows': Platform.isWindows,
      'dnsMode': normalizedDns.mode.name,
      'dnsServers': normalizedDns.serversFor(tunIpMode),
      'splitTunnelMode': splitTunnel.mode.name,
      'splitTunnelAppNames': splitTunnel.apps
          .map((app) => app.name)
          .toList(growable: false),
      'splitTunnelAppPaths': splitTunnel.apps
          .map((app) => app.path)
          .toList(growable: false),
      'domainSplitTunnelMode': domainSplitTunnel.mode.name,
      'domainSplitTunnelDomains': domainSplitTunnel.domains
          .map((domain) => domain.matchSuffix)
          .toList(growable: false),
      'tunInterfaceName': tunInterfaceName,
      'outboundBindInterface': outboundBindInterface,
      'routeDefaultInterface': routeDefaultInterface,
      'xrayServerAddressOverride': serverAddressOverride,
      'socksUsername': socksUsername,
      'socksPassword': socksPassword,
    }).toNativeUtf8();
    final errorPointer = calloc<ffi.Pointer<Utf8>>();
    ffi.Pointer<Utf8> resultPointer = ffi.nullptr;
    try {
      resultPointer = _buildCoreConfig(profileJson, optionsJson, errorPointer);
      if (resultPointer == ffi.nullptr) {
        final messagePointer = errorPointer.value;
        final message = messagePointer == ffi.nullptr
            ? 'Failed to build core config.'
            : messagePointer.toDartString();
        if (messagePointer != ffi.nullptr) {
          _freeString(messagePointer);
        }
        throw StateError(message);
      }

      return resultPointer.toDartString();
    } finally {
      calloc.free(profileJson);
      calloc.free(optionsJson);
      calloc.free(errorPointer);
      if (resultPointer != ffi.nullptr) {
        _freeString(resultPointer);
      }
    }
  }
}
