part of 'core_runtime_service.dart';

class WindowsTunPrivilegeDeniedException implements Exception {
  const WindowsTunPrivilegeDeniedException();

  @override
  String toString() =>
      'Administrator privileges are required for Windows TUN mode.';
}

extension CoreRuntimeServiceWindows on CoreRuntimeService {
  Future<void> _ensureWindowsTunPrerequisites(String binaryPath) async {
    if (!Platform.isWindows) {
      return;
    }

    final wintunPath = p.join(p.dirname(binaryPath), 'wintun.dll');
    if (!File(wintunPath).existsSync()) {
      final executableName = p.basename(binaryPath);
      throw StateError(
        'wintun.dll was not found next to $executableName. Windows TUN mode requires wintun.dll in ${p.dirname(binaryPath)}.',
      );
    }

    if (!await ensureWindowsTunPrivileges()) {
      throw const WindowsTunPrivilegeDeniedException();
    }
  }

  Future<bool> ensureWindowsTunPrivileges() async {
    if (!Platform.isWindows) {
      return true;
    }

    final elevated = await _isRunningAsAdministrator();
    if (elevated == false) {
      _rememberAppLog(
        'Windows TUN mode requires Administrator privileges; relaunching EntropyVPN elevated...',
      );
      final relaunched = await _relaunchAsAdministrator();
      if (relaunched) {
        _rememberAppLog(
          'Elevated instance was launched. Exiting unelevated instance.',
        );
        exit(0);
      }
      return false;
    }

    if (elevated == null) {
      _rememberAppLog(
        'Could not determine whether EntropyVPN is elevated; continuing and letting the core report any permission error.',
      );
    }

    return true;
  }

  String _buildWindowsTunInterfaceName() {
    return 'EntropyVPN TUN';
  }
}
