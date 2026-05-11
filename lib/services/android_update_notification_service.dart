import 'dart:io';

import 'package:flutter/services.dart';

import 'app_update_service.dart';

class AndroidUpdateNotificationService {
  static const MethodChannel _controlChannel = MethodChannel(
    'entropy_vpn/control',
  );

  Future<bool> showUpdateNotification(AppUpdateInfo update) async {
    if (!Platform.isAndroid) {
      return false;
    }

    try {
      return await _controlChannel
              .invokeMethod<bool>('showUpdateNotification', <String, Object?>{
                'title': 'New update',
                'body': 'EntropyVPN ${update.versionLabel} is available',
                'releaseUrl': update.releaseUrl.toString(),
              }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
