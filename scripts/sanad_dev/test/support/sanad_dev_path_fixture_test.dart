import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/path_equivalence.dart';
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'sanad_dev_test_fixtures.dart';

void main() {
  group('platform-neutral path and fixture normalization', () {
    test('equivalentPaths handles null and identical paths', () {
      expect(equivalentPaths('/repo/client', '/repo/client'), isTrue);
      expect(equivalentPaths(null, '/repo/client'), isFalse);
    });

    test('equivalentPaths handles spaces and host casing', () {
      if (Platform.isWindows) {
        expect(
          equivalentPaths(
            r'C:\Users\John Doe\sanad-agent\client',
            r'c:/users/john doe/sanad-agent/client',
          ),
          isTrue,
        );
      } else {
        expect(
          equivalentPaths(
            '/Users/John Doe/sanad-agent/client',
            '/Users/John Doe/sanad-agent/client',
          ),
          isTrue,
        );
      }
    });

    test('equivalentPaths handles Unicode paths', () {
      final first = Platform.isWindows
          ? r'C:\المشاريع\سند\client'
          : '/home/المشاريع/سند/client';
      final second = Platform.isWindows
          ? r'c:/المشاريع/سند/client'
          : '/home/المشاريع/سند/client';
      expect(equivalentPaths(first, second), isTrue);
    });

    test('equivalentPaths handles drive roots on Windows', () {
      if (!Platform.isWindows) return;

      expect(equivalentPaths(r'C:\', 'c:/'), isTrue);
      expect(equivalentPaths(r'C:\repo\client', r'D:\repo\client'), isFalse);
    });

    test('equivalentPaths handles UNC syntax on Windows', () {
      if (!Platform.isWindows) return;

      expect(
        equivalentPaths(
          r'\\server\share\repo\client',
          r'\\SERVER\share\repo\client',
        ),
        isTrue,
      );
      expect(
        equivalentPaths(
          r'\\server\share\repo\client',
          r'\\other\share\repo\client',
        ),
        isFalse,
      );
    });

    test('equivalentPaths handles NT device prefixes on Windows', () {
      if (!Platform.isWindows) return;

      expect(equivalentPaths(r'\\?\C:\repo\client', r'c:\repo\client'), isTrue);
      expect(
        equivalentPaths(
          r'\\?\UNC\server\share\repo\client',
          r'\\SERVER\share\repo\client',
        ),
        isTrue,
      );
    });

    test(
      'preferences prefix is stable across casing and separators on Windows',
      () {
        if (!Platform.isWindows) return;

        final upper = runtime_context.deriveSanadDevPreferencesPrefix(
          r'C:\repo\isolated\home',
        );
        final lower = runtime_context.deriveSanadDevPreferencesPrefix(
          r'c:\repo\isolated\home',
        );
        final forward = runtime_context.deriveSanadDevPreferencesPrefix(
          'C:/repo/isolated/home/',
        );

        expect(upper, lower);
        expect(upper, forward);
        expect(upper, startsWith('sanad.'));
      },
    );

    test('preferences prefix handles spaces and Unicode safely', () {
      final withSpaces = runtime_context.deriveSanadDevPreferencesPrefix(
        Platform.isWindows
            ? r'C:\Users\John Doe\Sanad Home'
            : '/Users/John Doe/Sanad Home',
      );
      final withUnicode = runtime_context.deriveSanadDevPreferencesPrefix(
        Platform.isWindows
            ? r'C:\المشاريع\سند\home'
            : '/home/المشاريع/سند/home',
      );

      expect(withSpaces, startsWith('sanad.'));
      expect(withUnicode, startsWith('sanad.'));
      expect(withSpaces, isNot(withUnicode));
    });

    test('createTestRuntime maps synthetic paths to the host', () {
      final runtime = createTestRuntime(platformNeutral: true);
      expect(runtime.workspaceRoot, platformNeutralTestPath('/repo'));
      expect(runtime.sanadHome, platformNeutralTestPath('/isolated/home'));
    });

    test('platformNeutralTestPath preserves relative path semantics', () {
      final path = platformNeutralTestPath('repo/client');
      expect(path, 'repo${Platform.pathSeparator}client');
    });
  });
}
