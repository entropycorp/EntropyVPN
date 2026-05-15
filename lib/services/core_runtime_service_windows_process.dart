part of 'core_runtime_service.dart';

extension CoreRuntimeServiceWindowsProcess on CoreRuntimeService {
  Future<void> _stopStaleWindowsTunCoreProcesses(String binaryPath) async {
    if (!Platform.isWindows) {
      return;
    }

    final stopwatch = Stopwatch()..start();
    try {
      final rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('stopStaleCoreProcesses', <String, Object?>{
            'binaryPath': binaryPath,
            'currentPid': pid,
            'waitMs': 500,
          });
      stopwatch.stop();
      if (rawResult is! Map) {
        _rememberAppLog(
          'Native stale ${p.basename(binaryPath)} process sweep unavailable: runner returned unexpected result.',
        );
        return;
      }
      final result = rawResult.cast<Object?, Object?>();
      final elapsedMs = result['elapsedMs']?.toString();
      _rememberAppLog(
        'Process timing: native:stale_core_sweep elapsed=${elapsedMs ?? stopwatch.elapsedMilliseconds}ms exit=${result['ok'] == true ? 0 : 1}.',
      );
      if (result['ok'] != true) {
        final failedStep = result['failedStep']?.toString() ?? 'unknown';
        final error = result['error']?.toString() ?? 'unknown error';
        _rememberAppLog(
          'Native stale ${p.basename(binaryPath)} process sweep unavailable: $failedStep failed: $error',
        );
        return;
      }

      final failedPids = _nativePidList(result['failedPids']);
      if (failedPids.isNotEmpty) {
        _rememberAppLog(
          'Fast stale core sweep could not stop PID(s) ${failedPids.join(',')}.',
        );
      }
      final stoppedPids = <int>[
        ..._nativePidList(result['terminatedPids']),
        ..._nativePidList(result['exitedPids']),
      ];
      if (stoppedPids.isNotEmpty) {
        _rememberAppLog(
          'Stopped stale ${p.basename(binaryPath)} process(es) before TUN start: ${stoppedPids.join(',')}.',
        );
      }
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: native:stale_core_sweep elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      _rememberAppLog('Fast stale core sweep unavailable.');
    }
  }

  Future<bool> _terminateWindowsProcessTreeByPid(
    int processId, {
    String? timingLabel,
    Duration waitTimeout = const Duration(milliseconds: 500),
  }) async {
    final stopwatch = Stopwatch()..start();
    var success = false;
    try {
      final rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('terminateProcessTree', <String, Object?>{
            'pid': processId,
            'waitMs': waitTimeout.inMilliseconds,
          });
      if (rawResult is! Map) {
        _rememberAppLog(
          'Native process termination failed for PID $processId: runner returned unexpected result.',
        );
        return false;
      }
      final result = rawResult.cast<Object?, Object?>();
      final failedPids = _nativePidList(result['failedPids']);
      success = result['ok'] == true && result['success'] == true;
      if (failedPids.isNotEmpty) {
        final error = result['error']?.toString() ?? 'unknown error';
        _rememberAppLog(
          'Native process termination could not stop PID(s) ${failedPids.join(',')}: $error',
        );
      }
      return success;
    } catch (error) {
      _rememberAppLog(
        'Native process termination failed for PID $processId: ${_describeError(error)}',
      );
      return false;
    } finally {
      stopwatch.stop();
      if (timingLabel != null) {
        _rememberAppLog(
          'Process timing: $timingLabel elapsed=${stopwatch.elapsedMilliseconds}ms exit=${success ? 0 : 1}.',
        );
      }
    }
  }

  List<int> _nativePidList(Object? rawValue) {
    if (rawValue is! List) {
      return const <int>[];
    }
    return rawValue
        .whereType<num>()
        .map((value) => value.toInt())
        .where((value) => value > 0)
        .toList(growable: false);
  }

  Future<bool> _relaunchAsAdministrator() async {
    try {
      final executable = Platform.resolvedExecutable;
      final rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>('relaunchAsAdministrator', <String, Object?>{
            'executable': executable,
            'workingDirectory': p.dirname(executable),
            'arguments': '--entropyvpn-elevated-relaunch',
          });
      if (rawResult is Map) {
        final result = rawResult.cast<Object?, Object?>();
        if (result['ok'] == true) {
          return true;
        }
        final failedStep = result['failedStep']?.toString() ?? 'unknown';
        final error = result['error']?.toString() ?? 'unknown error';
        _rememberAppLog(
          'Failed to relaunch as Administrator: $failedStep failed: $error',
        );
        return false;
      }
      _rememberAppLog(
        'Failed to relaunch as Administrator: native runner returned an unexpected result.',
      );
      return false;
    } catch (error) {
      _rememberAppLog(
        'Failed to relaunch as Administrator: ${_describeError(error)}',
      );
      return false;
    }
  }

