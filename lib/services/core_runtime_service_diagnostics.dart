part of 'core_runtime_service.dart';

extension CoreRuntimeServiceDiagnostics on CoreRuntimeService {
  void _rememberLog(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    _recentLogs.add(line.trim());
    while (_recentLogs.length > CoreRuntimeService._maxRecentLogs) {
      _recentLogs.removeFirst();
    }
    onLogUpdated?.call();
  }

  void _rememberAppLog(String line) {
    _rememberLog('[app] $line');
  }


  String _describeProfile(ParsedVpnProfile profile) {
    if (profile.isSingBoxConfig) {
      return <String>[
        'kind=sing-box-config',
        'name=${_orDash(profile.remark)}',
        'endpoint=${profile.endpointLabel}',
        'config_dir=${_orDash(profile.singBoxConfigDirectory)}',
      ].join(', ');
    }
    if (profile.isXrayConfig) {
      return <String>[
        'kind=xray-config',
        'name=${_orDash(profile.remark)}',
        'endpoint=${profile.endpointLabel}',
        'config_dir=${_orDash(profile.xrayConfigDirectory)}',
      ].join(', ');
    }

    final fields = <String>[
      'protocol=${profile.protocol.name}',
      'endpoint=${profile.server}:${profile.port}',
      'transport=${profile.transport.name}',
      'tls=${profile.tlsMode.name}',
      'remark=${_orDash(profile.remark)}',
      'plugin=${_orDash(profile.plugin)}',
    ];

    if (profile.host?.trim().isNotEmpty == true) {
      fields.add('host=${profile.host!.trim()}');
    }
    if (profile.path?.trim().isNotEmpty == true) {
      fields.add('path=${profile.path!.trim()}');
    }
    if (profile.serviceName?.trim().isNotEmpty == true) {
      fields.add('service=${profile.serviceName!.trim()}');
    }
    if (profile.sni?.trim().isNotEmpty == true) {
      fields.add('sni=${profile.sni!.trim()}');
    }

    return fields.join(', ');
  }

  String _describeConfig(Map<String, dynamic> config) {
    final inbounds = config['inbounds'] as List<dynamic>? ?? const <dynamic>[];
    final outboundList =
        config['outbounds'] as List<dynamic>? ?? const <dynamic>[];
    final inbound = inbounds.isEmpty
        ? const <String, dynamic>{}
        : (inbounds.first as Map).cast<String, dynamic>();
    final outbound = outboundList.isEmpty
        ? const <String, dynamic>{}
        : (outboundList.first as Map).cast<String, dynamic>();
    final route = (config['route'] as Map?)?.cast<String, dynamic>();
    final dns = (config['dns'] as Map?)?.cast<String, dynamic>();
    final inboundKind =
        inbound['type']?.toString() ?? inbound['protocol']?.toString();
    final outboundServer = _describeConfigOutboundServer(outbound);

    final fields = <String>[
      'inbound=${_orDash(inboundKind)}',
      'outbound=${_orDash(outbound['type']?.toString() ?? outbound['protocol']?.toString())}',
      'server=$outboundServer',
      'route.final=${_orDash(route?['final']?.toString())}',
    ];

    if (inboundKind == 'tun') {
      final xraySettings = (inbound['settings'] as Map?)
          ?.cast<String, dynamic>();
      fields.add(
        'interface=${_orDash(inbound['interface_name']?.toString() ?? xraySettings?['name']?.toString())}',
      );
      fields.add(
        'mtu=${_orDash(inbound['mtu']?.toString() ?? xraySettings?['MTU']?.toString() ?? xraySettings?['mtu']?.toString())}',
      );
      fields.add(
        'address=${_orDash((inbound['address'] as List?)?.join('|') ?? (xraySettings?['gateway'] as List?)?.join('|'))}',
      );
      fields.add('auto_route=${_orDash(inbound['auto_route']?.toString())}');
      fields.add('stack=${_orDash(inbound['stack']?.toString())}');
      fields.add(
        'strict_route=${_orDash(inbound['strict_route']?.toString())}',
      );
      fields.add(
        'dns.final=${_orDash(dns?['final']?.toString() ?? (xraySettings?['dns'] as List?)?.join('|'))}',
      );
    } else {
      fields.add('listen=${_orDash(inbound['listen']?.toString())}');
      fields.add('listen_port=${_orDash(inbound['listen_port']?.toString())}');
      fields.add(
        'set_system_proxy=${_orDash(inbound['set_system_proxy']?.toString())}',
      );
    }

    if (outbound['transport'] is Map<String, dynamic>) {
      final transport = outbound['transport'] as Map<String, dynamic>;
      fields.add('transport=${_orDash(transport['type']?.toString())}');
    }
    if (outbound['streamSettings'] is Map<String, dynamic>) {
      final streamSettings = outbound['streamSettings'] as Map<String, dynamic>;
      fields.add('network=${_orDash(streamSettings['network']?.toString())}');
      final sockopt = (streamSettings['sockopt'] as Map?)
          ?.cast<String, dynamic>();
      if (sockopt?['interface'] != null) {
        fields.add(
          'bind_interface=${_orDash(sockopt?['interface']?.toString())}',
        );
      }
    }
    if (outbound['bind_interface'] != null) {
      fields.add(
        'bind_interface=${_orDash(outbound['bind_interface']?.toString())}',
      );
    }
    if (outbound['tls'] is Map<String, dynamic>) {
      final tls = outbound['tls'] as Map<String, dynamic>;
      final tlsMode = tls['reality'] is Map<String, dynamic>
          ? 'reality'
          : 'tls';
      fields.add('tls_mode=$tlsMode');
    }

    return fields.join(', ');
  }

