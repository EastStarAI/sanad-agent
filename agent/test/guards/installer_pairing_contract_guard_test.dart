import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'installers support pairing, portal login, and local-only installation',
    () {
      final posix = File('../scripts/install.sh').readAsStringSync();
      final windows = File('../scripts/install.ps1').readAsStringSync();
      final login = File('bin/login.dart').readAsStringSync();

      expect(posix, contains('--pairing-token'));
      expect(posix, contains('--login'));
      expect(posix, contains('--no-login'));
      expect(posix, contains('login --token "\$PAIRING_TOKEN"'));
      expect(posix, contains('login --portal'));
      expect(posix, contains('No interactive terminal detected'));
      expect(posix, contains('service install'));
      expect(posix, contains('service restart'));
      expect(posix, contains('SERVICE_WAS_RUNNING'));

      expect(windows, contains('[string]\$PairingToken'));
      expect(windows, contains('[switch]\$Login'));
      expect(windows, contains('[switch]\$NoLogin'));
      expect(windows, contains('login --token \$PairingToken'));
      expect(windows, contains('login --portal'));
      expect(windows, contains('No interactive terminal detected'));
      expect(windows, contains('service install'));
      expect(windows, contains('service restart'));
      expect(windows, contains('\$ServiceWasRunning'));
      expect(windows, contains('\$ServiceInstalledThisRun'));
      expect(
        windows,
        contains(
          'Unregister-ScheduledTask -TaskName "SanadAgent" '
          '-Confirm:\$false',
        ),
      );
      expect(windows, contains('Sanad \$(\$Manifest.version) for Windows'));
      expect(windows, isNot(contains('Sanad 1.0.1 for Windows')));

      expect(login, contains("args.contains('--portal')"));
      expect(login, contains('Choose either --portal or --token'));

      expect(
        posix.indexOf('login --token "\$PAIRING_TOKEN"'),
        lessThan(posix.indexOf('service install')),
      );
      expect(
        windows.indexOf('login --token \$PairingToken'),
        lessThan(windows.indexOf('service install')),
      );
      expect(
        posix.indexOf('login --portal'),
        lessThan(posix.indexOf('service install')),
      );
      expect(
        windows.indexOf('login --portal'),
        lessThan(windows.indexOf('service install')),
      );
      expect(
        posix.indexOf('service install'),
        lessThan(posix.indexOf('service restart')),
      );
      expect(
        windows.indexOf('service install'),
        lessThan(windows.indexOf('service restart')),
      );

      expect(posix, isNot(contains('device_token')));
      expect(windows, isNot(contains('device_token')));
    },
  );
}
