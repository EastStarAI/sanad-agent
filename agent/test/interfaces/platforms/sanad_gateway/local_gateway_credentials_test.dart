import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
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
        try {
          tempHome.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('loadOrCreate generates and persists a token on first call', () async {
      final first = await LocalGatewayCredentials.loadOrCreateForDaemonStart();
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
      final first = await LocalGatewayCredentials.loadOrCreateForDaemonStart();
      final second = await LocalGatewayCredentials.loadOrCreateForDaemonStart();
      expect(first.value, equals(second.value));
    });

    test('concurrent first-start calls converge on one token', () async {
      final credentials = await Future.wait(
        List.generate(
          12,
          (_) => LocalGatewayCredentials.loadOrCreateForDaemonStart(),
        ),
      );

      expect(
        credentials.map((credential) => credential.value).toSet(),
        hasLength(1),
      );
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
      final created =
          await LocalGatewayCredentials.loadOrCreateForDaemonStart();
      final read = LocalGatewayCredentials.tryRead();
      expect(read, isNotNull);
      expect(read!.value, equals(created.value));
    });

    test('extractFromHeaders accepts the custom header', () async {
      final created =
          await LocalGatewayCredentials.loadOrCreateForDaemonStart();
      final extracted = LocalGatewayCredentials.extractFromHeaders({
        LocalGatewayCredentials.headerName: created.value,
      }, created.value);
      expect(extracted, isNotNull);
      expect(extracted!.value, equals(created.value));
    });

    test('extractFromHeaders accepts Authorization: Bearer', () async {
      final created =
          await LocalGatewayCredentials.loadOrCreateForDaemonStart();
      final extracted = LocalGatewayCredentials.extractFromHeaders({
        'Authorization': 'Bearer ${created.value}',
      }, created.value);
      expect(extracted, isNotNull);
    });

    test('extractFromHeaders rejects a wrong token', () async {
      final created =
          await LocalGatewayCredentials.loadOrCreateForDaemonStart();
      final extracted = LocalGatewayCredentials.extractFromHeaders({
        LocalGatewayCredentials.headerName: 'wrong',
      }, created.value);
      expect(extracted, isNull);
    });

    test('toString does not leak the token value', () async {
      final created =
          await LocalGatewayCredentials.loadOrCreateForDaemonStart();
      expect(created.toString(), isNot(contains(created.value)));
    });

    group('per-Home credential binding', () {
      late Directory otherHome;

      setUp(() async {
        otherHome = Directory.systemTemp.createTempSync(
          'sanad-credentials-other-home-',
        );
      });

      tearDown(() {
        if (otherHome.existsSync()) {
          try {
            otherHome.deleteSync(recursive: true);
          } catch (_) {}
        }
      });

      Future<void> useHome(Directory directory) async {
        setSanadHomeOverride(directory.path);
        setSanadStateHomeOverride(directory.path);
        await SanadHomeBootstrap.prepareAll();
      }

      test('each Home generates its own credential', () async {
        final first =
            await LocalGatewayCredentials.loadOrCreateForDaemonStart();
        final firstBinding = File(
          SanadHomeBootstrap.resolveChild(
            LocalGatewayCredentials.bindingRelativePath,
          ),
        ).readAsStringSync();

        await useHome(otherHome);
        final second =
            await LocalGatewayCredentials.loadOrCreateForDaemonStart();
        final secondBinding = File(
          SanadHomeBootstrap.resolveChild(
            LocalGatewayCredentials.bindingRelativePath,
          ),
        ).readAsStringSync();

        expect(second.value, isNot(first.value));
        expect(firstBinding, sanadHomeIdentity(tempHome.path));
        expect(secondBinding, sanadHomeIdentity(otherHome.path));
      });

      test('a credential copied from another Home is rotated', () async {
        final source =
            await LocalGatewayCredentials.loadOrCreateForDaemonStart();
        final sourceToken = File(
          SanadHomeBootstrap.resolveChild(LocalGatewayCredentials.relativePath),
        ).readAsStringSync();
        final sourceBinding = File(
          SanadHomeBootstrap.resolveChild(
            LocalGatewayCredentials.bindingRelativePath,
          ),
        ).readAsStringSync();

        // A Test Home cloned from another Home carries both files verbatim.
        await useHome(otherHome);
        File(
          SanadHomeBootstrap.resolveChild(LocalGatewayCredentials.relativePath),
        ).writeAsStringSync(sourceToken);
        File(
          SanadHomeBootstrap.resolveChild(
            LocalGatewayCredentials.bindingRelativePath,
          ),
        ).writeAsStringSync(sourceBinding);

        expect(LocalGatewayCredentials.tryRead(), isNull);

        final migrated =
            await LocalGatewayCredentials.loadOrCreateForDaemonStart();

        expect(migrated.value, isNot(source.value));
        expect(
          File(
            SanadHomeBootstrap.resolveChild(
              LocalGatewayCredentials.bindingRelativePath,
            ),
          ).readAsStringSync(),
          sanadHomeIdentity(otherHome.path),
        );
        expect(LocalGatewayCredentials.tryRead()?.value, migrated.value);
      });

      test('a legacy credential without a binding is rotated once', () async {
        await useHome(tempHome);
        final legacy = File(
          SanadHomeBootstrap.resolveChild(LocalGatewayCredentials.relativePath),
        );
        legacy.writeAsStringSync('legacy-shared-token');

        final migrated =
            await LocalGatewayCredentials.loadOrCreateForDaemonStart();

        expect(migrated.value, isNot('legacy-shared-token'));
        expect(
          File(
            SanadHomeBootstrap.resolveChild(
              LocalGatewayCredentials.bindingRelativePath,
            ),
          ).readAsStringSync(),
          sanadHomeIdentity(tempHome.path),
        );
        // The binding makes the rotation a one-time migration.
        expect(
          (await LocalGatewayCredentials.loadOrCreateForDaemonStart()).value,
          migrated.value,
        );
      });

      test('a non-daemon reader never rotates a foreign credential', () async {
        // Regression: `sanad login` used the daemon loader, so an upgrade
        // rotated `.local_token` under a daemon that was still running and the
        // desktop Client was rejected until that daemon restarted.
        await useHome(otherHome);
        final tokenFile = File(
          SanadHomeBootstrap.resolveChild(LocalGatewayCredentials.relativePath),
        )..writeAsStringSync('credential-of-another-home');
        final bindingFile = File(
          SanadHomeBootstrap.resolveChild(
            LocalGatewayCredentials.bindingRelativePath,
          ),
        )..writeAsStringSync(sanadHomeIdentity(tempHome.path));

        expect(LocalGatewayCredentials.tryRead(), isNull);
        expect(
          () => LocalGatewayCredentials.readExisting(),
          throwsA(isA<LocalGatewayCredentialUnavailable>()),
        );

        expect(tokenFile.readAsStringSync(), 'credential-of-another-home');
        expect(
          bindingFile.readAsStringSync(),
          sanadHomeIdentity(tempHome.path),
        );
      });

      test(
        'a non-daemon reader does not migrate a legacy credential',
        () async {
          await useHome(tempHome);
          final tokenFile = File(
            SanadHomeBootstrap.resolveChild(
              LocalGatewayCredentials.relativePath,
            ),
          )..writeAsStringSync('legacy-shared-token');
          final bindingFile = File(
            SanadHomeBootstrap.resolveChild(
              LocalGatewayCredentials.bindingRelativePath,
            ),
          );

          expect(
            LocalGatewayCredentials.readExisting().value,
            'legacy-shared-token',
          );

          // Migration is the daemon's job on its next start; a read-only caller
          // leaves both files exactly as it found them.
          expect(tokenFile.readAsStringSync(), 'legacy-shared-token');
          expect(bindingFile.existsSync(), isFalse);
        },
      );

      test(
        'a non-daemon reader creates nothing when no token exists',
        () async {
          await useHome(tempHome);
          final tokenFile = File(
            SanadHomeBootstrap.resolveChild(
              LocalGatewayCredentials.relativePath,
            ),
          );
          final bindingFile = File(
            SanadHomeBootstrap.resolveChild(
              LocalGatewayCredentials.bindingRelativePath,
            ),
          );

          expect(
            () => LocalGatewayCredentials.readExisting(),
            throwsA(isA<LocalGatewayCredentialUnavailable>()),
          );

          expect(tokenFile.existsSync(), isFalse);
          expect(bindingFile.existsSync(), isFalse);
        },
      );
    });
  });
}