  String _describeConfigOutboundServer(Map<String, dynamic> outbound) {
    final directServer = outbound['server']?.toString();
    final directPort = outbound['server_port']?.toString();
    if (directServer != null || directPort != null) {
      return '${_orDash(directServer)}:${_orDash(directPort)}';
    }

    final settings = (outbound['settings'] as Map?)?.cast<String, dynamic>();
    final vnext = settings?['vnext'];
    if (vnext is List && vnext.isNotEmpty && vnext.first is Map) {
      final server = (vnext.first as Map)['address']?.toString();
      final port = (vnext.first as Map)['port']?.toString();
      return '${_orDash(server)}:${_orDash(port)}';
    }

    final servers = settings?['servers'];
    if (servers is List && servers.isNotEmpty && servers.first is Map) {
      final server = (servers.first as Map)['address']?.toString();
      final port = (servers.first as Map)['port']?.toString();
      return '${_orDash(server)}:${_orDash(port)}';
    }

    return '-:-';
  }


  String _orDash(String? value) {
    if (value == null) {
      return '-';
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? '-' : trimmed;
  }

  String _describeError(Object error) {
    final text = error.toString().trim();
    return text.isEmpty ? error.runtimeType.toString() : text;
  }
}

class _StartupTiming {
  final Stopwatch _total = Stopwatch();
  final List<_StartupTimingEntry> _entries = <_StartupTimingEntry>[];

  void start() {
    _total.start();
  }

  void stop() {
    _total.stop();
  }

  Future<T> time<T>(String label, FutureOr<T> Function() action) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      stopwatch.stop();
      _entries.add(_StartupTimingEntry(label, stopwatch.elapsed));
    }
  }

  String summary() {
    final fields = <String>['total=${_format(_total.elapsed)}'];
    for (final entry in _entries) {
      fields.add('${entry.label}=${_format(entry.elapsed)}');
    }
    return fields.join(', ');
  }

  String _format(Duration duration) {
    return '${duration.inMilliseconds}ms';
  }
}

class _StartupTimingEntry {
  const _StartupTimingEntry(this.label, this.elapsed);

  final String label;
  final Duration elapsed;
}

class _SplitTunnelExpansionCacheEntry {
  const _SplitTunnelExpansionCacheEntry({
    required this.key,
    required this.settings,
    required this.createdAt,
    required this.addedAppCount,
  });

  final String key;
  final SplitTunnelSettings settings;
  final DateTime createdAt;
  final int addedAppCount;
}
