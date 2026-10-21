import 'dart:io';

import 'package:test/test.dart';

import 'ephemeral_loopback_port.dart';

void main() {
  test('a reservation stolen before bind is retried on a fresh port', () async {
    final stolenPort = await reserveFreeLoopbackPort();
    final thief = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      stolenPort,
    );
    addTearDown(thief.close);

    final reserved = <int>[];
    final server = await bindOnReservedLoopbackPort((port) async {
      reserved.add(port);
      return ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    }, reserve: () async {
      if (reserved.isNotEmpty) return reserveFreeLoopbackPort();
      return stolenPort;
    });
    addTearDown(server.close);

    expect(reserved, hasLength(2));
    expect(reserved.first, stolenPort);
    expect(server.port, reserved.last);
    expect(server.port, isNot(stolenPort));
  });

  test('an unresolvable collision fails only after the attempt budget', () async {
    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(blocker.close);
    var attempts = 0;

    await expectLater(
      bindOnReservedLoopbackPort(
        (port) => ServerSocket.bind(InternetAddress.loopbackIPv4, port),
        reserve: () async {
          attempts += 1;
          return blocker.port;
        },
        maxAttempts: 3,
      ),
      throwsA(isA<SocketException>()),
    );
    expect(attempts, 3);
  });

  test('overlapping bind/release cycles always keep the port exclusive', () async {
    ServerSocket? previous;
    addTearDown(() async => previous?.close());
    final ports = <int>[];

    for (var cycle = 0; cycle < 12; cycle++) {
      final current = await bindOnReservedLoopbackPort(
        (port) => ServerSocket.bind(InternetAddress.loopbackIPv4, port),
      );
      ports.add(current.port);
      final released = previous;
      previous = current;
      await released?.close();
    }

    expect(ports.toSet(), hasLength(ports.length));
  });

  test('simultaneous reservations never hand the same port out twice', () async {
    final servers = await Future.wait(
      List.generate(
        8,
        (_) => bindOnReservedLoopbackPort(
          (port) => ServerSocket.bind(InternetAddress.loopbackIPv4, port),
        ),
      ),
    );
    addTearDown(() async {
      for (final server in servers) {
        await server.close();
      }
    });

    final ports = servers.map((server) => server.port).toList();
    expect(ports.toSet(), hasLength(ports.length));
  });
}
