import 'dart:io';

import 'package:entropy_vpn/models/vpn_profile.dart';
import 'package:entropy_vpn/services/tcp_ping_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('measures reachable TCP ping targets in profile order', () async {
    final firstServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final secondServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final firstSubscription = firstServer.listen((socket) {
      socket.destroy();
    });
    final secondSubscription = secondServer.listen((socket) {
      socket.destroy();
    });
    addTearDown(() async {
      await firstSubscription.cancel();
      await secondSubscription.cancel();
      await firstServer.close();
      await secondServer.close();
    });

    final measurements = await measureTcpPingTargets(<TcpPingTarget>[
      TcpPingTarget(
        profileIndex: 0,
        profileKey: 'first',
        profile: _tcpProfile(firstServer.port),
      ),
      TcpPingTarget(
        profileIndex: 1,
        profileKey: 'second',
        profile: _tcpProfile(secondServer.port),
      ),
    ], timeout: const Duration(seconds: 2));

    expect(measurements.map((measurement) => measurement.profileIndex), <int>[
      0,
      1,
    ]);
    expect(measurements.map((measurement) => measurement.profileKey), <String>[
      'first',
      'second',
    ]);
    for (final measurement in measurements) {
      expect(measurement.latencyMs, greaterThan(0));
    }
  });

  test('TCP ping uses native FFI on every supported platform', () async {
    final source = await File(
      'lib/services/tcp_ping_service.dart',
    ).readAsString();

    expect(source, contains('entropy_measure_tcp_pings'));
    expect(source, contains('Isolate.run'));
    expect(source, contains('entropy_vpn_native.dll'));
    expect(source, contains('libentropy_vpn_native.so'));
    expect(source, isNot(contains('Socket.connect')));
  });
}

ParsedVpnProfile _tcpProfile(int port) {
  return ParsedVpnProfile(
    protocol: LinkProtocol.vless,
    server: InternetAddress.loopbackIPv4.address,
    port: port,
    transport: TransportMode.raw,
    tlsMode: TlsMode.tls,
    userId: '11111111-1111-1111-1111-111111111111',
  );
}
