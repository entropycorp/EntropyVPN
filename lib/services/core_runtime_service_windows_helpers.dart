import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/vpn_profile.dart';
import 'core_runtime_service_windows_types.dart';

bool windowsAddressMatchesTunIpMode(
  InternetAddress address,
  TunIpMode tunIpMode,
) {
  return switch (tunIpMode) {
    TunIpMode.ipv4 => address.type == InternetAddressType.IPv4,
    TunIpMode.ipv6 => address.type == InternetAddressType.IPv6,
    TunIpMode.dualStack => true,
  };
}

String windowsHostRouteKey(WindowsHostRoute route) {
  return windowsRouteRemovalKey(
    destinationPrefix: route.destinationPrefix,
    interfaceIndex: route.interfaceIndex,
    nextHop: route.nextHop,
  );
}

String windowsPathKey(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  return p.normalize(trimmed).toLowerCase();
}

String windowsRouteRemovalKey({
  required String destinationPrefix,
  required int interfaceIndex,
  required String nextHop,
}) {
  return '$destinationPrefix\n$interfaceIndex\n$nextHop';
}
