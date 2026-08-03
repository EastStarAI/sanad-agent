import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/core/sanad_home/loopback_policy.dart';

void main() {
  group('LoopbackPolicy.isLoopbackHost', () {
    test('accepts literal loopback names', () {
      expect(LoopbackPolicy.isLoopbackHost('127.0.0.1'), isTrue);
      expect(LoopbackPolicy.isLoopbackHost('127.0.0.2'), isTrue);
      expect(LoopbackPolicy.isLoopbackHost('::1'), isTrue);
      expect(LoopbackPolicy.isLoopbackHost('localhost'), isTrue);
    });

    test('rejects wildcard bind addresses', () {
      expect(LoopbackPolicy.isLoopbackHost('0.0.0.0'), isFalse);
      expect(LoopbackPolicy.isLoopbackHost('::'), isFalse);
    });

    test('rejects private and public hosts', () {
      expect(LoopbackPolicy.isLoopbackHost('192.168.1.1'), isFalse);
      expect(LoopbackPolicy.isLoopbackHost('10.0.0.1'), isFalse);
      expect(LoopbackPolicy.isLoopbackHost('8.8.8.8'), isFalse);
      expect(LoopbackPolicy.isLoopbackHost('example.com'), isFalse);
    });

    test('rejects empty or whitespace', () {
      expect(LoopbackPolicy.isLoopbackHost(''), isFalse);
      expect(LoopbackPolicy.isLoopbackHost('   '), isFalse);
    });
  });

  group('LoopbackPolicy.isLoopbackAddress', () {
    test('accepts a real loopback InternetAddress', () {
      final address = InternetAddress('127.0.0.1');
      expect(LoopbackPolicy.isLoopbackAddress(address), isTrue);
    });

    test('rejects null and non-loopback addresses', () {
      expect(LoopbackPolicy.isLoopbackAddress(null), isFalse);
      expect(
        LoopbackPolicy.isLoopbackAddress(InternetAddress('10.0.0.1')),
        isFalse,
      );
    });
  });

  group('LoopbackPolicy.assertLoopbackBind', () {
    test('passes for loopback', () {
      expect(
        () => LoopbackPolicy.assertLoopbackBind('127.0.0.1'),
        returnsNormally,
      );
    });

    test('throws for non-loopback', () {
      expect(
        () => LoopbackPolicy.assertLoopbackBind('0.0.0.0'),
        throwsA(isA<LocalGatewayBindViolation>()),
      );
    });
  });
}
