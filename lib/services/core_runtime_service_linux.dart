part of 'core_runtime_service.dart';

class LinuxTunHelperUnavailableException implements Exception {
  const LinuxTunHelperUnavailableException(this.message);
  final String message;
  @override
  String toString() => 'Linux TUN helper unavailable: $message';
}

/// Linux runtime support.
///
/// * **system-proxy** mode launches the core directly with the user's own
///   privileges, then points GNOME at the local listener via `gsettings`.
/// * **TUN** mode launches a small shell wrapper via `pkexec` (or directly
///   when the app is already root) so the core gets `CAP_NET_ADMIN` to manage
///   the TUN interface and route table. The wrapper is controlled from the
///   unprivileged app via stdin: writing the line `stop\n` (or closing
///   stdin, which happens when the GUI process exits) triggers a clean
///   shutdown of the core.
extension CoreRuntimeServiceLinux on CoreRuntimeService {
  static const String _linuxRunnerHelperName = 'entropy_vpn_runner.sh';

  Future<void> _startOnLinux({
    required CoreFlavor core,
    required ParsedVpnProfile profile,
    required TrafficMode trafficMode,
    required TunIpMode tunIpMode,
    required DnsSettings dnsSettings,
    required SplitTunnelSettings splitTunnelSettings,
    required DomainSplitTunnelSettings domainSplitTunnelSettings,
  }) async {
    if (!Platform.isLinux) {
      return;
    }

    if (trafficMode != TrafficMode.systemProxy &&
        trafficMode != TrafficMode.tun) {
      throw UnsupportedError(
        'Unknown Linux traffic mode: ${trafficMode.name}.',
      );
    }

    if (splitTunnelSettings.isEnabled || domainSplitTunnelSettings.isEnabled) {
      _rememberAppLog(
        'Split tunneling is not yet implemented on Linux; settings ignored.',
      );
    }

    await _stopOnLinux();
    await _waitForPendingStopCleanup(reason: 'before Linux start');
    _recentLogs.clear();

    final startupTiming = _StartupTiming()..start();
    try {
      _rememberAppLog(
        'Starting Linux runtime: core=${core.name}, traffic=${trafficMode.name}, '
        'endpoint=${profile.server}:${profile.port}.',
      );

      final binaryPath = await startupTiming.time(
        'resolve_binary',
        () => _resolveBinary(core),
      );

      final configPayload = _buildRuntimeConfigPayload(
        core: core,
        profile: profile,
        trafficMode: trafficMode,
        tunIpMode: tunIpMode,
        dnsSettings: dnsSettings,
        splitTunnelSettings: const SplitTunnelSettings(),
        domainSplitTunnelSettings: const DomainSplitTunnelSettings(),
      );
      _rememberAppLog('Linux runtime config: ${configPayload.summary}');

      final runtimeDirectory = await startupTiming.time(
        'prepare_runtime_dir',
        () => _prepareLinuxRuntimeDirectory(),
      );
      final configFile = File(p.join(runtimeDirectory.path, 'config.json'));
      await configFile.writeAsString(configPayload.json, flush: true);

      final workingDirectory =
          _resolveConfigWorkingDirectory(profile) ?? runtimeDirectory.path;

      final Process process;
      if (trafficMode == TrafficMode.tun) {
        process = await startupTiming.time(
          'tun_process_start',
          () => _startLinuxTunProcess(
            coreBinary: binaryPath,
            configPath: configFile.path,
            workingDirectory: workingDirectory,
          ),
        );
      } else {
        process = await startupTiming.time(
          'process_start',
          () => Process.start(
            binaryPath,
            _linuxCoreArguments(core, configFile.path),
            workingDirectory: workingDirectory,
            mode: ProcessStartMode.normal,
          ),
        );
      }
      _process = process;
      _rememberAppLog('Linux runtime PID ${process.pid} ($binaryPath).');

      _attachLinuxProcessStreams(process);
      unawaited(_watchLinuxProcessExit(process));

      if (trafficMode == TrafficMode.systemProxy) {
        final inboundPort = _extractLinuxInboundPort(configPayload.json);
        if (inboundPort != null) {
          await startupTiming.time(
            'apply_system_proxy',
            () => _applyLinuxSystemProxy(inboundPort),
          );
        } else {
          _rememberAppLog(
            'Could not determine local proxy port; system proxy not configured. '
            'Set http_proxy/https_proxy manually if needed.',
          );
        }
      }
    } catch (error) {
      _process = null;
      _rememberAppLog('Linux runtime start failed: ${_describeError(error)}');
      rethrow;
    } finally {
      startupTiming.stop();
      _rememberAppLog(
        'Linux runtime startup timing: ${startupTiming.summary()}.',
      );
    }
  }

