import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'keeps one UUID in one preference namespace across logout-style reuse',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      var generated = 0;
      final identity = ClientInstanceIdentity(
        preferences: preferences,
        uuidFactory: () {
          generated += 1;
          return '11111111-1111-4111-8111-111111111111';
        },
      );

      expect(await identity.load(), '11111111-1111-4111-8111-111111111111');
      expect(await identity.load(), '11111111-1111-4111-8111-111111111111');
      expect(generated, 1);
    },
  );

  test(
    'new preference namespace represents reinstall or isolated home',
    () async {
      SharedPreferences.setMockInitialValues({});
      final firstPreferences = await SharedPreferences.getInstance();
      final first = ClientInstanceIdentity(
        preferences: firstPreferences,
        uuidFactory: () => '11111111-1111-4111-8111-111111111111',
      );
      expect(await first.load(), '11111111-1111-4111-8111-111111111111');

      SharedPreferences.setMockInitialValues({});
      final secondPreferences = await SharedPreferences.getInstance();
      final second = ClientInstanceIdentity(
        preferences: secondPreferences,
        uuidFactory: () => '22222222-2222-4222-8222-222222222222',
      );
      expect(await second.load(), '22222222-2222-4222-8222-222222222222');
    },
  );

  test(
    'metadata is minimal and excludes personal host and network fields',
    () async {
      SharedPreferences.setMockInitialValues({});
      final identity = ClientInstanceIdentity(
        preferences: await SharedPreferences.getInstance(),
        platformName: () => 'macos',
        isWeb: () => false,
        isDesktop: () => true,
        isMobile: () => false,
        packageInfoLoader: () async => PackageInfo(
          appName: 'Sanad',
          packageName: 'com.eaststarai.sanad',
          version: '1.2.3',
          buildNumber: '9',
        ),
      );

      final json = (await identity.metadata()).toJson();
      expect(json, {
        'client_kind': 'desktop',
        'platform_family': 'macos',
        'os_family': 'macos',
        'app_version': '1.2.3',
      });
      expect(
        json.keys,
        isNot(
          containsAll(['hostname', 'email', 'ip', 'device_name', 'user_agent']),
        ),
      );
    },
  );

  test(
    'unknown platform and oversized version fall back without failing identity',
    () async {
      SharedPreferences.setMockInitialValues({});
      final identity = ClientInstanceIdentity(
        preferences: await SharedPreferences.getInstance(),
        platformName: () => 'fuchsia-next',
        isWeb: () => false,
        isDesktop: () => false,
        isMobile: () => false,
        packageInfoLoader: () async => PackageInfo(
          appName: 'Sanad',
          packageName: 'com.eaststarai.sanad',
          version: 'x' * 33,
          buildNumber: '1',
        ),
      );

      expect((await identity.metadata()).toJson(), {
        'client_kind': 'unknown',
        'platform_family': 'unknown',
      });
    },
  );
}
