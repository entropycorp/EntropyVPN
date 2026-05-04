import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidIncomingLinkBridge {
  static const MethodChannel _methodChannel = MethodChannel(
    'entropy_vpn/incoming_links',
  );
  static const EventChannel _eventsChannel = EventChannel(
    'entropy_vpn/incoming_links/events',
  );

  Stream<String>? _links;

  Future<String?> getInitialLink() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final link = await _methodChannel.invokeMethod<String>('getInitialLink');
    return _normalize(link);
  }

  Stream<String> get links {
    if (!Platform.isAndroid) {
      return const Stream<String>.empty();
    }
    return _links ??= _eventsChannel
        .receiveBroadcastStream()
        .map((event) => _normalize(event?.toString()))
        .where((link) => link != null)
        .cast<String>();
  }

  String? _normalize(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }
}
