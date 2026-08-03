import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';

void main() {
  group('LocalGatewayCredentials', () {
    late Directory tempHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('sanad-credentials-test-');
      setSanadHomeOverride(tempHome.path);
      setSanadStateHomeOverride(tempHome.path);
    });

    tearDown(() {
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    test('loadOrCreate generates and persists a token on first call', () async {
      final first = await LocalGatewayCredentials.loadOrCreate();
      expect(first.value, isNotEmpty);
      final canonical = SanadHomeBootstrap.resolveChild('.local_token');
      final file = File(canonical);
      expect(file.existsSync(), isTrue);
      if (!Platform.isWindows) {
        final mode = file.statSync().mode & 0x1ff;
        expect(mode, equals(0x180));
      }
    });

    test('loadOrCreate returns the same token on subsequent calls', () async {
      final first = await LocalGatewayCredentials.loadOrCreate();
      final second = await LocalGatewayCredentials.loadOrCreate();
      expect(first.value, equals(second.value));
    });

    test('concurrent first-start calls converge on one token', () async {
      final credentials = await Future.wait(
        List.generate(12, (_) => LocalGatewayCredentials.loadOrCreate()),
      );

      expect(credentials.map((credential) => credential.value).toSet(), hasLength(1));
      final lock = File(SanadHomeBootstrap.resolveChild('.local_token.lock'));
      expect(lock.existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(lock.statSync().mode & 0x1ff, 0x180);
      }
    });

    test('tryRead returns null when the token is missing', () {
      expect(LocalGatewayCredentials.tryRead(), isNull);
    });

    test('tryRead returns the persisted token', () async {
      final created = await LocalGatewayCredentials.loadOrCreate();
      final read = LocalGatewayCredentials.tryRead();
      expect(read, isNotNull);
      expect(read!.value, equals(created.value));
    });

    test('extractFromHeaders accepts the custom header', () async {
      final created = await LocalGatewayCredentials.loadOrCreate();
      final extracted = LocalGatewayCredentials.extractFromHeaders({
        LocalGatewayCredentials.headerName: created.value,
      }, created.value);
      expect(extracted, isNotNull);
      expect(extracted!.value, equals(created.value));
    });

    test('extractFromHeaders accepts Authorization: Bearer', () async {
      final created = await LocalGatewayCredentials.loadOrCreate();
      final extracted = LocalGatewayCredentials.extractFromHeaders({
        'Authorization': 'Bearer ${created.value}',
      }, created.value);
      expect(extracted, isNotNull);
    });

    test('extractFromHeaders rejects a wrong token', () async {
      final created = await LocalGatewayCredentials.loadOrCreate();
      final extracted = LocalGatewayCredentials.extractFromHeaders({
        LocalGatewayCredentials.headerName: 'wrong',
      }, created.value);
      expect(extracted, isNull);
    });

    test('toString does not leak the token value', () async {
      final created = await LocalGatewayCredentials.loadOrCreate();
      expect(created.toString(), isNot(contains(created.value)));
    });
  });
}
