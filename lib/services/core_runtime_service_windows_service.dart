part of 'core_runtime_service.dart';

const String _windowsTunServiceName = 'EntropyVPNService';
const Set<String> _windowsTunServiceToolAllowlist = <String>{'fltmc.exe'};

class WindowsServiceCoreProcess {
  WindowsServiceCoreProcess({
    required this.runId,
    required this.pid,
    required this.stdoutPath,
    required this.stderrPath,
    required this.runtimeDirectory,
  });

  final String runId;
  final int pid;
  final String stdoutPath;
  final String stderrPath;
  final Directory runtimeDirectory;
  int stdoutOffset = 0;
  int stderrOffset = 0;
}

extension CoreRuntimeServiceWindowsService on CoreRuntimeService {
  Future<bool> _ensureWindowsTunServiceReady({
    required TunIpMode tunIpMode,
  }) async {
    if (!Platform.isWindows) {
      return false;
    }
    if (tunIpMode != TunIpMode.ipv4) {
      _rememberAppLog(
        'EntropyVPN Service helper currently supports automatic non-elevated Windows TUN startup for IPv4 mode; falling back to elevation for ${tunIpMode.name}.',
      );
      return false;
    }
    if (await _pingWindowsTunService()) {
      _windowsTunServiceReady = true;
      _rememberAppLog(
        'EntropyVPN Service helper is running; Windows TUN will start without relaunching the UI elevated.',
      );
      return true;
    }

    _rememberAppLog('Starting EntropyVPN Service helper...');
    await _startWindowsTunService();
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline)) {
      if (await _pingWindowsTunService()) {
        _windowsTunServiceReady = true;
        _rememberAppLog('EntropyVPN Service helper is ready.');
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    _rememberAppLog(
      'EntropyVPN Service helper did not become ready; falling back to elevation.',
    );
    return false;
  }

  Future<void> _startWindowsTunService() async {
    try {
      final rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('startWindowsService', <String, Object?>{
            'serviceName': _windowsTunServiceName,
            'timeoutMs': 1500,
          });
      if (rawResult is! Map) {
        _rememberAppLog(
          'Could not start $_windowsTunServiceName: native runner returned unexpected result.',
        );
        return;
      }
      final result = rawResult.cast<Object?, Object?>();
      final elapsedMs = result['elapsedMs']?.toString();
      final state = result['state']?.toString() ?? 'unknown';
      final elapsed = elapsedMs == null ? '' : ' elapsed=${elapsedMs}ms';
      if (result['ok'] != true) {
        final failedStep = result['failedStep']?.toString() ?? 'unknown';
        final error = result['error']?.toString() ?? 'unknown error';
        _rememberAppLog(
          'Could not start $_windowsTunServiceName: $failedStep failed$elapsed: $error',
        );
        return;
      }

      if (result['running'] == true) {
        final action = result['alreadyRunning'] == true
            ? 'already running'
            : result['startRequested'] == true
            ? 'started'
            : 'running';
        _rememberAppLog(
          '$_windowsTunServiceName $action via native service control$elapsed.',
        );
        return;
      }

      _rememberAppLog(
        '$_windowsTunServiceName native start requested but service is $state$elapsed.',
      );
    } on MissingPluginException {
      _rememberAppLog(
        'Could not start $_windowsTunServiceName: Windows runner channel is not registered.',
      );
    } on PlatformException catch (error) {
      _rememberAppLog(
        'Could not start $_windowsTunServiceName: ${error.message ?? error.code}',
      );
    } catch (error) {
      _rememberAppLog(
        'Could not start $_windowsTunServiceName: ${_describeError(error)}',
      );
    }
  }

  Future<bool> _pingWindowsTunService() async {
    try {
      await _runWindowsServiceHelper(const <String>[
        'ping',
      ], timeout: const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<WindowsServiceCoreProcess> _startWindowsServiceCore({
    required CoreFlavor core,
    required String binaryPath,
    required List<String> args,
    required String workingDirectory,
    required Directory runtimeDirectory,
  }) async {
    final runId = '${DateTime.now().microsecondsSinceEpoch}-$pid-${core.name}';
    final stdoutPath = p.join(runtimeDirectory.path, 'core.stdout.log');
    final stderrPath = p.join(runtimeDirectory.path, 'core.stderr.log');
    final helperArgs = <String>[
      'start-core',
      '--run-id',
      runId,
      '--executable',
      binaryPath,
      '--working-directory',
      workingDirectory,
      '--stdout-path',
      stdoutPath,
      '--stderr-path',
      stderrPath,
      for (final arg in args) ...<String>['--arg', arg],
    ];

    final response = await _runWindowsServiceHelper(
      helperArgs,
      timeout: const Duration(seconds: 10),
      timingLabel: 'start_core',
    );
    final processId = int.tryParse(response['pid'] ?? '') ?? 0;
    if (processId <= 0) {
      throw StateError('EntropyVPN Service did not return a core PID.');
    }

    final serviceProcess = WindowsServiceCoreProcess(
      runId: runId,
      pid: processId,
      stdoutPath: stdoutPath,
      stderrPath: stderrPath,
      runtimeDirectory: runtimeDirectory,
    );
    _windowsServiceProcess = serviceProcess;
    _runtimeDirectory = runtimeDirectory;
    _startWindowsServicePolling();
    final serviceExecutable = _decodeWindowsServiceText(
      response,
      'executableB64',
    ).trim();
    _rememberAppLog(
      'Core process started by EntropyVPN Service with PID $processId${serviceExecutable.isEmpty ? '' : ' using $serviceExecutable'}.',
    );
    return serviceProcess;
  }

  Future<void> _stopWindowsServiceCore(
    WindowsServiceCoreProcess process,
  ) async {
    _rememberAppLog(
      'Stopping service-managed core process PID ${process.pid}...',
    );
    try {
      final response = await _runWindowsServiceHelper(<String>[
        'stop-core',
        '--run-id',
        process.runId,
      ], timeout: const Duration(seconds: 8));
      await _tailWindowsServiceLogs(process);
      final exitCode = response['exitCode'];
      _rememberAppLog(
        'Service-managed core process stopped${exitCode == null ? '' : ' with code $exitCode'}.',
      );
    } catch (error) {
      _rememberAppLog(
        'Failed to stop service-managed core process: ${_describeError(error)}',
      );
    }
  }

  void _startWindowsServicePolling() {
    _windowsServicePollTimer?.cancel();
    _windowsServicePollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_pollWindowsServiceCore()),
    );
  }

  Future<void> _pollWindowsServiceCore() async {
    if (_windowsServiceStartupSetupInProgress) {
      return;
    }
    if (_windowsServicePollInFlight) {
      return;
    }
    final serviceProcess = _windowsServiceProcess;
    if (serviceProcess == null) {
      _cleanupWindowsServicePolling();
      return;
    }

    _windowsServicePollInFlight = true;
    try {
      await _tailWindowsServiceLogs(serviceProcess);
      final status = await _runWindowsServiceHelper(<String>[
        'status-core',
        '--run-id',
        serviceProcess.runId,
      ], timeout: const Duration(seconds: 2));
      if (status['running'] == '1') {
        return;
      }

      if (!identical(_windowsServiceProcess, serviceProcess)) {
        return;
      }

      final exitCode = int.tryParse(status['exitCode'] ?? '') ?? 0;
      _rememberAppLog('Core process exited with code $exitCode.');
      _windowsServiceProcess = null;
      _cleanupWindowsServicePolling();
      await _removeTemporaryTunRoutes();
      await _removeTemporaryServerRoute();
      await _restoreProxyIfNeeded();
      await _cleanupSubscriptions();
      await _cleanupRuntimeDirectory(serviceProcess.runtimeDirectory);
      _runtimeDirectory = null;
      onProcessExit?.call(_buildUnexpectedExitMessage(exitCode));
    } catch (error) {
      _rememberAppLog(
        'Service-managed core status check failed: ${_describeError(error)}',
      );
    } finally {
      _windowsServicePollInFlight = false;
    }
  }

  Future<void> _tailWindowsServiceLogs(
    WindowsServiceCoreProcess process,
  ) async {
    process.stdoutOffset = await _tailWindowsServiceLog(
      process.stdoutPath,
      process.stdoutOffset,
      isError: false,
    );
    process.stderrOffset = await _tailWindowsServiceLog(
      process.stderrPath,
      process.stderrOffset,
      isError: true,
    );
  }

  Future<int> _tailWindowsServiceLog(
    String path,
    int offset, {
    required bool isError,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      return 0;
    }
    final length = await file.length();
    final start = offset > length ? 0 : offset;
    if (length <= start) {
      return start;
    }

    final handle = await file.open();
    try {
      await handle.setPosition(start);
      final bytes = await handle.read(length - start);
      final text = utf8.decode(bytes, allowMalformed: true);
      _rememberProcessOutput(isError ? 'ERR: ' : '', text);
      return length;
    } finally {
      await handle.close();
    }
  }

  void _cleanupWindowsServicePolling() {
    _windowsServicePollTimer?.cancel();
    _windowsServicePollTimer = null;
    _windowsServicePollInFlight = false;
  }

  bool _shouldRunWithWindowsServiceHelper(String executable) {
    if (!_windowsTunServiceReady || !Platform.isWindows) {
      return false;
    }
    final executableName = p.basename(executable).toLowerCase();
    return _windowsTunServiceToolAllowlist.contains(executableName);
  }

  Future<ProcessResult> _runWindowsServiceTimedProcess(
    String label,
    String executable,
    List<String> args, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    final timeoutMs = (timeout ?? const Duration(seconds: 30)).inMilliseconds;
    try {
      final response = await _runWindowsServiceHelper(<String>[
        'run-process',
        '--executable',
        p.basename(executable),
        '--timeout-ms',
        timeoutMs.toString(),
        if (workingDirectory != null) ...<String>[
          '--working-directory',
          workingDirectory,
        ],
        for (final arg in args) ...<String>['--arg', arg],
      ], timeout: Duration(milliseconds: timeoutMs + 5000));
      stopwatch.stop();
      final exitCode = int.tryParse(response['exitCode'] ?? '') ?? 1;
      final processId = int.tryParse(response['pid'] ?? '') ?? 0;
      _rememberAppLog(
        'Process timing: service:$label elapsed=${stopwatch.elapsedMilliseconds}ms exit=$exitCode.',
      );
      return ProcessResult(
        processId,
        exitCode,
        _decodeWindowsServiceText(response, 'stdoutB64'),
        _decodeWindowsServiceText(response, 'stderrB64'),
      );
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: service:$label elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      rethrow;
    }
  }

  Future<Map<String, String>> _runWindowsServiceHelper(
    List<String> args, {
    Duration timeout = const Duration(seconds: 5),
    String? timingLabel,
  }) async {
    final stopwatch = Stopwatch()..start();
    var transport = 'native_pipe';
    try {
      final rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('runWindowsServiceHelper', <String, Object?>{
            'args': args,
            'timeoutMs': timeout.inMilliseconds,
          })
          .timeout(timeout + const Duration(seconds: 1));
      if (rawResult is! Map) {
        throw StateError(
          'EntropyVPN service helper native runner returned unexpected result.',
        );
      }
      final result = rawResult.cast<Object?, Object?>();
      transport = result['transport']?.toString() ?? transport;
      if (result['ok'] != true) {
        throw StateError(
          result['error']?.toString() ??
              'EntropyVPN Service request failed in native runner.',
        );
      }
      final fields = result['fields'];
      if (fields is! Map) {
        throw StateError(
          'EntropyVPN service helper native runner returned no response fields.',
        );
      }
      final response = fields.map<String, String>(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
      stopwatch.stop();
      _logWindowsServiceRequestTiming(
        timingLabel,
        transport: transport,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return response;
    } catch (error) {
      stopwatch.stop();
      _logWindowsServiceRequestTiming(
        timingLabel,
        transport: transport,
        elapsedMs: stopwatch.elapsedMilliseconds,
        error: error,
      );
      rethrow;
    }
  }

  void _logWindowsServiceRequestTiming(
    String? label, {
    required String transport,
    required int elapsedMs,
    Object? error,
  }) {
    if (label == null) {
      return;
    }
    _rememberAppLog(
      'Service request timing: $label transport=$transport elapsed=${elapsedMs}ms${error == null ? '' : ' failed=${_describeError(error)}'}.',
    );
  }

  String _decodeWindowsServiceText(Map<String, String> fields, String key) {
    final encoded = fields[key];
    if (encoded == null || encoded.isEmpty) {
      return '';
    }
    try {
      return utf8.decode(base64Decode(encoded), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }
}
