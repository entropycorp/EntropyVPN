part of 'core_runtime_service.dart';

extension CoreRuntimeServiceWindowsProcess on CoreRuntimeService {
  Future<void> _stopStaleWindowsTunCoreProcesses(String binaryPath) async {
    if (!Platform.isWindows) {
      return;
    }

    if (_stopStaleWindowsTunCoreProcessesWithToolhelp(binaryPath)) {
      return;
    }

    const script = r'''
param(
  [string]$ExecutablePath,
  [string]$ExecutableName,
  [int]$CurrentProcessId
)
try {
  $targetPath = [System.IO.Path]::GetFullPath($ExecutablePath)
  $processes = Get-CimInstance Win32_Process -Filter "Name = '$ExecutableName'" |
    Where-Object {
      $_.ProcessId -ne $CurrentProcessId -and
      -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
      [System.IO.Path]::GetFullPath([string]$_.ExecutablePath) -ieq $targetPath
    }

  $stopped = foreach ($process in $processes) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    [string]$process.ProcessId
  }

  if ($stopped) {
    [Console]::Out.Write(($stopped -join ','))
  }
} catch {
  Write-Error -Message ([string]$_.Exception.Message)
  exit 1
}
''';

    try {
      final executableName = p.basename(binaryPath);
      final result = await _runPowerShellScript(
        script,
        label: 'stale_core_sweep',
        namedArgs: <String, String>{
          'ExecutablePath': binaryPath,
          'ExecutableName': executableName,
          'CurrentProcessId': pid.toString(),
        },
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to stop stale $executableName processes before TUN start: ${_describeError(result.stderr)}',
        );
        return;
      }

      final stoppedPids = result.stdout.toString().trim();
      if (stoppedPids.isNotEmpty) {
        _rememberAppLog(
          'Stopped stale $executableName process(es) before TUN start: $stoppedPids.',
        );
      }
    } catch (error) {
      final executableName = p.basename(binaryPath);
      _rememberAppLog(
        'Failed to stop stale $executableName processes before TUN start: ${_describeError(error)}',
      );
    }
  }

  bool _stopStaleWindowsTunCoreProcessesWithToolhelp(String binaryPath) {
    final stopwatch = Stopwatch()..start();
    try {
      final targetPathKey = windowsPathKey(binaryPath);
      final staleProcesses = _snapshotWindowsProcesses()
          .where(
            (process) =>
                process.pid != pid &&
                process.path != null &&
                windowsPathKey(process.path!) == targetPathKey,
          )
          .toList(growable: false);

      final stoppedPids = <String>[];
      final failedPids = <String>[];
      for (final process in staleProcesses) {
        if (_terminateWindowsProcessByPid(process.pid)) {
          stoppedPids.add(process.pid.toString());
        } else {
          failedPids.add(process.pid.toString());
        }
      }

      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:stale_core_sweep elapsed=${stopwatch.elapsedMilliseconds}ms exit=0.',
      );
      if (failedPids.isNotEmpty) {
        _rememberAppLog(
          'Fast stale core sweep could not stop PID(s) ${failedPids.join(',')}; falling back to PowerShell.',
        );
        return false;
      }
      if (stoppedPids.isNotEmpty) {
        _rememberAppLog(
          'Stopped stale ${p.basename(binaryPath)} process(es) before TUN start: ${stoppedPids.join(',')}.',
        );
      }
      return true;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:stale_core_sweep elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      _rememberAppLog(
        'Fast stale core sweep unavailable; falling back to PowerShell.',
      );
      return false;
    }
  }

  bool _terminateWindowsProcessByPid(
    int processId, {
    String? timingLabel,
    Duration waitTimeout = const Duration(milliseconds: 500),
  }) {
    final stopwatch = timingLabel == null ? null : (Stopwatch()..start());
    var success = false;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final openProcess = kernel32
          .lookupFunction<OpenProcessNative, OpenProcessDart>('OpenProcess');
      final terminateProcess = kernel32
          .lookupFunction<TerminateProcessNative, TerminateProcessDart>(
            'TerminateProcess',
          );
      final waitForSingleObject = kernel32
          .lookupFunction<WaitForSingleObjectNative, WaitForSingleObjectDart>(
            'WaitForSingleObject',
          );
      final closeHandle = kernel32
          .lookupFunction<CloseHandleNative, CloseHandleDart>('CloseHandle');

      final handle = openProcess(
        windowsProcessTerminate | windowsSynchronize,
        0,
        processId,
      );
      if (handle == 0) {
        success = Process.killPid(processId, ProcessSignal.sigkill);
        return success;
      }

      try {
        success = terminateProcess(handle, 1) != 0;
        if (success) {
          waitForSingleObject(handle, waitTimeout.inMilliseconds);
        }
        return success;
      } finally {
        closeHandle(handle);
      }
    } finally {
      stopwatch?.stop();
      if (timingLabel != null) {
        _rememberAppLog(
          'Process timing: $timingLabel elapsed=${stopwatch!.elapsedMilliseconds}ms exit=${success ? 0 : 1}.',
        );
      }
    }
  }

  Future<bool> _relaunchAsAdministrator() async {
    const script = r'''
param(
  [string]$FilePath,
  [string]$WorkingDirectory,
  [string]$RelaunchArgument
)
try {
  Start-Process `
    -FilePath $FilePath `
    -ArgumentList $RelaunchArgument `
    -WorkingDirectory $WorkingDirectory `
    -Verb RunAs | Out-Null
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final executable = Platform.resolvedExecutable;
      final result = await _runPowerShellScript(
        script,
        label: 'relaunch_as_administrator',
        namedArgs: <String, String>{
          'FilePath': executable,
          'WorkingDirectory': p.dirname(executable),
          'RelaunchArgument': '--entropyvpn-elevated-relaunch',
        },
      );
      if (result.exitCode == 0) {
        return true;
      }
      _rememberAppLog(
        'Failed to relaunch as Administrator: ${_describeError(result.stderr)}',
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
    final toolhelpDescendants = _findRunningDescendantAppsWithToolhelp(
      selectedApps,
    );
    if (toolhelpDescendants != null) {
      return toolhelpDescendants;
    }

    final selectedPaths = selectedApps
        .map((app) => app.path.trim())
        .where((path) => path.isNotEmpty)
        .join('\n');
    if (selectedPaths.isEmpty) {
      return const <SplitTunnelApp>[];
    }

    const script = r'''
param([string]$SelectedPathsBase64)
try {
  $selectedText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($SelectedPathsBase64))
  $selected = @{}
  $selectedText -split "`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $selected[$_.ToLowerInvariant()] = $true }

  $processes = @(Get-CimInstance -Query "SELECT ProcessId, ParentProcessId, ExecutablePath FROM Win32_Process WHERE ExecutablePath IS NOT NULL")
  $byParent = @{}
  foreach ($process in $processes) {
    $parent = [int]$process.ParentProcessId
    if (-not $byParent.ContainsKey($parent)) {
      $byParent[$parent] = New-Object System.Collections.Generic.List[object]
    }
    $byParent[$parent].Add($process)
  }

  $queue = New-Object System.Collections.Generic.Queue[int]
  foreach ($process in $processes) {
    $path = ([string]$process.ExecutablePath).Trim()
    if ($selected.ContainsKey($path.ToLowerInvariant())) {
      $queue.Enqueue([int]$process.ProcessId)
    }
  }

  $found = @{}
  while ($queue.Count -gt 0) {
    $parentId = $queue.Dequeue()
    if (-not $byParent.ContainsKey($parentId)) {
      continue
    }
    foreach ($child in $byParent[$parentId]) {
      $childPath = ([string]$child.ExecutablePath).Trim()
      if ([string]::IsNullOrWhiteSpace($childPath)) {
        continue
      }
      $key = $childPath.ToLowerInvariant()
      if (-not $selected.ContainsKey($key) -and -not $found.ContainsKey($key)) {
        $found[$key] = $childPath
      }
      $queue.Enqueue([int]$child.ProcessId)
    }
  }

  $found.Values |
    Sort-Object |
    ForEach-Object {
      [PSCustomObject]@{
        name = [System.IO.Path]::GetFileNameWithoutExtension($_)
        path = $_
      }
    } |
    ConvertTo-Json -Depth 3 -Compress
} catch {
  Write-Error $_
  exit 1
}
''';

    try {
      final result = await _runPowerShellScript(
        script,
        label: 'expand_split_tunnel_process_tree',
        namedArgs: <String, String>{
          'SelectedPathsBase64': base64Encode(utf8.encode(selectedPaths)),
        },
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to expand split tunnel process tree: ${_describeError(result.stderr)}',
        );
        return const <SplitTunnelApp>[];
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        return const <SplitTunnelApp>[];
      }
      final decoded = jsonDecode(output);
      final rawItems = decoded is List
          ? decoded
          : decoded is Map
          ? <dynamic>[decoded]
          : const <dynamic>[];
      return rawItems
          .map((item) {
            if (item is! Map) {
              return null;
            }
            return SplitTunnelApp.fromPath(
              name: item['name']?.toString() ?? '',
              path: item['path']?.toString() ?? '',
            );
          })
          .whereType<SplitTunnelApp>()
          .toList(growable: false);
    } catch (error) {
      _rememberAppLog(
        'Failed to expand split tunnel process tree: ${_describeError(error)}',
      );
      return const <SplitTunnelApp>[];
    }
  }

  List<SplitTunnelApp>? _findRunningDescendantAppsWithToolhelp(
    List<SplitTunnelApp> selectedApps,
  ) {
    if (!Platform.isWindows) {
      return null;
    }

    final selectedPathKeys = selectedApps
        .map((app) => windowsPathKey(app.path))
        .where((path) => path.isNotEmpty)
        .toSet();
    if (selectedPathKeys.isEmpty) {
      return const <SplitTunnelApp>[];
    }

    final stopwatch = Stopwatch()..start();
    try {
      final processes = _snapshotWindowsProcesses();
      final childrenByParent = <int, List<WindowsProcessInfo>>{};
      for (final process in processes) {
        childrenByParent
            .putIfAbsent(process.parentPid, () => <WindowsProcessInfo>[])
            .add(process);
      }

      final queue = Queue<int>();
      for (final process in processes) {
        final path = process.path;
        if (path != null && selectedPathKeys.contains(windowsPathKey(path))) {
          queue.add(process.pid);
        }
      }

      final descendantsByPath = <String, String>{};
      while (queue.isNotEmpty) {
        final parentPid = queue.removeFirst();
        final children = childrenByParent[parentPid];
        if (children == null) {
          continue;
        }
        for (final child in children) {
          final childPath = child.path;
          if (childPath != null && childPath.trim().isNotEmpty) {
            final childPathKey = windowsPathKey(childPath);
            if (!selectedPathKeys.contains(childPathKey) &&
                !descendantsByPath.containsKey(childPathKey)) {
              descendantsByPath[childPathKey] = childPath;
            }
          }
          queue.add(child.pid);
        }
      }

      final descendants =
          descendantsByPath.values
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
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:expand_split_tunnel_process_tree elapsed=${stopwatch.elapsedMilliseconds}ms exit=0.',
      );
      return descendants;
    } catch (error) {
      stopwatch.stop();
      _rememberAppLog(
        'Process timing: toolhelp:expand_split_tunnel_process_tree elapsed=${stopwatch.elapsedMilliseconds}ms failed=${_describeError(error)}.',
      );
      _rememberAppLog(
        'Fast split tunnel process tree expansion unavailable; falling back to PowerShell.',
      );
      return null;
    }
  }

  List<WindowsProcessInfo> _snapshotWindowsProcesses() {
    final cached = _windowsProcessSnapshotCache;
    final now = DateTime.now();
    if (cached != null &&
        now.difference(cached.createdAt) <=
            CoreRuntimeService._windowsProcessSnapshotCacheTtl) {
      return cached.processes;
    }

    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createToolhelp32Snapshot = kernel32
        .lookupFunction<
          CreateToolhelp32SnapshotNative,
          CreateToolhelp32SnapshotDart
        >('CreateToolhelp32Snapshot');
    final process32First = kernel32
        .lookupFunction<Process32Native, Process32Dart>('Process32FirstW');
    final process32Next = kernel32
        .lookupFunction<Process32Native, Process32Dart>('Process32NextW');
    final closeHandle = kernel32
        .lookupFunction<CloseHandleNative, CloseHandleDart>('CloseHandle');
    final openProcess = kernel32
        .lookupFunction<OpenProcessNative, OpenProcessDart>('OpenProcess');
    final queryFullProcessImageName = kernel32
        .lookupFunction<
          QueryFullProcessImageNameNative,
          QueryFullProcessImageNameDart
        >('QueryFullProcessImageNameW');

    final snapshot = createToolhelp32Snapshot(windowsTh32csSnapProcess, 0);
    if (snapshot == windowsInvalidHandleValue) {
      throw StateError('CreateToolhelp32Snapshot failed');
    }

    final entry = calloc<ProcessEntry32W>();
    try {
      entry.ref.dwSize = sizeOf<ProcessEntry32W>();
      if (process32First(snapshot, entry) == 0) {
        return const <WindowsProcessInfo>[];
      }

      final processes = <WindowsProcessInfo>[];
      do {
        final pid = entry.ref.th32ProcessID;
        processes.add(
          WindowsProcessInfo(
            pid: pid,
            parentPid: entry.ref.th32ParentProcessID,
            path: _queryWindowsProcessImagePath(
              pid,
              openProcess: openProcess,
              queryFullProcessImageName: queryFullProcessImageName,
              closeHandle: closeHandle,
            ),
          ),
        );
      } while (process32Next(snapshot, entry) != 0);
      final snapshotProcesses = List<WindowsProcessInfo>.unmodifiable(
        processes,
      );
      _windowsProcessSnapshotCache = WindowsProcessSnapshotCacheEntry(
        createdAt: now,
        processes: snapshotProcesses,
      );
      return snapshotProcesses;
    } finally {
      calloc.free(entry);
      closeHandle(snapshot);
    }
  }

  String? _queryWindowsProcessImagePath(
    int pid, {
    required OpenProcessDart openProcess,
    required QueryFullProcessImageNameDart queryFullProcessImageName,
    required CloseHandleDart closeHandle,
  }) {
    if (pid <= 0) {
      return null;
    }

    final process = openProcess(windowsProcessQueryLimitedInformation, 0, pid);
    if (process == 0) {
      return null;
    }

    final buffer = calloc<Uint16>(maxWindowsPathBufferChars);
    final length = calloc<Uint32>();
    try {
      length.value = maxWindowsPathBufferChars;
      final ok = queryFullProcessImageName(process, 0, buffer, length);
      if (ok == 0 || length.value == 0) {
        return null;
      }
      return String.fromCharCodes(buffer.asTypedList(length.value)).trim();
    } finally {
      calloc.free(length);
      calloc.free(buffer);
      closeHandle(process);
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

    const script = r'''
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  [Console]::Out.Write($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
  ''';

    try {
      final result = await _runPowerShellScript(
        script,
        label: 'detect_elevation',
      );
      if (result.exitCode != 0) {
        _rememberAppLog(
          'Failed to detect elevation: ${_describeError(result.stderr)}',
        );
        return null;
      }

      final output = result.stdout.toString().trim().toLowerCase();
      if (output == 'true') {
        _cachedWindowsElevation = true;
        return true;
      }
      if (output == 'false') {
        _cachedWindowsElevation = false;
        return false;
      }

      _rememberAppLog(
        'Failed to detect elevation: unexpected output "${result.stdout.toString().trim()}".',
      );
      return null;
    } catch (error) {
      _rememberAppLog('Failed to detect elevation: ${_describeError(error)}');
      return null;
    }
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
        'Fast elevation probe unavailable: fltmc exited with ${result.exitCode}; falling back to PowerShell.',
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
