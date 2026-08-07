import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_boundary.dart';

void main() {
  group('SanadHomeBootstrap', () {
    late Directory tempHome;
    late Directory realHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync(
        'sanad-home-bootstrap-test-',
      );
      realHome = Directory.systemTemp.createTempSync(
        'sanad-home-bootstrap-real-',
      );
      setSanadHomeOverride(tempHome.path);
      setSanadStateHomeOverride(tempHome.path);
    });

    tearDown(() {
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
      if (realHome.existsSync()) {
        realHome.deleteSync(recursive: true);
      }
    });

    test('canonicalHome returns the resolved absolute path', () {
      final canonical = SanadHomeBootstrap.canonicalHome();
      expect(canonical, isNotEmpty);
      expect(Directory(canonical).existsSync(), isTrue);
    });

    test('resolveChild refuses `..` traversal', () {
      expect(
        () => SanadHomeBootstrap.resolveChild('../etc/passwd'),
        throwsA(
          isA<SanadHomeBoundaryViolation>().having(
            (e) => e.code,
            'code',
            'traversal',
          ),
        ),
      );
      expect(
        () => SanadHomeBootstrap.resolveChild('a/../../b'),
        throwsA(
          isA<SanadHomeBoundaryViolation>().having(
            (e) => e.code,
            'code',
            'traversal',
          ),
        ),
      );
    });

    test('resolveChild refuses NUL bytes and empty paths', () {
      expect(
        () => SanadHomeBootstrap.resolveChild('foo\u0000bar'),
        throwsA(
          isA<SanadHomeBoundaryViolation>().having(
            (e) => e.code,
            'code',
            'null_byte',
          ),
        ),
      );
      expect(
        () => SanadHomeBootstrap.resolveChild(''),
        throwsA(
          isA<SanadHomeBoundaryViolation>().having(
            (e) => e.code,
            'code',
            'empty_path',
          ),
        ),
      );
    });

    test('writeSecret creates a 0600 file and removes the temp file', () async {
      await SanadHomeBootstrap.writeSecret('auth.json', [
        0x7b,
        0x22,
        0x69,
        0x64,
        0x22,
        0x3a,
        0x31,
        0x7d,
      ]);
      final canonical = SanadHomeBootstrap.resolveChild('auth.json');
      final file = File(canonical);
      expect(file.existsSync(), isTrue);
      if (!Platform.isWindows) {
        final mode = file.statSync().mode & 0x1ff;
        expect(mode, equals(0x180));
      }
      final stragglers = file.parent
          .listSync()
          .where((e) => e.path.contains('.tmp.'))
          .toList();
      expect(stragglers, isEmpty);
    });

    test('writeConfig creates a file with the expected bytes', () async {
      await SanadHomeBootstrap.writeConfig('note.txt', 'hello-world');
      final bytes = SanadHomeBootstrap.readSecret('note.txt');
      expect(String.fromCharCodes(bytes), equals('hello-world'));
    });

    test(
      'atomic replace overwrites existing content and leaves no backup',
      () async {
        await SanadHomeBootstrap.writeSecret('replace-me.json', [0x41]);
        await SanadHomeBootstrap.writeSecret('replace-me.json', [0x42, 0x43]);
        final bytes = SanadHomeBootstrap.readSecret('replace-me.json');
        expect(bytes, equals([0x42, 0x43]));

        final canonical = SanadHomeBootstrap.resolveChild('replace-me.json');
        final leftovers = File(canonical).parent
            .listSync()
            .where((e) => e.path.endsWith('.bak') || e.path.contains('.tmp.'))
            .toList();
        expect(leftovers, isEmpty);
      },
    );

    test(
      'writeSecret refuses traversal and never touches the target',
      () async {
        final untouched = File(p.join(realHome.path, 'traversal-target.txt'))
          ..writeAsStringSync('original');
        expect(
          () => SanadHomeBootstrap.writeSecret('../traversal-target.txt', [
            0x41,
            0x42,
            0x43,
          ]),
          throwsA(isA<SanadHomeBoundaryViolation>()),
        );
        expect(untouched.readAsStringSync(), equals('original'));
      },
    );

    test('resolveChild refuses a symlink that escapes the home', () {
      // Use a unique target file per test to avoid collisions with
      // other tests in this group.
      final target = File(p.join(realHome.path, 'symlink-escape-target.txt'))
        ..writeAsStringSync('original');
      final escape = Link(p.join(tempHome.path, 'escape-sym'));
      escape.createSync(target.path);
      expect(
        () => SanadHomeBootstrap.resolveChild('escape-sym'),
        throwsA(isA<SanadHomeBoundaryViolation>()),
      );
    });

    test(
      'prepareAll secures roots without walking existing children',
      () async {
        if (Platform.isWindows) return;
        final untouched = File(p.join(tempHome.path, 'untouched-development'))
          ..writeAsStringSync('existing');
        Process.runSync('chmod', ['755', tempHome.path]);
        Process.runSync('chmod', ['644', untouched.path]);

        await SanadHomeBootstrap.prepareAll();

        expect(tempHome.statSync().mode & 0x1ff, equals(0x1c0));
        expect(untouched.statSync().mode & 0x1ff, equals(0x1a4));
      },
    );

    test(
      'prepare refuses a root symlink without touching its target',
      () async {
        if (Platform.isWindows) return;
        final marker = File(p.join(realHome.path, 'marker'))
          ..writeAsStringSync('unchanged');
        final linkedHome = p.join(tempHome.parent.path, 'linked-sanad-home');
        final link = Link(linkedHome)..createSync(realHome.path);
        addTearDown(() {
          if (link.existsSync()) link.deleteSync();
        });
        setSanadHomeOverride(linkedHome);
        setSanadStateHomeOverride(linkedHome);

        await expectLater(
          SanadHomeBootstrap.prepareAll(),
          throwsA(isA<SanadHomeBoundaryViolation>()),
        );
        expect(marker.readAsStringSync(), 'unchanged');
      },
    );

    test(
      'prepare rejects overlapping roots before creating the child',
      () async {
        final nested = p.join(tempHome.path, 'nested-state');
        setSanadStateHomeOverride(nested);

        await expectLater(
          SanadHomeBootstrap.prepareAll(),
          throwsA(
            isA<SanadHomeBoundaryViolation>().having(
              (error) => error.code,
              'code',
              'overlapping_roots',
            ),
          ),
        );
        expect(Directory(nested).existsSync(), isFalse);
      },
    );

    test('readSecret tightens owner-only mode before reading', () {
      if (Platform.isWindows) return;
      final legacy = File(p.join(tempHome.path, 'legacy-secret'))
        ..writeAsStringSync('secret');
      Process.runSync('chmod', ['644', legacy.path]);

      expect(
        String.fromCharCodes(SanadHomeBootstrap.readSecret('legacy-secret')),
        'secret',
      );
      expect(legacy.statSync().mode & 0x1ff, 0x180);
    });

    test('secureDatabaseFiles tightens WAL and SHM sidecars', () async {
      if (Platform.isWindows) return;
      final wal = File(p.join(tempHome.path, 'state.db-wal'))
        ..writeAsBytesSync([1]);
      final shm = File(p.join(tempHome.path, 'state.db-shm'))
        ..writeAsBytesSync([2]);
      Process.runSync('chmod', ['644', wal.path]);
      Process.runSync('chmod', ['644', shm.path]);

      await SanadHomeBootstrap.identity().secureDatabaseFiles();

      expect(wal.statSync().mode & 0x1ff, 0x180);
      expect(shm.statSync().mode & 0x1ff, 0x180);
    });

    test(
      'process umask secures SQLite sidecars created after bootstrap',
      () async {
        if (Platform.isWindows) return;
        await SanadHomeBootstrap.prepareAll();
        final lateSidecar = File(p.join(tempHome.path, 'state.db-journal'))
          ..writeAsBytesSync([1, 2, 3]);

        expect(lateSidecar.statSync().mode & 0x1ff, 0x180);
      },
    );

    test(
      'exists returns false for missing and true for present files',
      () async {
        expect(SanadHomeBootstrap.exists('missing.json'), isFalse);
        await SanadHomeBootstrap.writeSecret('present.json', [0x31]);
        expect(SanadHomeBootstrap.exists('present.json'), isTrue);
      },
    );
  });
}
