part of 'core_runtime_service.dart';

const String _windowsTunServiceName = 'EntropyVPNService';
const String _windowsTunServicePipePath = r'\\.\pipe\EntropyVPNService';
const Set<String> _windowsTunServiceToolAllowlist = <String>{
  'route.exe',
  'netsh.exe',
  'fltmc.exe',
};

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
      final result = await Process.run('sc.exe', <String>[
        'start',
        _windowsTunServiceName,
      ]);
      if (result.exitCode != 0 &&
          !'${result.stdout}\n${result.stderr}'.toLowerCase().contains(
            'already',
          )) {
        _rememberAppLog(
          'Could not start $_windowsTunServiceName: ${_describeError(result.stderr)}',
        );
      }
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
    var transport = 'direct_pipe';
    try {
      final request = _buildWindowsServiceRequest(args);
      final directResult = await Isolate.run(
        () => _trySendWindowsServicePipeRequest(
          request,
          timeoutMs: timeout.inMilliseconds,
        ),
      ).timeout(timeout + const Duration(seconds: 1));
      final directError = directResult.transportError;
      if (directError != null) {
        transport = 'helper_process';
        final response = await _runWindowsServiceHelperProcess(
          args,
          timeout: timeout,
          directError: directError,
        );
        stopwatch.stop();
        _logWindowsServiceRequestTiming(
          timingLabel,
          transport: transport,
          elapsedMs: stopwatch.elapsedMilliseconds,
        );
        return response;
      }
      final response = _parseWindowsServiceResponse(directResult.response);
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

  Future<Map<String, String>> _runWindowsServiceHelperProcess(
    List<String> args, {
    required Duration timeout,
    required String directError,
  }) async {
    final helperPath = _resolveWindowsServiceHelperPath();
    if (helperPath == null) {
      throw StateError(
        'EntropyVPN service pipe request failed and entropy_vpn_service.exe was not found for fallback: $directError',
      );
    }
    final run = Process.run(helperPath, args);
    final result = await run.timeout(timeout);
    final stdout = result.stdout.toString();
    return _parseWindowsServiceResponse(
      stdout,
      stderr: result.stderr.toString(),
      exitCode: result.exitCode,
    );
  }

  Map<String, String> _parseWindowsServiceResponse(
    String stdout, {
    String stderr = '',
    int exitCode = 0,
  }) {
    final fields = _parseWindowsServiceFields(stdout);
    if (fields['ok'] == '1') {
      return fields;
    }

    final message =
        _decodeWindowsServiceText(fields, 'errorB64').trim().isNotEmpty
        ? _decodeWindowsServiceText(fields, 'errorB64').trim()
        : stderr.trim().isNotEmpty
        ? stderr.trim()
        : stdout.trim().isNotEmpty
        ? stdout.trim()
        : 'EntropyVPN Service request failed with exit $exitCode.';
    throw StateError(message);
  }

  String _buildWindowsServiceRequest(List<String> args) {
    if (args.isEmpty) {
      throw StateError('Missing EntropyVPN service command.');
    }

    final command = args.first;
    final request = StringBuffer();
    if (command == 'ping') {
      _writeWindowsServiceField(request, 'command', 'ping');
    } else if (command == 'start-core') {
      _writeWindowsServiceField(request, 'command', 'start_core');
      _writeWindowsServiceEncodedField(
        request,
        'runId',
        _windowsServiceOptionValue(args, '--run-id'),
      );
      _writeWindowsServiceEncodedField(
        request,
        'executable',
        _windowsServiceOptionValue(args, '--executable'),
      );
      _writeWindowsServiceEncodedField(
        request,
        'workingDirectory',
        _windowsServiceOptionValue(args, '--working-directory'),
      );
      _writeWindowsServiceEncodedField(
        request,
        'stdoutPath',
        _windowsServiceOptionValue(args, '--stdout-path'),
      );
      _writeWindowsServiceEncodedField(
        request,
        'stderrPath',
        _windowsServiceOptionValue(args, '--stderr-path'),
      );
      _writeWindowsServiceArgumentFields(
        request,
        _windowsServiceRepeatedOptionValues(args, '--arg'),
      );
    } else if (command == 'stop-core') {
      _writeWindowsServiceField(request, 'command', 'stop_core');
      _writeWindowsServiceEncodedField(
        request,
        'runId',
        _windowsServiceOptionValue(args, '--run-id'),
      );
    } else if (command == 'status-core') {
      _writeWindowsServiceField(request, 'command', 'status_core');
      _writeWindowsServiceEncodedField(
        request,
        'runId',
        _windowsServiceOptionValue(args, '--run-id'),
      );
    } else if (command == 'run-process') {
      _writeWindowsServiceField(request, 'command', 'run_process');
      _writeWindowsServiceEncodedField(
        request,
        'executable',
        _windowsServiceOptionValue(args, '--executable'),
      );
      _writeWindowsServiceEncodedField(
        request,
        'workingDirectory',
        _windowsServiceOptionValue(args, '--working-directory'),
      );
      _writeWindowsServiceField(
        request,
        'timeoutMs',
        _windowsServiceOptionValue(args, '--timeout-ms', fallback: '30000'),
      );
      _writeWindowsServiceArgumentFields(
        request,
        _windowsServiceRepeatedOptionValues(args, '--arg'),
      );
    } else if (command == 'prepare-ipv4-server-route') {
      _writeWindowsServiceField(
        request,
        'command',
        'prepare_ipv4_server_route',
      );
      _writeWindowsServiceEncodedField(
        request,
        'remoteAddress',
        _windowsServiceOptionValue(args, '--remote-address'),
      );
    } else if (command == 'prepare-xray-tun-ipv4-routes') {
      _writeWindowsServiceField(
        request,
        'command',
        'prepare_xray_tun_ipv4_routes',
      );
      _writeWindowsServiceEncodedField(
        request,
        'interfaceAlias',
        _windowsServiceOptionValue(args, '--interface-alias'),
      );
      _writeWindowsServiceEncodedField(
        request,
        'address',
        _windowsServiceOptionValue(args, '--address'),
      );
      _writeWindowsServiceEncodedField(
        request,
        'dnsServers',
        _windowsServiceOptionValue(args, '--dns-servers'),
      );
      _writeWindowsServiceField(
        request,
        'timeoutMs',
        _windowsServiceOptionValue(args, '--timeout-ms', fallback: '2500'),
      );
      _writeWindowsServiceField(
        request,
        'prefixLength',
        _windowsServiceOptionValue(args, '--prefix-length', fallback: '30'),
      );
      _writeWindowsServiceField(
        request,
        'metric',
        _windowsServiceOptionValue(args, '--metric', fallback: '1'),
      );
    } else {
      throw StateError('Unknown EntropyVPN service command: $command');
    }

    return request.toString();
  }

  void _writeWindowsServiceArgumentFields(
    StringBuffer request,
    List<String> args,
  ) {
    _writeWindowsServiceField(request, 'argCount', args.length.toString());
    for (var index = 0; index < args.length; index += 1) {
      _writeWindowsServiceEncodedField(request, 'arg$index', args[index]);
    }
  }

  void _writeWindowsServiceField(
    StringBuffer request,
    String key,
    String value,
  ) {
    request
      ..write(key)
      ..write('=')
      ..write(value)
      ..write('\n');
  }

  void _writeWindowsServiceEncodedField(
    StringBuffer request,
    String key,
    String value,
  ) {
    _writeWindowsServiceField(request, key, base64Encode(utf8.encode(value)));
  }

  String _windowsServiceOptionValue(
    List<String> args,
    String name, {
    String fallback = '',
  }) {
    for (var index = 0; index + 1 < args.length; index += 1) {
      if (args[index] == name) {
        return args[index + 1];
      }
    }
    return fallback;
  }

  List<String> _windowsServiceRepeatedOptionValues(
    List<String> args,
    String name,
  ) {
    final values = <String>[];
    for (var index = 0; index + 1 < args.length; index += 1) {
      if (args[index] == name) {
        values.add(args[index + 1]);
        index += 1;
      }
    }
    return values;
  }

  String? _resolveWindowsServiceHelperPath() {
    if (!Platform.isWindows) {
      return null;
    }
    for (final root in _candidateRoots()) {
      final candidate = p.join(root, 'entropy_vpn_service.exe');
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  Map<String, String> _parseWindowsServiceFields(String output) {
    final fields = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final separator = line.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      fields[line.substring(0, separator)] = line.substring(separator + 1);
    }
    return fields;
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

({String response, String? transportError}) _trySendWindowsServicePipeRequest(
  String request, {
  required int timeoutMs,
}) {
  try {
    final response = _sendWindowsServicePipeRequest(
      request,
      timeoutMs: timeoutMs,
    );
    if (response.isEmpty) {
      return (
        response: '',
        transportError: 'EntropyVPN service pipe returned no response.',
      );
    }
    return (response: response, transportError: null);
  } catch (error) {
    return (response: '', transportError: error.toString());
  }
}

String _sendWindowsServicePipeRequest(
  String request, {
  required int timeoutMs,
}) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final waitNamedPipe = kernel32
      .lookupFunction<WaitNamedPipeWNative, WaitNamedPipeWDart>(
        'WaitNamedPipeW',
      );
  final createFile = kernel32
      .lookupFunction<CreateFileWNative, CreateFileWDart>('CreateFileW');
  final setNamedPipeHandleState = kernel32
      .lookupFunction<
        SetNamedPipeHandleStateNative,
        SetNamedPipeHandleStateDart
      >('SetNamedPipeHandleState');
  final writeFile = kernel32.lookupFunction<WriteFileNative, WriteFileDart>(
    'WriteFile',
  );
  final readFile = kernel32.lookupFunction<ReadFileNative, ReadFileDart>(
    'ReadFile',
  );
  final flushFileBuffers = kernel32
      .lookupFunction<FlushFileBuffersNative, FlushFileBuffersDart>(
        'FlushFileBuffers',
      );
  final closeHandle = kernel32
      .lookupFunction<CloseHandleNative, CloseHandleDart>('CloseHandle');
  final getLastError = kernel32
      .lookupFunction<GetLastErrorNative, GetLastErrorDart>('GetLastError');

  final pipeName = _nativeUtf16(_windowsTunServicePipePath);
  var pipe = windowsInvalidHandleValue;
  try {
    final waitMs = timeoutMs <= 0
        ? 1
        : timeoutMs > 3000
        ? 3000
        : timeoutMs;
    if (waitNamedPipe(pipeName, waitMs) == 0) {
      throw StateError(
        'EntropyVPN service pipe is not available: Windows error ${getLastError()}.',
      );
    }

    pipe = createFile(
      pipeName,
      windowsGenericRead | windowsGenericWrite,
      0,
      nullptr,
      windowsOpenExisting,
      windowsFileAttributeNormal,
      0,
    );
    if (pipe == windowsInvalidHandleValue) {
      throw StateError(
        'Could not open EntropyVPN service pipe: Windows error ${getLastError()}.',
      );
    }

    final mode = calloc<Uint32>();
    try {
      mode.value = windowsPipeReadmodeMessage;
      setNamedPipeHandleState(pipe, mode, nullptr, nullptr);
    } finally {
      calloc.free(mode);
    }

    final requestBytes = utf8.encode(request);
    final requestBuffer = calloc<Uint8>(requestBytes.length);
    final bytesWritten = calloc<Uint32>();
    try {
      requestBuffer.asTypedList(requestBytes.length).setAll(0, requestBytes);
      if (writeFile(
            pipe,
            requestBuffer.cast<Void>(),
            requestBytes.length,
            bytesWritten,
            nullptr,
          ) ==
          0) {
        throw StateError(
          'Could not write to EntropyVPN service pipe: Windows error ${getLastError()}.',
        );
      }
      if (bytesWritten.value != requestBytes.length) {
        throw StateError(
          'Could not write complete EntropyVPN service request: wrote ${bytesWritten.value} of ${requestBytes.length} bytes.',
        );
      }
      flushFileBuffers(pipe);
    } finally {
      calloc.free(bytesWritten);
      calloc.free(requestBuffer);
    }

    final responseBytes = <int>[];
    const bufferSize = 8192;
    final readBuffer = calloc<Uint8>(bufferSize);
    final bytesRead = calloc<Uint32>();
    try {
      while (true) {
        bytesRead.value = 0;
        final readOk = readFile(
          pipe,
          readBuffer.cast<Void>(),
          bufferSize,
          bytesRead,
          nullptr,
        );
        final count = bytesRead.value;
        if (readOk != 0 && count > 0) {
          responseBytes.addAll(readBuffer.asTypedList(count));
          break;
        }
        final readError = getLastError();
        if (readError == windowsErrorMoreData) {
          if (count > 0) {
            responseBytes.addAll(readBuffer.asTypedList(count));
          }
          continue;
        }
        break;
      }
    } finally {
      calloc.free(bytesRead);
      calloc.free(readBuffer);
    }

    return utf8.decode(responseBytes, allowMalformed: true);
  } finally {
    if (pipe != windowsInvalidHandleValue) {
      closeHandle(pipe);
    }
    calloc.free(pipeName);
  }
}

Pointer<Uint16> _nativeUtf16(String value) {
  final units = value.codeUnits;
  final pointer = calloc<Uint16>(units.length + 1);
  pointer.asTypedList(units.length + 1)
    ..setAll(0, units)
    ..[units.length] = 0;
  return pointer;
}
