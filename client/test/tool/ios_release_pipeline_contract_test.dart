import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// An iOS IPA that is exported from an unsigned `--no-codesign` archive loses
/// the app's own `CODE_SIGN_ENTITLEMENTS`, including
/// `com.apple.developer.associated-domains`. The installed app can then not
/// claim `app.sanad.eaststarai.com/oauth/ios`, iOS keeps the authentication
/// return in Safari, and login fails with "Authentication return failed" while
/// the app code and the portal are correct.
///
/// Both iOS pipelines therefore build and verify through one shared script.
void main() {
  test('both iOS workflows build the IPA through the shared script', () {
    final script = File('release/ios/build_signed_ipa.sh');
    expect(
      script.existsSync(),
      isTrue,
      reason: 'The signed IPA builder is the single owner of the iOS sequence.',
    );
    final scriptBody = script.readAsStringSync();
    expect(scriptBody, contains('--export-options-plist'));
    expect(
      scriptBody,
      isNot(contains('build ipa --release --no-codesign')),
      reason:
          'An unsigned archive loses the app entitlements on export, which is '
          'what broke the iOS authentication return.',
    );
    expect(scriptBody, contains('com.apple.developer.associated-domains'));
    expect(scriptBody, contains('ios/Runner/Runner.entitlements'));

    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(
      'CODE_SIGN_STYLE = Manual;'.allMatches(project),
      hasLength(2),
      reason:
          'Runner Release and Profile sign manually so a hosted runner needs no '
          'Apple ID account, and the pods and Swift packages keep their own '
          'signing settings.',
    );
    expect(
      'PROVISIONING_PROFILE_SPECIFIER = "'.allMatches(project),
      hasLength(2),
      reason:
          'Manual signing must name the reviewed profile for the app target; '
          'the builder fails when it drifts from the export options.',
    );
    expect(scriptBody, contains('Profile drift'));

    for (final workflow in const [
      '../.github/workflows/testflight.yml',
      '../.github/workflows/release.yml',
    ]) {
      final body = File(workflow).readAsStringSync();
      expect(
        body,
        contains('bash release/ios/build_signed_ipa.sh'),
        reason: '$workflow must delegate the iOS IPA sequence to the owner.',
      );
      expect(
        body,
        contains('--build-name='),
        reason:
            '$workflow passes key=value arguments, which the builder must '
            'accept.',
      );
      expect(
        body,
        isNot(contains('--no-codesign')),
        reason:
            '$workflow would archive unsigned and export an app without its '
            'own entitlements.',
      );
      expect(
        body,
        isNot(contains('xcodebuild -exportArchive')),
        reason:
            '$workflow would re-sign from the profile alone and drop the app '
            'entitlements.',
      );
    }
  });

  test(
    'the shipped builder accepts the key=value form the workflows use',
    () async {
      final result = await Process.run('bash', [
        'release/ios/build_signed_ipa.sh',
        '--build-name=1.0.20',
        '--build-number=21',
        '--export-options=missing/ExportOptions.plist',
      ]);
      expect(
        result.exitCode,
        2,
        reason: 'Argument parsing must reach the argument validation stage.',
      );
      expect(result.stderr, contains('Missing export options'));
      expect(result.stderr, isNot(contains('Unknown argument')));
    },
    skip: Platform.isWindows
        ? 'The builder is a Bash script exercised on POSIX runners.'
        : false,
  );
}
