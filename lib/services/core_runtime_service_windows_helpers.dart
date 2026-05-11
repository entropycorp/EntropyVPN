import 'dart:convert';
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

Ipv4DefaultRoute? parseWindowsDefaultIpv4Route(String routePrintOutput) {
  final candidates = <Ipv4DefaultRoute>[];
  final linePattern = RegExp(
    r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\S+)\s+(\S+)\s+(\d+)\s*$',
    caseSensitive: false,
  );
  for (final line in const LineSplitter().convert(routePrintOutput)) {
    final match = linePattern.firstMatch(line);
    if (match == null) {
      continue;
    }
    final gateway = match.group(1) ?? '';
    final interfaceAddress = match.group(2) ?? '';
    final metric = int.tryParse(match.group(3) ?? '');
    if (gateway.toLowerCase() == 'on-link' ||
        InternetAddress.tryParse(gateway)?.type != InternetAddressType.IPv4 ||
        InternetAddress.tryParse(interfaceAddress)?.type !=
            InternetAddressType.IPv4 ||
        metric == null) {
      continue;
    }
    candidates.add(
      Ipv4DefaultRoute(
        gateway: gateway,
        interfaceAddress: interfaceAddress,
        metric: metric,
      ),
    );
  }
  if (candidates.isEmpty) {
    return null;
  }
  candidates.sort((left, right) => left.metric.compareTo(right.metric));
  return candidates.first;
}

String? parseNetshInterfaceAliasForAddress(
  String netshOutput,
  String interfaceAddress,
) {
  String? currentAlias;
  final interfacePattern = RegExp(r'interface\s+"([^"]+)"');
  for (final line in const LineSplitter().convert(netshOutput)) {
    final interfaceMatch = interfacePattern.firstMatch(line);
    if (interfaceMatch != null) {
      currentAlias = interfaceMatch.group(1)?.trim();
      continue;
    }
    if (currentAlias != null && line.contains(interfaceAddress)) {
      return currentAlias;
    }
  }
  return null;
}

bool looksVirtualInterfaceAlias(String interfaceAlias) {
  final alias = interfaceAlias.toLowerCase();
  return alias.contains('vpn') ||
      alias.contains('tun') ||
      alias.contains('tap') ||
      alias.contains('wintun') ||
      alias.contains('wireguard') ||
      alias.contains('loopback') ||
      alias.contains('virtual');
}

bool routePrintHasIpv4HostRoute(
  String routePrintOutput,
  String address, {
  required String nextHop,
}) {
  final escapedAddress = RegExp.escape(address);
  final escapedNextHop = RegExp.escape(nextHop);
  final linePattern = RegExp(
    r'^\s*' +
        escapedAddress +
        r'\s+255\.255\.255\.255\s+' +
        escapedNextHop +
        r'\s+\S+\s+\d+\s*$',
    caseSensitive: false,
  );
  return const LineSplitter()
      .convert(routePrintOutput)
      .any(linePattern.hasMatch);
}

bool routeOutputSaysAlreadyExists(Object stdout, Object stderr) {
  final output = '${stdout.toString()}\n${stderr.toString()}'.toLowerCase();
  return output.contains('already exists') ||
      output.contains('object already exists');
}

String serverBypassPrefixesJson(List<InternetAddress> addresses) {
  return jsonEncode(
    addresses
        .map(
          (address) => <String, dynamic>{
            'destinationPrefix': address.type == InternetAddressType.IPv6
                ? '${address.address}/128'
                : '${address.address}/32',
          },
        )
        .toList(growable: false),
  );
}

WindowsRouteInfo? decodeWindowsRouteInfo(dynamic decoded) {
  if (decoded is! Map) {
    return null;
  }
  final json = decoded.cast<String, dynamic>();
  final alias = json['InterfaceAlias']?.toString().trim();
  if (alias == null || alias.isEmpty) {
    return null;
  }
  return WindowsRouteInfo(
    interfaceAlias: alias,
    interfaceIndex: (json['InterfaceIndex'] as num?)?.toInt(),
    sourceAddress: json['SourceAddress']?.toString().trim(),
    nextHop: json['NextHop']?.toString().trim(),
    hardwareInterface: json['HardwareInterface'] as bool?,
    virtual: json['Virtual'] as bool?,
  );
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

NetshIpv4Interface? parseNetshIpv4Interface(
  String netshOutput,
  String interfaceAlias,
) {
  final target = interfaceAlias.trim().toLowerCase();
  final linePattern = RegExp(
    r'^\s*(\d+)\s+\d+\s+\d+\s+(\S+)\s+(.+?)\s*$',
    caseSensitive: false,
  );
  for (final line in const LineSplitter().convert(netshOutput)) {
    final match = linePattern.firstMatch(line);
    if (match == null) {
      continue;
    }
    final name = match.group(3)?.trim();
    if (name == null || name.toLowerCase() != target) {
      continue;
    }
    final index = int.tryParse(match.group(1) ?? '');
    if (index == null || index <= 0) {
      continue;
    }
    return NetshIpv4Interface(
      index: index,
      name: name,
      status: match.group(2)?.trim() ?? '',
    );
  }
  return null;
}

bool canRemoveWithNativeIpv4RouteApi({
  required String destinationPrefix,
  required int interfaceIndex,
  required String nextHop,
}) {
  if (!Platform.isWindows || interfaceIndex <= 0) {
    return false;
  }

  final parts = destinationPrefix.split('/');
  if (parts.length != 2) {
    return false;
  }
  final destination = InternetAddress.tryParse(parts[0]);
  final prefixLength = int.tryParse(parts[1]);
  final gateway = InternetAddress.tryParse(nextHop);
  return destination?.type == InternetAddressType.IPv4 &&
      prefixLength != null &&
      prefixLength >= 0 &&
      prefixLength <= 32 &&
      gateway?.type == InternetAddressType.IPv4;
}

String windowsRouteRemovalKey({
  required String destinationPrefix,
  required int interfaceIndex,
  required String nextHop,
}) {
  return '$destinationPrefix\n$interfaceIndex\n$nextHop';
}

RouteExeIpv4Destination? routeExeIpv4DestinationParts(
  String destinationPrefix,
) {
  final parts = destinationPrefix.split('/');
  if (parts.length != 2) {
    return null;
  }
  final address = InternetAddress.tryParse(parts[0]);
  if (address == null || address.type != InternetAddressType.IPv4) {
    return null;
  }
  final mask = switch (parts[1]) {
    '1' => '128.0.0.0',
    '32' => '255.255.255.255',
    _ => null,
  };
  if (mask == null) {
    return null;
  }
  return RouteExeIpv4Destination(address: address.address, mask: mask);
}

String windowsTunRoutesJson(List<WindowsTunRoute> routes) {
  return jsonEncode(
    routes
        .map(
          (route) => <String, dynamic>{
            'destinationPrefix': route.destinationPrefix,
            'interfaceIndex': route.interfaceIndex,
            'nextHop': route.nextHop,
          },
        )
        .toList(growable: false),
  );
}

String windowsHostRoutesJson(List<WindowsHostRoute> routes) {
  return jsonEncode(
    routes
        .map(
          (route) => <String, dynamic>{
            'destinationPrefix': route.destinationPrefix,
            'interfaceIndex': route.interfaceIndex,
            'nextHop': route.nextHop,
          },
        )
        .toList(growable: false),
  );
}
