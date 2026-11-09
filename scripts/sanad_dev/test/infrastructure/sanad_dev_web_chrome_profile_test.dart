import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/web_chrome_profile.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad_web_profile_test.');
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  const flagPrefix = '--web-browser-flag=--user-data-dir=';

  List<String> chromeArguments() => ['flutter', 'run', '-d', 'chrome'];

  String? profileFlag(List<String> arguments) {
    for (final argument in arguments) {
      if (argument.startsWith(flagPrefix)) return argument;
    }
    return null;
  }

  group('persistent Chrome profile', () {
    test(
      'a Chrome Client gets a Home-scoped profile that is owner-only',
      () async {
        final arguments = chromeArguments();

        await applySanadDevWebBrowserProfile(
          arguments,
          device: 'chrome',
          sanadHome: home.path,
        );

        final expected = sanadDevWebChromeProfileDirectory(home.path);
        expect(profileFlag(arguments), '$flagPrefix$expected');
        expect(
          expected,
          endsWith(
            '${Platform.pathSeparator}dev${Platform.pathSeparator}'
            'chrome-web${Platform.pathSeparator}primary',
          ),
        );
        expect(Directory(expected).existsSync(), isTrue);
        if (!Platform.isWindows) {
          expect(FileStat.statSync(expected).mode & 0x1ff, 0x1c0);
        }
      },
    );

    test('a Client instance slot owns its own profile directory', () async {
      final arguments = chromeArguments();

      await applySanadDevWebBrowserProfile(
        arguments,
        device: 'chrome',
        sanadHome: home.path,
        clientInstanceSlot: 'web-primary',
      );

      final primary = sanadDevWebChromeProfileDirectory(home.path);
      final slotted = sanadDevWebChromeProfileDirectory(
        home.path,
        clientInstanceSlot: 'web-primary',
      );
      expect(slotted, isNot(primary));
      expect(slotted, endsWith('${Platform.pathSeparator}web-primary'));
      expect(profileFlag(arguments), '$flagPrefix$slotted');
      expect(Directory(slotted).existsSync(), isTrue);
    });

    test('native devices get no profile and create no Web state', () async {
      final arguments = [
        'flutter',
        'run',
        '-d',
        'macos',
        '$flagPrefix/tmp/stale-profile',
      ];

      await applySanadDevWebBrowserProfile(
        arguments,
        device: 'macos',
        sanadHome: home.path,
      );

      expect(profileFlag(arguments), isNull);
      expect(
        Directory('${home.path}${Platform.pathSeparator}dev').existsSync(),
        isFalse,
      );
    });

    test('reapplying replaces an inherited profile flag', () async {
      final arguments = [...chromeArguments(), '$flagPrefix/tmp/stale-profile'];

      await applySanadDevWebBrowserProfile(
        arguments,
        device: 'chrome',
        sanadHome: home.path,
        clientInstanceSlot: 'web-primary',
      );

      final flags = arguments
          .where((argument) => argument.startsWith(flagPrefix))
          .toList();
      expect(flags, hasLength(1));
      expect(
        flags.single,
        endsWith(
          sanadDevWebChromeProfileDirectory(
            home.path,
            clientInstanceSlot: 'web-primary',
          ),
        ),
      );
    });

    test(
      'a Home path containing a comma fails closed before any write',
      () async {
        final commaHome = Directory(
          '${home.path}${Platform.pathSeparator}home,withcomma',
        );
        await commaHome.create();
        final arguments = chromeArguments();

        await expectLater(
          applySanadDevWebBrowserProfile(
            arguments,
            device: 'chrome',
            sanadHome: commaHome.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('comma'),
            ),
          ),
        );

        expect(profileFlag(arguments), isNull);
        expect(
          Directory(
            '${commaHome.path}${Platform.pathSeparator}dev',
          ).existsSync(),
          isFalse,
        );
      },
    );

    test('Windows Home paths keep one separator shape', () {
      const windowsHome = r'C:\Users\Dev\.sanad-test-3';

      expect(
        sanadDevWebChromeProfileDirectory(
          windowsHome,
          clientInstanceSlot: 'web-primary',
          separator: r'\',
        ),
        r'C:\Users\Dev\.sanad-test-3\dev\chrome-web\web-primary',
      );
      expect(
        sanadDevWebChromeProfileDirectory('$windowsHome\\', separator: r'\'),
        r'C:\Users\Dev\.sanad-test-3\dev\chrome-web\primary',
      );
    });

    test('an unsafe slot or an empty Home fails closed', () {
      expect(
        () => sanadDevWebChromeProfileDirectory(
          home.path,
          clientInstanceSlot: '../escape',
        ),
        throwsFormatException,
      );
      expect(
        () => sanadDevWebChromeProfileDirectory(
          home.path,
          clientInstanceSlot: 'Web_Primary',
        ),
        throwsFormatException,
      );
      expect(
        () => sanadDevWebChromeProfileDirectory('   '),
        throwsFormatException,
      );
    });

    test('the switch controller reapplies the profile for extra Clients', () {
      // The controller is library-private, so its call site is guarded here
      // next to the port reapplication it must mirror.
      final packageDir = Directory.current.path.endsWith('sanad_dev')
          ? Directory.current
          : Directory('scripts/sanad_dev');
      final source = File(
        '${packageDir.path}/lib/src/runtime/switch/switch_controller.dart',
      ).readAsStringSync();

      final portCall = source.indexOf('applySanadDevWebPort(');
      final profileCall = source.indexOf('applySanadDevWebBrowserProfile(');
      expect(portCall, isNonNegative);
      expect(profileCall, greaterThan(portCall));
    });
  });
}
