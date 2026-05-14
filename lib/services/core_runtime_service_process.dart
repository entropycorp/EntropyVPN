part of 'core_runtime_service.dart';

extension CoreRuntimeServiceProcess on CoreRuntimeService {
  Future<String> _resolveBinary(CoreFlavor core) async {
    final fileName = switch (core) {
      CoreFlavor.xray => 'xray.exe',
      CoreFlavor.singBox => 'sing-box.exe',
    };

    final candidates = <String>{};
    for (final root in _candidateRoots()) {
      candidates.add(p.join(root, 'tools', 'cores', fileName));
      candidates.add(p.join(root, 'cores', fileName));
    }

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    ProcessResult? pathLookup;
    try {
      pathLookup = await _runTimedProcess(
        'where:$fileName',
        'where.exe',
        <String>[fileName],
      );
    } on ProcessException {
      pathLookup = null;
    }

    if (pathLookup != null && pathLookup.exitCode == 0) {
      final resolved = pathLookup.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      if (resolved.isNotEmpty) {
        return resolved;
      }
    }

    throw StateError(
      'Binary $fileName was not found. Expected in tools/cores or next to the built application.',
    );
  }

  Iterable<String> _candidateRoots() sync* {
    final seen = <String>{};

    for (final start in <String>[
      Directory.current.path,
      File(Platform.resolvedExecutable).parent.path,
    ]) {
      var current = p.normalize(start);
      while (seen.add(current)) {
        yield current;
        final parent = p.dirname(current);
        if (parent == current) {
          break;
        }
        current = parent;
      }
    }
  }

  Future<void> _terminateProcess(Process process) async {
    _rememberAppLog('Sending termination signal to PID ${process.pid}...');
    if (Platform.isWindows) {
      await _terminateWindowsProcess(process);
      return;
    }

    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _rememberAppLog(
        'Process PID ${process.pid} did not exit in time, forcing termination.',
      );
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  Future<void> _terminateWindowsProcess(Process process) async {
    var usedTaskkillFallback = false;
    try {
      final terminatedNatively = _terminateWindowsProcessByPid(
        process.pid,
        timingLabel: 'native_terminate:${process.pid}',
      );
      if (!terminatedNatively && !await _hasProcessExited(process)) {
        _rememberAppLog(
          'Native termination failed for PID ${process.pid}; falling back to taskkill.',
        );
        usedTaskkillFallback = true;
        await _terminateWindowsProcessWithTaskkill(process);
      }
    } catch (error) {
      _rememberAppLog(
        'Native termination failed for PID ${process.pid}: ${_describeError(error)}',
      );
      if (!await _hasProcessExited(process)) {
        usedTaskkillFallback = true;
        await _terminateWindowsProcessWithTaskkill(process);
      }
    }

    if (!await _hasProcessExited(process)) {
      process.kill(ProcessSignal.sigkill);
    }

    try {
      await process.exitCode.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      final method = usedTaskkillFallback ? 'native/taskkill' : 'native';
      _rememberAppLog(
        'Process PID ${process.pid} still did not report exit after $method termination.',
      );
    }
  }

  Future<void> _terminateWindowsProcessWithTaskkill(Process process) async {
    try {
      final result = await _runTimedProcess(
        'taskkill:${process.pid}',
        'taskkill.exe',
        <String>['/PID', process.pid.toString(), '/T', '/F'],
        timeout: const Duration(seconds: 2),
      );
      if (result.exitCode != 0 && !await _hasProcessExited(process)) {
        _rememberAppLog(
          'taskkill failed for PID ${process.pid}: ${_describeError(result.stderr)}',
        );
      }
    } catch (error) {
      _rememberAppLog(
        'taskkill failed for PID ${process.pid}: ${_describeError(error)}',
      );
    }
  }

  Future<bool> _hasProcessExited(Process process) async {
    try {
      await process.exitCode.timeout(Duration.zero);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _cleanupRuntimeDirectory(Directory directory) async {
    if (!directory.existsSync()) {
      return;
    }
    _rememberAppLog('Removing runtime directory ${directory.path}...');
    await directory.delete(recursive: true);
    _rememberAppLog('Runtime directory removed.');
  }

  String _formatCommand(String executable, List<String> args) {
    return ([executable, ...args]).map(_quoteIfNeeded).join(' ');
  }

  Future<ProcessResult> _runPowerShellScript(
    String script, {
    String label = 'script',
    Map<String, String> namedArgs = const <String, String>{},
  }) {
    return _runTimedProcess('powershell:$label', 'powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      _buildPowerShellInvocation(script, namedArgs: namedArgs),
    ]);
  }

  Future<ProcessResult> _runTimedProcess(
    String label,
    String executable,
    List<String> args, {
    String? workingDirectory,
    Duration? timeout,
  }) async {
    if (_shouldRunWithWindowsServiceHelper(executable)) {
      return _runWindowsServiceTimedProcess(
        label,
        executable,
        args,
        workingDirectory: workingDirectory,
        timeout: timeout,
      );
    }

    final stopwatch = Stopwatch()..start();
    try {
      final run = Process.run(
        executable,
        args,
        workingDirectory: workingDirectory,
      );
      final result = await (timeout == null ? run : run.timeout(timeout));
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms exit=${result.exitCode}.',
      );
      return result;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      rethrow;
    }
  }

  Future<Process> _startTimedProcess(
    String label,
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final process = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
      );
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms pid=${process.pid}.',
      );
      return process;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: $label elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      rethrow;
    }
  }

  String _buildPowerShellInvocation(
    String script, {
    Map<String, String> namedArgs = const <String, String>{},
  }) {
    final buffer = StringBuffer('& {\n');
    buffer.write(script.trim());
    buffer.write('\n}');
    namedArgs.forEach((key, value) {
      buffer.write(' -');
      buffer.write(key);
      buffer.write(' ');
      buffer.write(_quotePowerShellLiteral(value));
    });
    return buffer.toString();
  }

  String _quoteIfNeeded(String value) {
    return value.contains(' ') ? '"$value"' : value;
  }

  String _quotePowerShellLiteral(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }
}
