import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/installed_home_record.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory accountHome;
  late String executable;

  /// Writes the ownership metadata `service install` records in a Home.
  void writeInstallRecord(String home) {
    File(
      p.join(home, InstalledHomeRecord.metadataFileName),
    ).writeAsStringSync(jsonEncode({'version': 1, 'sanad_home': home}));
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('sanad-installed-home-');
    // The dedicated `sanad-agent` account's passwd Home is the Sanad Home
    // itself, so the install record and the artifact live directly inside it.
    accountHome = Directory(p.join(root.path, 'sanad-agent'))
      ..createSync(recursive: true);
    Directory(p.join(accountHome.path, 'bin')).createSync();
    executable = p.join(accountHome.path, 'bin', 'sanad');
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('InstalledHomeRecord', () {
    test('resolves the Home that records an install beside the executable', () {
      writeInstallRecord(accountHome.path);

      expect(InstalledHomeRecord.homeOf(executable), accountHome.path);
    });

    test('accepts the Windows launcher name of the same layout', () {
      writeInstallRecord(accountHome.path);

      expect(
        InstalledHomeRecord.homeOf('$executable.exe'),
        accountHome.path,
      );
    });

    test('ignores an executable that is not installed at <home>/bin/sanad', () {
      writeInstallRecord(root.path);

      expect(
        InstalledHomeRecord.homeOf(p.join(root.path, 'dart')),
        isNull,
        reason: 'a source run executes the Dart VM, which installs no Home',
      );
      expect(
        InstalledHomeRecord.homeOf(p.join(accountHome.path, 'sanad')),
        isNull,
        reason: 'the artifact layout names the Home through its bin directory',
      );
      expect(
        InstalledHomeRecord.homeOf(p.join(accountHome.path, 'tools', 'sanad')),
        isNull,
      );
    });

    test('ignores a Home that carries no install record', () {
      expect(InstalledHomeRecord.homeOf(executable), isNull);
    });

    test('refuses a symlinked install record', () {
      if (Platform.isWindows) {
        // Creating a symlink needs a privilege the CI account does not hold.
        return;
      }
      final foreign = File(p.join(root.path, 'foreign.json'))
        ..writeAsStringSync('{}');
      Link(
        p.join(accountHome.path, InstalledHomeRecord.metadataFileName),
      ).createSync(foreign.path);

      expect(InstalledHomeRecord.homeOf(executable), isNull);
    });
  });

  group('resolveSanadHomePath', () {
    const defaultHome = '/home/sanad-agent/.sanad';

    test('an explicit selection wins over every other source', () {
      expect(
        resolveSanadHomePath(
          override: '/chosen',
          environmentHome: '/env',
          installedHome: '/installed',
          defaultHome: defaultHome,
        ),
        '/chosen',
      );
    });

    test('SANAD_HOME wins over the install record', () {
      expect(
        resolveSanadHomePath(
          override: null,
          environmentHome: '/env',
          installedHome: '/installed',
          defaultHome: defaultHome,
        ),
        '/env',
      );
    });

    test('the installed Home wins over the account default', () {
      expect(
        resolveSanadHomePath(
          override: null,
          environmentHome: null,
          installedHome: '/var/lib/sanad-agent',
          defaultHome: defaultHome,
        ),
        '/var/lib/sanad-agent',
      );
    });

    test('the account default answers when nothing else names a Home', () {
      expect(
        resolveSanadHomePath(
          override: null,
          environmentHome: null,
          installedHome: null,
          defaultHome: defaultHome,
        ),
        defaultHome,
      );
    });
  });

  group('dedicated service account', () {
    test('service commands resolve the installed Home, not \$HOME/.sanad', () {
      // Live shape from issue 353: the unit's account has $HOME equal to the
      // Sanad Home, the installer put the artifact in that Home's bin
      // directory, and `service install` recorded the ownership metadata there.
      writeInstallRecord(accountHome.path);
      final accountDefault = p.join(accountHome.path, '.sanad');

      final resolved = resolveSanadHomePath(
        override: null,
        environmentHome: null,
        installedHome: InstalledHomeRecord.homeOf(executable),
        defaultHome: accountDefault,
      );

      expect(resolved, accountHome.path);
      expect(
        resolved,
        isNot(accountDefault),
        reason: 'a second empty Home is what reports a healthy unit as broken',
      );
    });
  });
}
