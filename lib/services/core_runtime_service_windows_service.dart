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

  // --- In-app updater IPC ---------------------------------------------------

  Future<bool> _ensureWindowsServiceRunningForUpdate() async {
    if (!Platform.isWindows) {
      return false;
    }
    if (await _pingWindowsTunService()) {
      return true;
    }
    await _startWindowsTunService();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await _pingWindowsTunService()) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// Asks the privileged service to check for and download an update. Returns
  /// false when the service could not be reached.
  Future<bool> windowsUpdateCheckNow({bool force = false}) async {
    if (!await _ensureWindowsServiceRunningForUpdate()) {
      return false;
    }
    await _runWindowsServiceHelper(<String>[
      'update-check-now',
      '--force',
      force ? '1' : '0',
    ], timeout: const Duration(seconds: 20));
    return true;
  }

  /// Polls the current updater state from the service.
  Future<WindowsUpdateStatus> windowsUpdateStatus() async {
    final fields = await _runWindowsServiceHelper(<String>[
      'update-status',
    ], timeout: const Duration(seconds: 10));
    final available = _decodeWindowsServiceText(fields, 'availableVersionB64');
    final installed = _decodeWindowsServiceText(fields, 'installedVersionB64');
    final error = _decodeWindowsServiceText(fields, 'errorB64');
    return WindowsUpdateStatus(
      state: windowsUpdateStateFromName(fields['state'] ?? 'idle'),
      availableVersion: available.isEmpty ? null : available,
      installedVersion: installed.isEmpty ? null : installed,
      progressBytes: int.tryParse(fields['progressBytes'] ?? '') ?? 0,
      totalBytes: int.tryParse(fields['totalBytes'] ?? '') ?? 0,
      error: error.isEmpty ? null : error,
    );
  }

  /// Asks the service to apply the staged update. The service then closes the
  /// running UI to swap its files, so the caller should exit shortly after.
  Future<void> windowsUpdateApply() async {
    await _runWindowsServiceHelper(<String>[
      'update-apply',
    ], timeout: const Duration(seconds: 15));
  }
}
