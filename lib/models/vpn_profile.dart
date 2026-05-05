import 'package:flutter/widgets.dart';

enum AppLanguage { ru, en }

enum CoreFlavor { xray, singBox }

enum TrafficMode { systemProxy, tun }

enum TunIpMode { ipv4, dualStack, ipv6 }

enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

enum LinkProtocol { vless, vmess, trojan, shadowsocks, hysteria, hysteria2 }

enum TransportMode { raw, ws, grpc, http, httpUpgrade, quic, xhttp }

enum TlsMode { none, tls, reality }

extension AppLanguageExtension on AppLanguage {
  Locale get locale => switch (this) {
    AppLanguage.ru => const Locale('ru'),
    AppLanguage.en => const Locale('en'),
  };
}

AppLanguage detectAppLanguage(String localeName) {
  return localeName.toLowerCase().startsWith('ru')
      ? AppLanguage.ru
      : AppLanguage.en;
}

class ParsedVpnProfile {
  const ParsedVpnProfile({
    required this.protocol,
    required this.server,
    required this.port,
    required this.transport,
    required this.tlsMode,
    this.remark,
    this.userId,
    this.password,
    this.method,
    this.security,
    this.alterId = 0,
    this.flow,
    this.sni,
    this.alpn = const <String>[],
    this.host,
    this.path,
    this.serviceName,
    this.authority,
    this.fingerprint,
    this.publicKey,
    this.shortId,
    this.spiderX,
    this.allowInsecure = false,
    this.plugin,
    this.pluginOpts,
    this.serverPorts = const <String>[],
    this.uploadMbps,
    this.downloadMbps,
    this.hysteriaNetwork,
    this.obfs,
    this.obfsPassword,
    this.singBoxOutboundType,
    this.singBoxConfigJson,
    this.singBoxConfigDirectory,
    this.xrayOutboundProtocol,
    this.xrayConfigJson,
    this.xrayConfigDirectory,
  });

  factory ParsedVpnProfile.singBoxConfig({
    required String configJson,
    String? remark,
    String? server,
    int port = 0,
    LinkProtocol protocol = LinkProtocol.vless,
    TransportMode transport = TransportMode.raw,
    TlsMode tlsMode = TlsMode.none,
    String? userId,
    String? password,
    String? method,
    String? security,
    String? flow,
    String? sni,
    List<String> alpn = const <String>[],
    String? host,
    String? path,
    String? serviceName,
    String? authority,
    String? fingerprint,
    String? publicKey,
    String? shortId,
    bool allowInsecure = false,
    String? singBoxOutboundType,
    String? configDirectory,
    List<String> serverPorts = const <String>[],
    int? uploadMbps,
    int? downloadMbps,
    String? hysteriaNetwork,
    String? obfs,
    String? obfsPassword,
  }) {
    return ParsedVpnProfile(
      protocol: protocol,
      server: server ?? '',
      port: port,
      transport: transport,
      tlsMode: tlsMode,
      remark: remark ?? 'Sing-box config',
      userId: userId,
      password: password,
      method: method,
      security: security,
      flow: flow,
      sni: sni,
      alpn: alpn,
      host: host,
      path: path,
      serviceName: serviceName,
      authority: authority,
      fingerprint: fingerprint,
      publicKey: publicKey,
      shortId: shortId,
      allowInsecure: allowInsecure,
      serverPorts: serverPorts,
      uploadMbps: uploadMbps,
      downloadMbps: downloadMbps,
      hysteriaNetwork: hysteriaNetwork,
      obfs: obfs,
      obfsPassword: obfsPassword,
      singBoxOutboundType: singBoxOutboundType,
      singBoxConfigJson: configJson,
      singBoxConfigDirectory: configDirectory,
    );
  }

  factory ParsedVpnProfile.xrayConfig({
    required String configJson,
    String? remark,
    String? server,
    int port = 0,
    LinkProtocol protocol = LinkProtocol.vless,
    TransportMode transport = TransportMode.raw,
    TlsMode tlsMode = TlsMode.none,
    String? userId,
    String? password,
    String? method,
    String? security,
    int alterId = 0,
    String? flow,
    String? sni,
    List<String> alpn = const <String>[],
    String? host,
    String? path,
    String? serviceName,
    String? authority,
    String? fingerprint,
    String? publicKey,
    String? shortId,
    String? spiderX,
    bool allowInsecure = false,
    String? xrayOutboundProtocol,
    String? configDirectory,
  }) {
    return ParsedVpnProfile(
      protocol: protocol,
      server: server ?? '',
      port: port,
      transport: transport,
      tlsMode: tlsMode,
      remark: remark ?? 'Xray config',
      userId: userId,
      password: password,
      method: method,
      security: security,
      alterId: alterId,
      flow: flow,
      sni: sni,
      alpn: alpn,
      host: host,
      path: path,
      serviceName: serviceName,
      authority: authority,
      fingerprint: fingerprint,
      publicKey: publicKey,
      shortId: shortId,
      spiderX: spiderX,
      allowInsecure: allowInsecure,
      xrayOutboundProtocol: xrayOutboundProtocol,
      xrayConfigJson: configJson,
      xrayConfigDirectory: configDirectory,
    );
  }

