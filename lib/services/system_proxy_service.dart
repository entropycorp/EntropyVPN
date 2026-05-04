import 'dart:convert';
import 'dart:io';

class SystemProxySnapshot {
  const SystemProxySnapshot({
    required this.enabled,
    required this.server,
    required this.override,
  });

  final bool enabled;
  final String? server;
  final String? override;
}

class SystemProxyService {
  static const String _registryPath =
      r"HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings";

  Future<SystemProxySnapshot> capture() async {
    final script =
        '''
\$settings = Get-ItemProperty -Path '$_registryPath'
[PSCustomObject]@{
  ProxyEnable = [int](\$settings.ProxyEnable)
  ProxyServer = [string](\$settings.ProxyServer)
  ProxyOverride = [string](\$settings.ProxyOverride)
} | ConvertTo-Json -Compress
''';

    final result = await _runPowerShell(script);
    final json = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    return SystemProxySnapshot(
      enabled: (json['ProxyEnable'] as num?)?.toInt() == 1,
      server: _emptyToNull(json['ProxyServer']?.toString()),
      override: _emptyToNull(json['ProxyOverride']?.toString()),
    );
  }

  Future<void> enableHttpProxy({
    required int port,
    String host = '127.0.0.1',
  }) async {
    final script =
        '''
Set-ItemProperty -Path '$_registryPath' -Name ProxyEnable -Value 1
Set-ItemProperty -Path '$_registryPath' -Name ProxyServer -Value '$host:$port'
Set-ItemProperty -Path '$_registryPath' -Name ProxyOverride -Value '<local>'
${_refreshScript()}
''';
    await _runPowerShell(script);
  }

  Future<void> restore(SystemProxySnapshot snapshot) async {
    final serverLine = snapshot.server == null
        ? "Remove-ItemProperty -Path '$_registryPath' -Name ProxyServer -ErrorAction SilentlyContinue"
        : "Set-ItemProperty -Path '$_registryPath' -Name ProxyServer -Value '${snapshot.server}'";
    final overrideLine = snapshot.override == null
        ? "Remove-ItemProperty -Path '$_registryPath' -Name ProxyOverride -ErrorAction SilentlyContinue"
        : "Set-ItemProperty -Path '$_registryPath' -Name ProxyOverride -Value '${snapshot.override}'";

    final script =
        '''
Set-ItemProperty -Path '$_registryPath' -Name ProxyEnable -Value ${snapshot.enabled ? 1 : 0}
$serverLine
$overrideLine
${_refreshScript()}
''';
    await _runPowerShell(script);
  }

  Future<ProcessResult> _runPowerShell(String script) {
    return Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]).then((result) {
      if (result.exitCode != 0) {
        final error = result.stderr.toString().trim();
        throw StateError(error.isEmpty ? 'PowerShell command failed.' : error);
      }
      return result;
    });
  }

  String _refreshScript() {
    return '''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinInetProxy {
  [DllImport("wininet.dll", SetLastError = true)]
  public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@
[WinInetProxy]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WinInetProxy]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
''';
  }

  String? _emptyToNull(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
