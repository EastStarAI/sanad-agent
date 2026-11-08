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
      expect(posix, contains('login --token-stdin'));
      expect(posix, contains('--pairing-token-stdin'));
      expect(posix, isNot(contains('login --token "\$PAIRING_TOKEN"')));
      expect(posix, contains('login --portal'));
      expect(posix, contains('No interactive terminal detected'));
      expect(posix, contains('service install'));
      expect(posix, contains('--expected-version'));
      expect(posix, contains('--require-cloud'));
      expect(posix, contains('restore_previous_installation'));
      expect(posix, contains('SERVICE_WAS_RUNNING'));
      expect(posix, contains('anchor apple generic'));
      expect(posix, contains('certificate leaf[subject.OU] = "UC2824B99G"'));
      expect(
        posix,
        contains('Developer ID Application: NanoSoft LY LLC (UC2824B99G)'),
      );
      expect(posix, isNot(contains("--test-requirement '=notarized'")));
      expect(posix, isNot(contains('spctl --assess --type execute')));

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
        posix.indexOf('login --token-stdin'),
        lessThan(
          posix.indexOf('"\$TARGET" service install --expected-version'),
        ),
      );
      expect(
        windows.indexOf('login --token \$PairingToken'),
        lessThan(windows.indexOf('service install')),
      );
      expect(
        posix.indexOf('login --portal'),
        lessThan(
          posix.indexOf('"\$TARGET" service install --expected-version'),
        ),
      );
      expect(
        windows.indexOf('login --portal'),
        lessThan(windows.indexOf('service install')),
      );
      expect(
        windows.indexOf('service install'),
        lessThan(windows.indexOf('service restart')),
      );

      expect(posix, isNot(contains('device_token')));
      expect(windows, isNot(contains('device_token')));
    },
  );

  test('installers name a target this release does not publish', () {
    final posix = File('../scripts/install.sh').readAsStringSync();

    // `aarch64` and `arm64` are the same target, and the asset is selected by
    // platform plus architecture only: a missing target must never be replaced
    // by another architecture's binary.
    expect(posix, contains('arm64|aarch64) ARCHITECTURE="arm64"'));
    expect(posix, contains('x86_64|amd64) ARCHITECTURE="x64"'));
    expect(posix, contains('select_agent_metadata'));
    expect(posix, contains(r'select_agent_metadata >"$SELECTION_FILE"'));
    expect(posix, contains('Published Agent targets'));
    expect(posix, contains('No official Sanad Agent build is published for %s'));
    expect(posix, contains(r'exit "$SELECTION_STATUS"'));
    // The requested target is reported before anything is downloaded.
    expect(
      posix.indexOf('No official Sanad Agent build is published'),
      lessThan(posix.indexOf(r'STAGED="$TEMP_DIR/$FILENAME"')),
    );
  });
}
