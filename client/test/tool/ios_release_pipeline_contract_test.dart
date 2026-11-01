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
    expect(scriptBody, contains('com.apple.developer.associated-domains'));
    expect(scriptBody, contains('ios/Runner/Runner.entitlements'));

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
}
