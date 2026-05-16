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

  void _disposeRuntime() {
    unawaited(_androidBridge?.dispose() ?? Future<void>.value());
    if (!Platform.isAndroid) {
      unawaited(
        stop().whenComplete(() async {
          await _windowsNativeRuntimeEventsSubscription?.cancel();
          _windowsNativeRuntimeEventsSubscription = null;
        }),
      );
    }
  }

}
