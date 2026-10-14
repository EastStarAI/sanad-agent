import 'dart:async';

import 'package:sanad_windows_path/windows_path.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsSystemPath', () {
    test('non-Windows passes inherited PATH through without a read', () async {
      var calls = 0;
      final resolver = WindowsSystemPath(
        isWindows: false,
        runPowerShell: () async {
          calls++;
          return r'C:\not\called';
        },
        runPowerShellSync: () {
          calls++;
          return r'C:\not\called';
        },
      );

      expect(await resolver.resolve('/inherited'), '/inherited');
      expect(resolver.resolveSync('/inherited'), '/inherited');
      expect(calls, 0);
    });

    test('Windows returns combined Machine and User PATH', () async {
      final resolver = WindowsSystemPath(
        isWindows: true,
        runPowerShell: () async =>
            r'C:\Program Files\nodejs;C:\Users\x\AppData\Roaming\npm',
      );

      expect(
        await resolver.resolve(r'C:\inherited'),
        r'C:\Program Files\nodejs;C:\Users\x\AppData\Roaming\npm',
      );
    });

    test('resolveSync uses its injected runner and caches the result', () {
      var calls = 0;
      final resolver = WindowsSystemPath(
        isWindows: true,
        runPowerShellSync: () {
          calls++;
          return r'C:\resolved';
        },
      );

      expect(resolver.resolveSync(r'C:\first'), r'C:\resolved');
      expect(resolver.resolveSync(r'C:\second'), r'C:\resolved');
      expect(calls, 1);
    });

    test(
      'failed reads cache inherited PATH to prevent repeated spawning',
      () async {
        var calls = 0;
        final resolver = WindowsSystemPath(
          isWindows: true,
          runPowerShell: () async {
            calls++;
            return null;
          },
        );

        expect(await resolver.resolve(r'C:\inherited'), r'C:\inherited');
        expect(await resolver.resolve(r'C:\inherited'), r'C:\inherited');
        expect(calls, 1);
      },
    );

    test('empty reads fall back to inherited PATH', () async {
      final resolver = WindowsSystemPath(
        isWindows: true,
        runPowerShell: () async => '   ',
      );

      expect(await resolver.resolve(r'C:\inherited'), r'C:\inherited');
    });

    test('concurrent callers share one PowerShell read', () async {
      var calls = 0;
      final result = Completer<String?>();
      final resolver = WindowsSystemPath(
        isWindows: true,
        runPowerShell: () {
          calls++;
          return result.future;
        },
      );

      final first = resolver.resolve(r'C:\first');
      final second = resolver.resolve(r'C:\second');
      result.complete(r'C:\resolved');

      expect(await first, r'C:\resolved');
      expect(await second, r'C:\resolved');
      expect(calls, 1);
    });

    test('TTL expiry and clearCache force fresh reads', () async {
      var calls = 0;
      var now = DateTime.utc(2026);
      final resolver = WindowsSystemPath(
        isWindows: true,
        cacheTtl: const Duration(minutes: 5),
        now: () => now,
        runPowerShell: () async => 'C:\\resolved-${++calls}',
      );

      expect(await resolver.resolve(r'C:\a'), r'C:\resolved-1');
      now = now.add(const Duration(minutes: 4));
      expect(await resolver.resolve(r'C:\b'), r'C:\resolved-1');
      now = now.add(const Duration(minutes: 2));
      expect(await resolver.resolve(r'C:\c'), r'C:\resolved-2');
      resolver.clearCache();
      expect(await resolver.resolve(r'C:\d'), r'C:\resolved-3');
    });
  });

  test('PATH helpers handle Windows key casing without duplicates', () {
    final inherited = {'Path': r'C:\old', 'OTHER': 'value'};
    expect(inheritedPathFromEnvironment(inherited), r'C:\old');
    expect(replaceEnvironmentPath(inherited, r'C:\new'), {
      'OTHER': 'value',
      'PATH': r'C:\new',
    });
  });
}
