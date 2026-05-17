part of 'core_runtime_service.dart';

extension CoreRuntimeServiceLifecycle on CoreRuntimeService {
  Future<void> _waitForPendingStopCleanup({required String reason}) async {
    final cleanup = _pendingStopCleanup;
    if (cleanup == null) {
      return;
    }

    _rememberAppLog('Waiting for previous stop cleanup $reason...');
    await cleanup;
  }

  Future<void> shutdown() async {
    final bridge = _androidBridge;
    if (bridge != null) {
      try {
        await bridge.dispose();
      } catch (_) {
        // Best-effort: the bridge may already be torn down.
      }
    }
    if (!Platform.isAndroid) {
      try {
        await stop(waitForCleanup: true);
      } finally {
        await _windowsNativeRuntimeEventsSubscription?.cancel();
        _windowsNativeRuntimeEventsSubscription = null;
      }
    }
  }

  void _disposeRuntime() {
    // Best-effort fallback for callers that can't await (e.g. Flutter's sync
    // dispose chain when shutdownForExit wasn't reached). Prefer shutdown().
    unawaited(shutdown());
  }

}