  Future<void> _stopOnLinux() async {
    if (!Platform.isLinux) {
      return;
    }
    // Best-effort proxy restore even if the process is gone or kill fails.
    // Safe to call when system proxy was never set — gsettings no-ops.
    await _restoreLinuxSystemProxy();

    final process = _process;
    if (process == null) {
      return;
    }
    _process = null;
    try {
      // For TUN mode the wrapper script reacts to "stop\n" on stdin; for
      // system-proxy mode the core itself owns stdin but is happy to receive
      // SIGTERM as well. Try the polite path first, then fall through.
      try {
        process.stdin.writeln('stop');
        await process.stdin.flush();
      } catch (_) {
        // Ignore: process may not accept stdin (already closed, etc.).
      }
      try {
        await process.stdin.close();
      } catch (_) {}

      process.kill(ProcessSignal.sigterm);
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return process.exitCode;
        },
      );
      _rememberAppLog('Linux runtime stopped (exit=$exitCode).');
    } catch (error) {
      _rememberAppLog('Linux runtime stop failed: ${_describeError(error)}');
    }
  }

  /// Launches the privileged TUN wrapper. Picks the most direct path
  /// available: if the app is already root, run the helper directly;
  /// otherwise hand it to `pkexec`, which spawns a polkit auth prompt for
  /// the user. The wrapper inherits stdin so the unprivileged parent can
  /// drive shutdown.
  Future<Process> _startLinuxTunProcess({
    required String coreBinary,
    required String configPath,
    required String workingDirectory,
  }) async {
    final helperPath = await _locateLinuxRunnerHelper();
    final isRoot = await _isRunningAsRoot();

    final String executable;
    final List<String> args;
    if (isRoot) {
      executable = helperPath;
      args = <String>[coreBinary, configPath];
      _rememberAppLog(
        'Launching TUN helper directly (already root): $helperPath',
      );
    } else {
      final pkexec = await _findOnPath('pkexec');
      if (pkexec == null) {
        throw const LinuxTunHelperUnavailableException(
          'pkexec was not found on PATH. Install policykit-1 (Debian/Ubuntu) '
          'or polkit (Fedora/Arch) to enable TUN mode, or run EntropyVPN as '
          'root.',
        );
      }
      executable = pkexec;
      // `--disable-internal-agent` is omitted so the user's session polkit
      // agent (gnome-authentication-agent, lxqt-policykit, etc.) handles the
      // prompt. pkexec proxies stdin/stdout/stderr through to the elevated
      // child by default.
      args = <String>[helperPath, coreBinary, configPath];
      _rememberAppLog(
        'Launching TUN helper via pkexec: $pkexec $helperPath '
        '<core> <config>',
      );
    }

    return Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.normal,
    );
  }

  /// Resolves the path of the bundled `entropy_vpn_runner.sh`. Searches the
  /// same candidate roots as the core binary, then falls back to the install
  /// layout under `share/entropy_vpn/helpers/`.
  Future<String> _locateLinuxRunnerHelper() async {
    final candidates = <String>{};
    for (final root in _candidateRoots()) {
      candidates.add(p.join(root, 'share', 'entropy_vpn', 'helpers',
          _linuxRunnerHelperName));
      candidates.add(p.join(root, 'linux', 'helpers', _linuxRunnerHelperName));
      candidates.add(p.join(root, 'helpers', _linuxRunnerHelperName));
    }
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    throw LinuxTunHelperUnavailableException(
      '$_linuxRunnerHelperName not found next to the bundle. Looked under '
      'share/entropy_vpn/helpers/, linux/helpers/, helpers/.',
    );
  }

  Future<bool> _isRunningAsRoot() async {
    try {
      final result = await Process.run('id', <String>['-u']);
      if (result.exitCode != 0) {
        return false;
      }
      final uid = int.tryParse(result.stdout.toString().trim());
      return uid == 0;
    } on ProcessException {
      // `id` should always exist on Linux; if it doesn't, assume not root.
      return false;
    }
  }

  Future<String?> _findOnPath(String tool) async {
    try {
      final result = await Process.run('which', <String>[tool]);
      if (result.exitCode != 0) {
        return null;
      }
      final line = result.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .map((s) => s.trim())
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      return line.isEmpty ? null : line;
    } on ProcessException {
      return null;
    }
  }

  /// Parses the generated core config to find an HTTP/SOCKS inbound port
  /// suitable for system-proxy mode. Returns null if no usable inbound is
  /// found (e.g. native TUN configs, malformed JSON).
  int? _extractLinuxInboundPort(String configJson) {
    try {
      final decoded = jsonDecode(configJson);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final inbounds = decoded['inbounds'];
      if (inbounds is! List) {
        return null;
      }
      for (final inbound in inbounds) {
        if (inbound is! Map) {
          continue;
        }
        final kind = (inbound['protocol'] ?? inbound['type'])
            ?.toString()
            .toLowerCase();
        if (kind != 'http' && kind != 'mixed' && kind != 'socks') {
          continue;
        }
        final port = inbound['port'] ?? inbound['listen_port'];
        if (port is num && port > 0 && port <= 65535) {
          return port.toInt();
        }
      }
    } catch (_) {
      // Fall through to null.
    }
    return null;
  }

  /// Configures the GNOME system proxy via `gsettings`. Best-effort: on
  /// non-GNOME desktops (KDE, etc.) `gsettings` may be missing or the schema
  /// may not apply — failures are logged but never fatal.
  Future<void> _applyLinuxSystemProxy(int port) async {
    final commands = <List<String>>[
      ['set', 'org.gnome.system.proxy', 'mode', 'manual'],
      ['set', 'org.gnome.system.proxy.http', 'host', '127.0.0.1'],
      ['set', 'org.gnome.system.proxy.http', 'port', '$port'],
      ['set', 'org.gnome.system.proxy.https', 'host', '127.0.0.1'],
      ['set', 'org.gnome.system.proxy.https', 'port', '$port'],
    ];
    for (final args in commands) {
      try {
        final result = await Process.run('gsettings', args);
        if (result.exitCode != 0) {
          _rememberAppLog(
            'gsettings ${args.join(' ')} exit=${result.exitCode} '
            'stderr=${result.stderr.toString().trim()}',
          );
          return;
        }
      } on ProcessException catch (error) {
        _rememberAppLog(
          'gsettings unavailable (${error.message}); set http_proxy manually '
          'to 127.0.0.1:$port.',
        );
        return;
      }
    }
    _rememberAppLog('GNOME system proxy set to 127.0.0.1:$port.');
  }

  Future<void> _restoreLinuxSystemProxy() async {
    try {
      final result = await Process.run('gsettings', <String>[
        'set',
        'org.gnome.system.proxy',
        'mode',
        'none',
      ]);
      if (result.exitCode == 0) {
        _rememberAppLog('GNOME system proxy reset to none.');
      }
    } on ProcessException {
      // gsettings absent; nothing to restore.
    }
  }

  Future<Directory> _prepareLinuxRuntimeDirectory() {
    return Directory.systemTemp.createTemp('entropy_vpn_');
  }

  List<String> _linuxCoreArguments(CoreFlavor core, String configPath) {
    return switch (core) {
      CoreFlavor.xray => <String>['run', '-c', configPath],
      CoreFlavor.singBox => <String>['run', '-c', configPath],
    };
  }

  void _attachLinuxProcessStreams(Process process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_rememberLog, onError: (Object error) {
      _rememberAppLog('stdout stream error: ${_describeError(error)}');
    });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_rememberLog, onError: (Object error) {
      _rememberAppLog('stderr stream error: ${_describeError(error)}');
    });
  }

  Future<void> _watchLinuxProcessExit(Process process) async {
    final exitCode = await process.exitCode;
    // Only signal an unexpected exit if this process is still the active one;
    // a manual stop nulls _process first.
    if (!identical(_process, process)) {
      return;
    }
    _process = null;
    _rememberAppLog(
      'Linux runtime process exited unexpectedly (exit=$exitCode).',
    );
    onProcessExit?.call(
      exitCode == 0 ? null : 'Core exited with code $exitCode.',
    );
  }
}
