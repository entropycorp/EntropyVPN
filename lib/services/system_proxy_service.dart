import 'package:flutter/services.dart';

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
  static const MethodChannel _windowsTunChannel = MethodChannel(
    'entropy_vpn/windows_tun',
  );

  Future<SystemProxySnapshot> capture() async {
    final json = await _invokeWindowsProxyMethod('captureSystemProxy');
    return SystemProxySnapshot(
      enabled: json['enabled'] == true,
      server: _emptyToNull(json['server']?.toString()),
      override: _emptyToNull(json['override']?.toString()),
    );
  }

  Future<void> enableHttpProxy({
    required int port,
    String host = '127.0.0.1',
  }) async {
    await _invokeWindowsProxyMethod('setSystemProxy', <String, Object?>{
      'enabled': true,
      'server': '$host:$port',
      'override': '<local>',
    });
  }

  Future<void> restore(SystemProxySnapshot snapshot) async {
    await _invokeWindowsProxyMethod('setSystemProxy', <String, Object?>{
      'enabled': snapshot.enabled,
      'server': snapshot.server,
      'override': snapshot.override,
    });
  }

  Future<Map<Object?, Object?>> _invokeWindowsProxyMethod(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final rawResult = await _windowsTunChannel.invokeMethod<Object?>(
      method,
      arguments,
    );
    if (rawResult is! Map) {
      throw StateError('Native system proxy call returned an invalid result.');
    }
    final result = rawResult.cast<Object?, Object?>();
    if (result['ok'] != true) {
      final failedStep = result['failedStep']?.toString() ?? 'unknown';
      final error = result['error']?.toString() ?? 'unknown error';
      throw StateError('$failedStep failed: $error');
    }
    return result;
  }

  String? _emptyToNull(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
