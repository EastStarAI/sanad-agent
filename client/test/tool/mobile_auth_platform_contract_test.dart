import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android and iOS claim only the registered HTTPS auth callbacks', () {
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    for (final host in const [
      'dev.portal.sanad.eaststarai.com',
      'staging.portal.sanad.eaststarai.com',
      'portal.sanad.eaststarai.com',
    ]) {
      expect(androidManifest, contains('android:host="$host"'));
    }
    expect(
      'android:autoVerify="true"'.allMatches(androidManifest),
      hasLength(3),
    );
    expect(androidManifest, contains('android:path="/oauth/android"'));
    expect(androidManifest, contains('android:scheme="sanad"'));
    expect(
      androidManifest,
      contains('android:name="flutter_deeplinking_enabled"'),
    );

    final entitlements = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    expect(
      entitlements,
      contains('com.apple.developer.associated-domains'),
    );
    for (final domain in const [
      'applinks:dev.app.sanad.eaststarai.com',
      'applinks:staging.app.sanad.eaststarai.com',
      'applinks:app.sanad.eaststarai.com',
    ]) {
      expect(entitlements, contains(domain));
    }
    expect(
      entitlements,
      isNot(contains('applinks:dev.portal.sanad.eaststarai.com')),
      reason: 'The iOS callback must cross from Portal to the Client host.',
    );

    final xcodeProject = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(
      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'.allMatches(xcodeProject),
      hasLength(3),
    );
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(infoPlist, contains('<key>FlutterDeepLinkingEnabled</key>'));
    expect(
      infoPlist,
      contains('<key>FlutterDeepLinkingEnabled</key>\n\t<false/>'),
      reason: 'app_links must be the sole iOS OAuth callback owner.',
    );
    expect(infoPlist, contains('CFBundleURLSchemes'));
    expect(infoPlist, contains('<string>sanad</string>'));
    expect(infoPlist, isNot(contains('com.googleusercontent.apps.')));

    final productionConfig = jsonDecode(File('config/prod.json').readAsStringSync()) as Map<String, dynamic>;
    expect(
      productionConfig['SANAD_IOS_AUTH_REDIRECT_URI'],
      'https://app.sanad.eaststarai.com/oauth/ios',
    );
    expect(
      productionConfig['SANAD_ANDROID_AUTH_REDIRECT_URI'],
      'https://portal.sanad.eaststarai.com/oauth/android',
    );
  });
}
