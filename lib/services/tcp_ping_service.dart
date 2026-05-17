import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

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
  if (targets.isEmpty) {
    return const <TcpPingMeasurement>[];
  }

  final nativeTargets = targets
      .map(
        (target) => <String, Object?>{
          'profileIndex': target.profileIndex,
          'profileKey': target.profileKey,
          'host': target.profile.server.trim(),
          'port': target.profile.port,
        },
      )
      .toList(growable: false);
  final nativeResults = await Isolate.run(
    () => _NativeTcpPingBatch.instance.measure(
      nativeTargets,
      timeoutMs: timeout.inMilliseconds,
      maxConcurrent: maxConcurrent,
    ),
  );
  if (nativeResults.isEmpty) {
    throw const SocketException('TCP ping failed for all targets.');
  }
  return nativeResults;
}

typedef _NativeMeasureTcpPings =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> targetsJson,
      ffi.Int32 timeoutMs,
      ffi.Int32 maxConcurrent,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeMeasureTcpPingsDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> targetsJson,
      int timeoutMs,
      int maxConcurrent,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeFreeString = ffi.Void Function(ffi.Pointer<Utf8> value);
typedef _NativeFreeStringDart = void Function(ffi.Pointer<Utf8> value);

class _NativeTcpPingBatch {
  _NativeTcpPingBatch._(this._measureTcpPings, this._freeString);

  static final _NativeTcpPingBatch instance = _create();

  final _NativeMeasureTcpPingsDart _measureTcpPings;
  final _NativeFreeStringDart _freeString;

  static _NativeTcpPingBatch _create() {
    final library = _openLibrary();
    return _NativeTcpPingBatch._(
      library
          .lookupFunction<_NativeMeasureTcpPings, _NativeMeasureTcpPingsDart>(
            'entropy_measure_tcp_pings',
          ),
      library.lookupFunction<_NativeFreeString, _NativeFreeStringDart>(
        'entropy_free_string',
      ),
    );
  }

  static ffi.DynamicLibrary _openLibrary() {
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('entropy_vpn_native.dll');
    }
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('libentropy_vpn_native.so');
    }
    throw UnsupportedError('Native TCP ping is unavailable.');
  }

  List<TcpPingMeasurement> measure(
    List<Map<String, Object?>> targets, {
    required int timeoutMs,
    required int maxConcurrent,
  }) {
    final input = jsonEncode(targets).toNativeUtf8();
    final errorPointer = calloc<ffi.Pointer<Utf8>>();
    ffi.Pointer<Utf8> resultPointer = ffi.nullptr;
    try {
      resultPointer = _measureTcpPings(
        input,
        timeoutMs,
        maxConcurrent,
        errorPointer,
      );
      if (resultPointer == ffi.nullptr) {
        final messagePointer = errorPointer.value;
        final message = messagePointer == ffi.nullptr
            ? 'Native TCP ping failed.'
            : messagePointer.toDartString();
        if (messagePointer != ffi.nullptr) {
          _freeString(messagePointer);
        }
        throw StateError(message);
      }

      final decoded = jsonDecode(resultPointer.toDartString());
      if (decoded is! List) {
        throw const FormatException('Native TCP ping returned invalid JSON.');
      }
      final measurements =
          decoded
              .whereType<Map>()
              .map((item) {
                final profileIndex = (item['profileIndex'] as num?)?.toInt();
                final latencyMs = (item['latencyMs'] as num?)?.toInt();
                final profileKey = item['profileKey']?.toString();
                if (profileIndex == null ||
                    latencyMs == null ||
                    latencyMs <= 0 ||
                    profileKey == null) {
                  return null;
                }
                return TcpPingMeasurement(
                  profileIndex: profileIndex,
                  profileKey: profileKey,
                  latencyMs: latencyMs,
                );
              })
              .whereType<TcpPingMeasurement>()
              .toList(growable: false)
            ..sort(
              (left, right) => left.profileIndex.compareTo(right.profileIndex),
            );
      return measurements;
    } finally {
      calloc.free(input);
      calloc.free(errorPointer);
      if (resultPointer != ffi.nullptr) {
        _freeString(resultPointer);
      }
    }
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
