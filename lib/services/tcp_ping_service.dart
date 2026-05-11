import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../models/config_source.dart';
import '../models/vpn_profile.dart';

const Duration tcpPingTimeout = Duration(seconds: 5);
const int tcpPingMaxConcurrent = 8;

class TcpPingTarget {
  const TcpPingTarget({
    required this.profileIndex,
    required this.profileKey,
    required this.profile,
  });

  final int profileIndex;
  final String profileKey;
  final ParsedVpnProfile profile;
}

class TcpPingMeasurement {
  const TcpPingMeasurement({
    required this.profileIndex,
    required this.profileKey,
    required this.latencyMs,
  });

  final int profileIndex;
  final String profileKey;
  final int latencyMs;
}

bool hasTcpPingEndpoint(ParsedVpnProfile? profile) {
  final host = profile?.server.trim();
  final port = profile?.port ?? 0;
  return host != null && host.isNotEmpty && port > 0 && port <= 65535;
}

List<TcpPingTarget> tcpPingTargetsForSource(ConfigSource source) {
  if (source.isSubscription) {
    return <TcpPingTarget>[
      for (var i = 0; i < source.profiles.length; i += 1)
        if (hasTcpPingEndpoint(source.profiles[i]))
          TcpPingTarget(
            profileIndex: i,
            profileKey: vpnProfileIdentityKey(source.profiles[i]),
            profile: source.profiles[i],
          ),
    ];
  }

  final profile = source.selectedProfile;
  if (!hasTcpPingEndpoint(profile)) {
    return const <TcpPingTarget>[];
  }

  return <TcpPingTarget>[
    TcpPingTarget(
      profileIndex: source.selectedProfileIndex,
      profileKey: vpnProfileIdentityKey(profile!),
      profile: profile,
    ),
  ];
}

Future<List<TcpPingMeasurement>> measureTcpPingTargets(
  List<TcpPingTarget> targets, {
  int maxConcurrent = tcpPingMaxConcurrent,
  Duration timeout = tcpPingTimeout,
}) async {
  final measurements = <TcpPingMeasurement>[];
  final errors = <Object>[];
  var nextTarget = 0;

  Future<void> runWorker() async {
    while (true) {
      final targetIndex = nextTarget;
      nextTarget += 1;
      if (targetIndex >= targets.length) {
        return;
      }

      final target = targets[targetIndex];
      try {
        final latencyMs = await measureTcpPing(
          target.profile,
          timeout: timeout,
        );
        measurements.add(
          TcpPingMeasurement(
            profileIndex: target.profileIndex,
            profileKey: target.profileKey,
            latencyMs: latencyMs,
          ),
        );
      } catch (error) {
        errors.add(error);
      }
    }
  }

  final workerCount = math.min(maxConcurrent, targets.length);
  await Future.wait(<Future<void>>[
    for (var i = 0; i < workerCount; i += 1) runWorker(),
  ]);

  if (measurements.isEmpty && errors.isNotEmpty) {
    Error.throwWithStackTrace(errors.first, StackTrace.current);
  }

  measurements.sort(
    (left, right) => left.profileIndex.compareTo(right.profileIndex),
  );
  return measurements;
}

Future<int> measureTcpPing(
  ParsedVpnProfile profile, {
  Duration timeout = tcpPingTimeout,
}) async {
  final host = profile.server.trim();
  final port = profile.port;
  final stopwatch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: timeout);
    stopwatch.stop();
    final elapsedMs = stopwatch.elapsedMilliseconds;
    return elapsedMs <= 0 ? 1 : elapsedMs;
  } finally {
    socket?.destroy();
  }
}

String vpnProfileIdentityKey(ParsedVpnProfile profile) {
  return <Object?>[
    profile.isSingBoxConfig,
    profile.singBoxConfigJson,
    profile.isXrayConfig,
    profile.xrayConfigJson,
    profile.protocol.name,
    profile.server,
    profile.port,
    profile.remark,
    profile.userId,
    profile.password,
    profile.method,
    profile.path,
    profile.serviceName,
  ].join('|');
}
