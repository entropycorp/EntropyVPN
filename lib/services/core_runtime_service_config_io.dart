part of 'core_runtime_service.dart';

extension CoreRuntimeServiceConfigIo on CoreRuntimeService {
  Future<void> _startSingleCore({
    required CoreFlavor core,
    required String binaryPath,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
    String? tunInterfaceName,
    required Directory runtimeDirectory,
    String? outboundBindInterface,
    String? xrayServerAddressOverride,
  }) async {
    final configFile = File(p.join(runtimeDirectory.path, 'config.json'));
    final config = _buildRuntimeConfig(
      core: core,
      profile: profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
      splitTunnelSettings: splitTunnelSettings,
      domainSplitTunnelSettings: domainSplitTunnelSettings,
      tunInterfaceName: tunInterfaceName,
      outboundBindInterface: outboundBindInterface,
      xrayServerAddressOverride: xrayServerAddressOverride,
    );
    final configJson = const JsonEncoder.withIndent('  ').convert(config);
    final workingDirectory =
        _resolveConfigWorkingDirectory(profile) ?? runtimeDirectory.path;
    _rememberAppLog('Runtime config path: ${configFile.path}');
    _rememberAppLog('Core working directory: $workingDirectory');
    _rememberAppLog('Runtime config summary: ${_describeConfig(config)}');
    _rememberAppLog(
      'Writing runtime config (${utf8.encode(configJson).length} bytes)...',
    );
    await configFile.writeAsString(configJson);
    final shouldSkipValidation = _shouldSkipRuntimeValidation(core, config);
    if (shouldSkipValidation) {
      _rememberAppLog(
        'Skipping runtime config validation because xray run -test initializes the Windows TUN driver.',
      );
    } else {
      _rememberAppLog('Validating runtime config...');
      await _validateConfig(
        core,
        binaryPath,
        configFile.path,
        workingDirectory: workingDirectory,
      );
      _rememberAppLog('Config validation passed.');
    }

    final args = <String>['run', '-c', configFile.path];
    _rememberAppLog(
      'Starting core process: ${_formatCommand(binaryPath, args)}',
    );
    final process = await _startTimedProcess(
      '${core.name}_core_start',
      binaryPath,
      args,
      workingDirectory: workingDirectory,
    );

    _process = process;
    _runtimeDirectory = runtimeDirectory;
    _stdoutSubscription = _listenTo(process.stdout);
    _stderrSubscription = _listenTo(process.stderr, isError: true);
    _rememberAppLog('Core process started with PID ${process.pid}.');
  }

  Map<String, dynamic> _buildRuntimeConfig({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
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
      return decoded;
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
      return decoded;
    }

    return _configBuilder.buildFor(
      core,
      profile,
      trafficMode: trafficMode,
      tunIpMode: tunIpMode,
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
  }

  Map<String, dynamic> _buildNativeSingBoxRuntimeConfig({
    required ParsedVpnProfile profile,
    required TunIpMode tunIpMode,
    String? tunInterfaceName,
  }) {
    final decoded = jsonDecode(profile.singBoxConfigJson!);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Native sing-box config must be a JSON object.');
    }
    final appliedTunSettings = _configBuilder.applyNativeSingBoxTunSettings(
      decoded,
      tunIpMode: tunIpMode,
      tunInterfaceName: Platform.isWindows ? tunInterfaceName : null,
      mtu: Platform.isAndroid ? CoreConfigBuilder.tunMtu : null,
      androidCompatibility: Platform.isAndroid,
    );
    if (appliedTunSettings && !Platform.isAndroid) {
      _rememberAppLog(
        'Applied ${tunIpMode.name} TUN IP mode to native sing-box config.',
      );
    }
    return decoded;
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

  Future<void> _validateConfig(
    CoreFlavor core,
    String binaryPath,
    String configPath, {
    String? workingDirectory,
  }) async {
    final args = switch (core) {
      CoreFlavor.xray => <String>['run', '-test', '-c', configPath],
      CoreFlavor.singBox => <String>['check', '-c', configPath],
    };

    _rememberAppLog('Validation command: ${_formatCommand(binaryPath, args)}');
    final result = await _runTimedProcess(
      '${core.name}_config_validation',
      binaryPath,
      args,
      workingDirectory: workingDirectory,
    );
    _rememberProcessOutput('[check][stdout] ', result.stdout.toString());
    _rememberProcessOutput('[check][stderr] ', result.stderr.toString());
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      final stdout = result.stdout.toString().trim();
      final message = stderr.isNotEmpty ? stderr : stdout;
      _rememberAppLog(
        'Runtime config validation failed with exit code ${result.exitCode}.',
      );
      throw StateError(
        message.isEmpty ? 'Core configuration validation failed.' : message,
      );
    }
  }
}