  Future<SplitTunnelSettings> _expandSplitTunnelSettings(
    SplitTunnelSettings settings,
  ) async {
    final normalized = settings.normalized;
    if (!Platform.isWindows ||
        !normalized.isEnabled ||
        normalized.apps.isEmpty) {
      return normalized;
    }

    final cacheKey = _splitTunnelExpansionCacheKey(normalized);
    final cached = _splitTunnelExpansionCache;
    final now = DateTime.now();
    if (cached != null &&
        cached.key == cacheKey &&
        now.difference(cached.createdAt) <=
            CoreRuntimeService._splitTunnelExpansionCacheTtl) {
      _rememberAppLog(
        'Split tunneling reused cached process tree expansion (${cached.addedAppCount} child process paths).',
      );
      return cached.settings;
    }

    final descendants = await _findRunningDescendantApps(normalized.apps);

    final appsById = <String, SplitTunnelApp>{
      for (final app in normalized.apps) app.id: app,
    };
    for (final app in descendants) {
      appsById[app.id] = app;
    }
    final expanded = SplitTunnelSettings(
      mode: normalized.mode,
      apps: appsById.values.toList(growable: false),
    ).normalized;
    final addedAppCount = expanded.apps.length - normalized.apps.length;
    _splitTunnelExpansionCache = _SplitTunnelExpansionCacheEntry(
      key: cacheKey,
      settings: expanded,
      createdAt: now,
      addedAppCount: addedAppCount,
    );
    if (addedAppCount > 0) {
      _rememberAppLog(
        'Split tunneling added $addedAppCount running child process paths.',
      );
    }
    return expanded;
  }

  String _splitTunnelExpansionCacheKey(SplitTunnelSettings settings) {
    final normalized = settings.normalized;
    final appKeys =
        normalized.apps
            .map((app) => app.id)
            .where((id) => id.trim().isNotEmpty)
            .toList(growable: false)
          ..sort();
    return '${normalized.mode.name}|${appKeys.join('\n')}';
  }