  final LinkProtocol protocol;
  final String server;
  final int port;
  final TransportMode transport;
  final TlsMode tlsMode;
  final String? remark;
  final String? userId;
  final String? password;
  final String? method;
  final String? security;
  final int alterId;
  final String? flow;
  final String? sni;
  final List<String> alpn;
  final String? host;
  final String? path;
  final String? serviceName;
  final String? authority;
  final String? fingerprint;
  final String? publicKey;
  final String? shortId;
  final String? spiderX;
  final bool allowInsecure;
  final String? plugin;
  final String? pluginOpts;
  final List<String> serverPorts;
  final int? uploadMbps;
  final int? downloadMbps;
  final String? hysteriaNetwork;
  final String? obfs;
  final String? obfsPassword;
  final String? singBoxOutboundType;
  final String? singBoxConfigJson;
  final String? singBoxConfigDirectory;
  final String? xrayOutboundProtocol;
  final String? xrayConfigJson;
  final String? xrayConfigDirectory;

  bool get isSingBoxConfig =>
      singBoxConfigJson != null && singBoxConfigJson!.trim().isNotEmpty;

  bool get isXrayConfig =>
      xrayConfigJson != null && xrayConfigJson!.trim().isNotEmpty;

  bool get isNativeConfig => isSingBoxConfig || isXrayConfig;

  CoreFlavor? get nativeConfigCore {
    if (isSingBoxConfig) {
      return CoreFlavor.singBox;
    }
    if (isXrayConfig) {
      return CoreFlavor.xray;
    }
    return null;
  }

  String get endpointLabel {
    final normalizedServer = server.trim();
    if (normalizedServer.isEmpty) {
      return remark?.trim().isNotEmpty == true
          ? remark!.trim()
          : isXrayConfig
          ? 'Xray config'
          : 'Sing-box config';
    }
    if (port <= 0) {
      return normalizedServer;
    }
    return '$normalizedServer:$port';
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'protocol': protocol.name,
      'server': server,
      'port': port,
      'transport': transport.name,
      'tlsMode': tlsMode.name,
      'remark': remark,
      'userId': userId,
      'password': password,
      'method': method,
      'security': security,
      'alterId': alterId,
      'flow': flow,
      'sni': sni,
      'alpn': alpn,
      'host': host,
      'path': path,
      'serviceName': serviceName,
      'authority': authority,
      'fingerprint': fingerprint,
      'publicKey': publicKey,
      'shortId': shortId,
      'spiderX': spiderX,
      'allowInsecure': allowInsecure,
      'plugin': plugin,
      'pluginOpts': pluginOpts,
      'serverPorts': serverPorts,
      'uploadMbps': uploadMbps,
      'downloadMbps': downloadMbps,
      'hysteriaNetwork': hysteriaNetwork,
      'obfs': obfs,
      'obfsPassword': obfsPassword,
      'singBoxOutboundType': singBoxOutboundType,
      'singBoxConfigJson': singBoxConfigJson,
      'singBoxConfigDirectory': singBoxConfigDirectory,
      'xrayOutboundProtocol': xrayOutboundProtocol,
      'xrayConfigJson': xrayConfigJson,
      'xrayConfigDirectory': xrayConfigDirectory,
    };
  }

  factory ParsedVpnProfile.fromJson(Map<String, dynamic> json) {
    return ParsedVpnProfile(
      protocol: _enumByName(
        LinkProtocol.values,
        json['protocol'] as String?,
        LinkProtocol.vless,
      ),
      server: (json['server'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      transport: _enumByName(
        TransportMode.values,
        json['transport'] as String?,
        TransportMode.raw,
      ),
      tlsMode: _enumByName(
        TlsMode.values,
        json['tlsMode'] as String?,
        TlsMode.none,
      ),
      remark: json['remark'] as String?,
      userId: json['userId'] as String?,
      password: json['password'] as String?,
      method: json['method'] as String?,
      security: json['security'] as String?,
      alterId: (json['alterId'] as num?)?.toInt() ?? 0,
      flow: json['flow'] as String?,
      sni: json['sni'] as String?,
      alpn: ((json['alpn'] as List<dynamic>?) ?? const <dynamic>[])
          .whereType<String>()
          .toList(growable: false),
      host: json['host'] as String?,
      path: json['path'] as String?,
      serviceName: json['serviceName'] as String?,
      authority: json['authority'] as String?,
      fingerprint: json['fingerprint'] as String?,
      publicKey: json['publicKey'] as String?,
      shortId: json['shortId'] as String?,
      spiderX: json['spiderX'] as String?,
      allowInsecure: json['allowInsecure'] == true,
      plugin: json['plugin'] as String?,
      pluginOpts: json['pluginOpts'] as String?,
      serverPorts:
          ((json['serverPorts'] as List<dynamic>?) ?? const <dynamic>[])
              .map((item) => item?.toString().trim() ?? '')
              .where((item) => item.isNotEmpty)
              .toList(growable: false),
      uploadMbps: (json['uploadMbps'] as num?)?.toInt(),
      downloadMbps: (json['downloadMbps'] as num?)?.toInt(),
      hysteriaNetwork: json['hysteriaNetwork'] as String?,
      obfs: json['obfs'] as String?,
      obfsPassword: json['obfsPassword'] as String?,
      singBoxOutboundType: json['singBoxOutboundType'] as String?,
      singBoxConfigJson: json['singBoxConfigJson'] as String?,
      singBoxConfigDirectory: json['singBoxConfigDirectory'] as String?,
      xrayOutboundProtocol: json['xrayOutboundProtocol'] as String?,
      xrayConfigJson: json['xrayConfigJson'] as String?,
      xrayConfigDirectory: json['xrayConfigDirectory'] as String?,
    );
  }
}

T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
  if (name == null || name.isEmpty) {
    return fallback;
  }

  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }

  return fallback;
}
