part of 'core_runtime_service.dart';

extension CoreRuntimeServiceProcess on CoreRuntimeService {
  Future<String> _resolveBinary(CoreFlavor core) async {
    final fileNames = _platformBinaryNames(core);

    final candidates = <String>{};
    for (final root in _candidateRoots()) {
      for (final fileName in fileNames) {
        candidates.add(p.join(root, 'tools', 'cores', fileName));
        candidates.add(p.join(root, 'cores', fileName));
        if (Platform.isLinux) {
          candidates.add(p.join(root, 'tools', 'cores', 'linux', fileName));
        }
      }
    }

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    // Fall back to PATH lookup. Use `where` on Windows, `which` elsewhere.
    final lookupTool = Platform.isWindows ? 'where.exe' : 'which';
    for (final fileName in fileNames) {
      ProcessResult? pathLookup;
      try {
        pathLookup = await _runTimedProcess(
          '$lookupTool:$fileName',
          lookupTool,
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
    }

    throw StateError(
      'Binary ${fileNames.first} was not found. Expected in tools/cores or '
      'next to the built application, or on PATH.',
    );
  }

  List<String> _platformBinaryNames(CoreFlavor core) {
    if (Platform.isWindows) {
      return switch (core) {
        CoreFlavor.xray => const ['xray.exe'],
        CoreFlavor.singBox => const ['sing-box.exe'],
      };
    }
    return switch (core) {
      CoreFlavor.xray => const ['xray'],
      CoreFlavor.singBox => const ['sing-box'],
    };
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

  Future<String?> probeCoreVersion(CoreFlavor core) async {
    if (Platform.isAndroid) {
      final bridge = _androidBridge;
      if (bridge == null) {
        return null;
      }
      try {
        return await bridge.getCoreVersion(core.name);
      } catch (_) {
        return null;
      }
    }
    try {
      final binary = await _resolveBinary(core);
      final result = await _runTimedProcess(
        'probeVersion:${core.name}',
        binary,
        const <String>['version'],
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode != 0) {
        return null;
      }
      final output = '${result.stdout}\n${result.stderr}';
      final match = RegExp(
        r'\b(\d+\.\d+\.\d+(?:[-+][\w.]+)?)',
      ).firstMatch(output);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }
}
