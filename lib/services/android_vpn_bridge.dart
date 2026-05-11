import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';

import '../models/split_tunnel.dart';
import '../models/vpn_profile.dart';

class AndroidVpnBridge {
  static const MethodChannel _controlChannel = MethodChannel(
    'entropy_vpn/control',
  );
  static const EventChannel _eventsChannel = EventChannel('entropy_vpn/events');
  static const int _maxRecentLogs = 400;

  final Queue<String> _recentLogs = Queue<String>();

  StreamSubscription<dynamic>? _eventsSubscription;
  bool _isRunning = false;
  bool _stopRequested = false;
  String _phase = 'disconnected';
  DateTime? _connectedAt;

  void Function(String? error)? onProcessExit;
  void Function()? onLogUpdated;

  bool get isRunning => _isRunning;
  String get phase => _phase;
  DateTime? get connectedAt => _connectedAt;
  String? get lastLogLine => _recentLogs.isEmpty ? null : _recentLogs.last;
  List<String> get recentLogs => List<String>.unmodifiable(_recentLogs);

  Future<void> refreshState() => _ensureEventStream();

  Future<void> start({
    required String core,
    required String configJson,
    required String profileName,
    required String serverAddress,
    required String? serverCountryCode,
    required AppLanguage language,
    required TunIpMode tunIpMode,
    required List<String> dnsServers,
    required SplitTunnelSettings splitTunnelSettings,
  }) async {
    await _ensureEventStream();
    if (_isRunning && _phase == 'connected') {
      _stopRequested = false;
      return;
    }

    _stopRequested = false;
    _recentLogs.clear();
    onLogUpdated?.call();

    final granted = await _controlChannel.invokeMethod<bool>('prepareVpn');
    if (granted != true) {
      throw StateError('VPN permission was denied on Android.');
    }

    final accepted = await _controlChannel.invokeMethod<bool>(
      'startVpn',
      _buildStartPayloadArguments(
        core: core,
        configJson: configJson,
        profileName: profileName,
        serverAddress: serverAddress,
        serverCountryCode: serverCountryCode,
        language: language,
        tunIpMode: tunIpMode,
        dnsServers: dnsServers,
        splitTunnelSettings: splitTunnelSettings,
      ),
    );
    if (accepted != true) {
      throw StateError('Android VPN service rejected the start request.');
    }
  }

  Future<void> saveStartPayload({
    required String core,
    required String configJson,
    required String profileName,
    required String serverAddress,
    required String? serverCountryCode,
    required AppLanguage language,
    required TunIpMode tunIpMode,
    required List<String> dnsServers,
    required SplitTunnelSettings splitTunnelSettings,
  }) async {
    await _controlChannel.invokeMethod<bool>(
      'saveVpnStartPayload',
      _buildStartPayloadArguments(
        core: core,
        configJson: configJson,
        profileName: profileName,
        serverAddress: serverAddress,
        serverCountryCode: serverCountryCode,
        language: language,
        tunIpMode: tunIpMode,
        dnsServers: dnsServers,
        splitTunnelSettings: splitTunnelSettings,
      ),
    );
  }

  Future<void> stop() async {
    await _ensureEventStream();
    _stopRequested = true;
    await _controlChannel.invokeMethod<void>('stopVpn');
  }

  Future<void> dispose() async {
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
  }

  Future<void> _ensureEventStream() async {
    _eventsSubscription ??= _eventsChannel.receiveBroadcastStream().listen(
      _handleEvent,
      onError: (Object error) {
        if (_stopRequested) {
          return;
        }
        onProcessExit?.call(error.toString());
      },
    );

    final snapshot = await _controlChannel.invokeMapMethod<String, dynamic>(
      'getState',
    );
    if (snapshot != null) {
      _applySnapshot(snapshot);
    }
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    _applySnapshot(event.map((key, value) => MapEntry(key.toString(), value)));
  }

  void _applySnapshot(Map<String, dynamic> snapshot) {
    final previousPhase = _phase;

    _isRunning = snapshot['running'] == true;
    _phase = snapshot['phase']?.toString() ?? 'disconnected';
    _connectedAt = _parseEpochMillis(snapshot['connectedAtEpochMillis']);

    final nextLogs = ((snapshot['logs'] as List<dynamic>?) ?? const <dynamic>[])
        .map((item) => item.toString())
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);

    _recentLogs
      ..clear()
      ..addAll(nextLogs);
    while (_recentLogs.length > _maxRecentLogs) {
      _recentLogs.removeFirst();
    }

    final error = snapshot['error']?.toString();
    final hasError = error != null && error.trim().isNotEmpty;
    if (!_stopRequested) {
      if (previousPhase != 'error' && _phase == 'error') {
        onProcessExit?.call(hasError ? error : null);
      }
    }

    onLogUpdated?.call();
  }

  DateTime? _parseEpochMillis(Object? value) {
    final millis = switch (value) {
      final num number => number.toInt(),
      final String text => int.tryParse(text),
      _ => null,
    };
    if (millis == null || millis <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Map<String, Object?> _buildStartPayloadArguments({
    required String core,
    required String configJson,
    required String profileName,
    required String serverAddress,
    required String? serverCountryCode,
    required AppLanguage language,
    required TunIpMode tunIpMode,
    required List<String> dnsServers,
    required SplitTunnelSettings splitTunnelSettings,
  }) {
    final normalizedSplitTunnel = splitTunnelSettings.normalized;
    return <String, Object?>{
      'core': core,
      'config': configJson,
      'profileName': profileName,
      'serverAddress': serverAddress,
      'serverCountryCode': serverCountryCode,
      'language': language.name,
      'tunIpMode': tunIpMode.name,
      'dnsServers': dnsServers,
      'splitTunnelMode': normalizedSplitTunnel.mode.name,
      'splitTunnelPackages': normalizedSplitTunnel.apps
          .map((app) => app.path.trim())
          .where((packageName) => packageName.isNotEmpty)
          .toList(growable: false),
    };
  }
}