  Future<List<SplitTunnelApp>> _findRunningDescendantApps(
    List<SplitTunnelApp> selectedApps,
  ) async {
    if (!Platform.isWindows) {
      return const <SplitTunnelApp>[];
    }

    final selectedPaths = selectedApps
        .map((app) => app.path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (selectedPaths.isEmpty) {
      return const <SplitTunnelApp>[];
    }

    final stopwatch = Stopwatch()..start();
    try {
      final rawResult = await CoreRuntimeService._windowsTunChannel
          .invokeMethod<Object?>(
            'expandSplitTunnelProcessTree',
            <String, Object?>{'selectedPaths': selectedPaths},
          );
      stopwatch.stop();
      if (rawResult is! Map) {
        _rememberAppLog(
          'Native split tunnel process tree expansion unavailable: runner returned unexpected result.',
        );
        return const <SplitTunnelApp>[];
      }
      final result = rawResult.cast<Object?, Object?>();
      final elapsedMs = result['elapsedMs']?.toString();
      if (result['ok'] != true) {
        final failedStep = result['failedStep']?.toString() ?? 'unknown';
        final error = result['error']?.toString() ?? 'unknown error';
        final elapsed = elapsedMs == null ? '' : ' after ${elapsedMs}ms';
        _rememberAppLog(
          'Native split tunnel process tree expansion unavailable: $failedStep failed$elapsed: $error',
        );
        return const <SplitTunnelApp>[];
      }

      final paths = result['paths'] is List
          ? result['paths'] as List
          : const <dynamic>[];
      final descendants =
          paths
              .whereType<String>()
              .map((path) => path.trim())
              .where((path) => path.isNotEmpty)
              .map(
                (path) => SplitTunnelApp.fromPath(
                  name: p.basenameWithoutExtension(path),
                  path: path,
                ),
              )
              .toList(growable: false)
            ..sort(
              (left, right) =>
                  left.name.toLowerCase().compareTo(right.name.toLowerCase()),
            );
      final processCount = result['processCount']?.toString();
      final rootCount = result['rootCount']?.toString();
      _rememberAppLog(
        'Process timing: native:expand_split_tunnel_process_tree elapsed=${elapsedMs ?? stopwatch.elapsedMilliseconds}ms exit=0.',
      );
      if (processCount != null || rootCount != null) {
        _rememberAppLog(
          'Split tunnel process tree scanned ${_orDash(processCount)} process(es), matched ${_orDash(rootCount)} selected root process(es).',
        );
      }
      return descendants;
    } on MissingPluginException {
      stopwatch.stop();
      _rememberAppLog(
        'Native split tunnel process tree expansion unavailable: Windows runner channel is not registered.',
      );
      return const <SplitTunnelApp>[];
    } on PlatformException catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Native split tunnel process tree expansion unavailable: ${error.message ?? error.code}',
      );
      return const <SplitTunnelApp>[];
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: native:expand_split_tunnel_process_tree elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      _rememberAppLog(
        'Native split tunnel process tree expansion unavailable; continuing with selected apps only.',
      );
      return const <SplitTunnelApp>[];
    }
  }

  Future<bool?> _isRunningAsAdministrator() async {
    if (!Platform.isWindows) {
      return null;
    }
    final cached = _cachedWindowsElevation;
    if (cached != null) {
      return cached;
    }

    final fastElevation = _detectWindowsElevationWithToken();
    if (fastElevation != null) {
      _cachedWindowsElevation = fastElevation;
      return fastElevation;
    }

    final fltmcElevation = await _detectWindowsElevationWithFltmc();
    if (fltmcElevation != null) {
      _cachedWindowsElevation = fltmcElevation;
      return fltmcElevation;
    }

    _rememberAppLog('Failed to detect elevation with native probes.');
    return null;
  }

  bool? _detectWindowsElevationWithToken() {
    final stopwatch = Stopwatch()..start();
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final advapi32 = DynamicLibrary.open('advapi32.dll');
      final getCurrentProcess = kernel32
          .lookupFunction<GetCurrentProcessNative, GetCurrentProcessDart>(
            'GetCurrentProcess',
          );
      final closeHandle = kernel32
          .lookupFunction<CloseHandleNative, CloseHandleDart>('CloseHandle');
      final openProcessToken = advapi32
          .lookupFunction<OpenProcessTokenNative, OpenProcessTokenDart>(
            'OpenProcessToken',
          );
      final getTokenInformation = advapi32
          .lookupFunction<GetTokenInformationNative, GetTokenInformationDart>(
            'GetTokenInformation',
          );

      final tokenHandle = calloc<IntPtr>();
      final elevation = calloc<Uint32>();
      final returnLength = calloc<Uint32>();
      try {
        final opened = openProcessToken(
          getCurrentProcess(),
          windowsTokenQuery,
          tokenHandle,
        );
        if (opened == 0 || tokenHandle.value == 0) {
          return null;
        }

        final ok = getTokenInformation(
          tokenHandle.value,
          windowsTokenElevation,
          elevation.cast<Void>(),
          sizeOf<Uint32>(),
          returnLength,
        );
        if (ok == 0) {
          return null;
        }

        return elevation.value != 0;
      } finally {
        if (tokenHandle.value != 0) {
          closeHandle(tokenHandle.value);
        }
        calloc.free(returnLength);
        calloc.free(elevation);
        calloc.free(tokenHandle);
      }
    } catch (error) {
      _rememberAppLog(
        'Fast token elevation probe unavailable: ${_describeError(error)}',
      );
      return null;
    } finally {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: token:detect_elevation elapsed=${stopwatch.elapsedMilliseconds}ms.',
      );
    }
  }

  Future<bool?> _detectWindowsElevationWithFltmc() async {
    try {
      final result = await _runTimedProcess(
        'fltmc:detect_elevation',
        'fltmc.exe',
        const <String>[],
        timeout: const Duration(seconds: 1),
      );
      if (result.exitCode == 0) {
        return true;
      }

      final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
      if (output.contains('0x80070005') ||
          output.contains('access is denied') ||
          output.contains('requires elevation')) {
        return false;
      }

      _rememberAppLog(
        'Fast elevation probe unavailable: fltmc exited with ${result.exitCode}.',
      );
      return null;
    } catch (error) {
      _rememberAppLog(
        'Fast elevation probe unavailable: ${_describeError(error)}',
      );
      return null;
    }
  }
}
