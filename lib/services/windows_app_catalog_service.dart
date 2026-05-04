import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/split_tunnel.dart';

class WindowsAppCatalogService {
  static const MethodChannel _androidControlChannel = MethodChannel(
    'entropy_vpn/control',
  );

  List<SplitTunnelApp>? _cachedApplications;
  Future<List<SplitTunnelApp>>? _loadingApplications;

  Future<List<SplitTunnelApp>> loadApplications({bool refresh = false}) {
    final cachedApplications = _cachedApplications;
    if (!refresh && cachedApplications != null) {
      return Future<List<SplitTunnelApp>>.value(cachedApplications);
    }

    final loadingApplications = _loadingApplications;
    if (loadingApplications != null) {
      return loadingApplications;
    }

    final future = _loadApplications()
        .then((applications) {
          final cached = List<SplitTunnelApp>.unmodifiable(applications);
          _cachedApplications = cached;
          return cached;
        })
        .whenComplete(() {
          _loadingApplications = null;
        });
    _loadingApplications = future;
    return future;
  }

  Future<List<SplitTunnelApp>> _loadApplications() async {
    if (Platform.isAndroid) {
      return _loadAndroidApplications();
    }

    if (!Platform.isWindows) {
      return const <SplitTunnelApp>[];
    }

    final result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      _catalogScript,
    ]);

    if (result.exitCode != 0) {
      return const <SplitTunnelApp>[];
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return const <SplitTunnelApp>[];
    }

    try {
      return _decodeApplications(jsonDecode(output));
    } catch (_) {
      return const <SplitTunnelApp>[];
    }
  }

  Future<List<SplitTunnelApp>> _loadAndroidApplications() async {
    try {
      final rawItems = await _androidControlChannel.invokeListMethod<dynamic>(
        'listInstalledApps',
      );
      return _decodeApplications(rawItems ?? const <dynamic>[]);
    } catch (_) {
      return const <SplitTunnelApp>[];
    }
  }

  List<SplitTunnelApp> _decodeApplications(dynamic decoded) {
    final rawItems = decoded is List
        ? decoded
        : decoded is Map
        ? <dynamic>[decoded]
        : const <dynamic>[];
    final apps = <SplitTunnelApp>[];
    final seen = <String>{};

    for (final item in rawItems) {
      if (item is! Map) {
        continue;
      }
      final name = item['name']?.toString() ?? '';
      final path = item['path']?.toString() ?? '';
      final app = SplitTunnelApp.fromPath(name: name, path: path);
      if (app.path.isEmpty || !seen.add(app.id)) {
        continue;
      }
      apps.add(app);
    }

    apps.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return apps;
  }
}

const _catalogScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$items = New-Object System.Collections.Generic.List[object]

function Add-AppItem([string]$Name, [string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }
  $trimmedPath = $Path.Trim()
  if (-not $trimmedPath.ToLowerInvariant().EndsWith('.exe')) {
    return
  }
  if (-not (Test-Path -LiteralPath $trimmedPath -PathType Leaf)) {
    return
  }
  $trimmedName = $Name.Trim()
  if ([string]::IsNullOrWhiteSpace($trimmedName)) {
    $trimmedName = [System.IO.Path]::GetFileNameWithoutExtension($trimmedPath)
  }
  $items.Add([PSCustomObject]@{
    name = $trimmedName
    path = $trimmedPath
  })
}

$roots = @(
  [Environment]::GetFolderPath('StartMenu'),
  [Environment]::GetFolderPath('CommonStartMenu'),
  [Environment]::GetFolderPath('Desktop'),
  [Environment]::GetFolderPath('CommonDesktopDirectory')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }

$shell = New-Object -ComObject WScript.Shell
foreach ($root in $roots) {
  Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -File | ForEach-Object {
    $shortcut = $shell.CreateShortcut($_.FullName)
    Add-AppItem -Name ([System.IO.Path]::GetFileNameWithoutExtension($_.Name)) -Path ([string]$shortcut.TargetPath)
  }
}

Get-Process | Where-Object { $_.Path } | ForEach-Object {
  Add-AppItem -Name $_.ProcessName -Path $_.Path
}

$items |
  Group-Object { $_.path.ToLowerInvariant() } |
  ForEach-Object { $_.Group[0] } |
  Sort-Object name, path |
  ConvertTo-Json -Depth 3 -Compress
''';
