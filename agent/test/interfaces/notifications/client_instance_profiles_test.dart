import 'package:sanad_agent/interfaces/notifications/client_instance_profiles.dart';
import 'package:sanad_agent/interfaces/notifications/notification_copy.dart';
import 'package:test/test.dart';

const _instance = '11111111-1111-4111-8111-111111111111';

void main() {
  group('locale registration', () {
    test('a client.hello locale is registered for that instance', () {
      final profiles = ClientInstanceProfiles();
      profiles.registerFromHello(const {
        'type': 'client.hello',
        'protocol': 'sanad.identity_presence',
        'version': 1,
        'client_instance_id': _instance,
        'locale': 'ar',
      });

      expect(profiles.localeFor(_instance), NotificationLocale.arabic);
      expect(
        profiles.localeFor(_instance.toUpperCase()),
        NotificationLocale.arabic,
        reason: 'instance identity is case-insensitive',
      );
    });

    test('a locale nested in display metadata is accepted', () {
      final profiles = ClientInstanceProfiles();
      profiles.registerFromHello(const {
        'client_instance_id': _instance,
        'metadata': {'platform_family': 'ios', 'locale': 'ar-SA'},
      });

      expect(profiles.localeFor(_instance), NotificationLocale.arabic);
    });

    test('an absent or unsupported locale falls back to English', () {
      final profiles = ClientInstanceProfiles();
      profiles.registerFromHello(const {'client_instance_id': _instance});
      expect(profiles.localeFor(_instance), NotificationLocale.english);

      profiles.register(clientInstanceId: _instance, locale: 'fr');
      expect(
        profiles.localeFor(_instance),
        NotificationLocale.fallback,
        reason: 'an unsupported tag never replaces the defined fallback',
      );
    });

    test('an unknown instance renders in the fallback locale', () {
      final profiles = ClientInstanceProfiles();
      expect(
        profiles.localeFor('22222222-2222-4222-8222-222222222222'),
        NotificationLocale.fallback,
      );
      expect(profiles.localeFor(null), NotificationLocale.fallback);
    });

    test('re-registering without a locale keeps the known locale', () {
      final profiles = ClientInstanceProfiles();
      profiles.register(clientInstanceId: _instance, locale: 'ar');
      profiles.registerFromHello(const {'client_instance_id': _instance});

      expect(profiles.localeFor(_instance), NotificationLocale.arabic);
    });

    test('forgetting an instance restores the fallback', () {
      final profiles = ClientInstanceProfiles();
      profiles.register(clientInstanceId: _instance, locale: 'ar');
      profiles.forget(_instance);

      expect(profiles.localeFor(_instance), NotificationLocale.fallback);
    });

    test('a hello without a valid instance id registers nothing', () {
      final profiles = ClientInstanceProfiles();
      expect(profiles.registerFromHello(const {'locale': 'ar'}), isNull);
      expect(
        profiles.registerFromHello(const {'client_instance_id': '  '}),
        isNull,
      );
      expect(profiles.length, 0);
    });
  });

  group('notification capability', () {
    test('an undeclared instance is assumed able to notify', () {
      final profiles = ClientInstanceProfiles();
      expect(profiles.canNotify(null), isTrue);
      expect(profiles.canNotify(_instance), isTrue);
    });

    test('an explicit negative declaration persists', () {
      final profiles = ClientInstanceProfiles();
      profiles.registerFromHello(const {
        'client_instance_id': _instance,
        'notification_capable': false,
      });
      expect(profiles.canNotify(_instance), isFalse);

      // A later hello without the field keeps the declaration.
      profiles.registerFromHello(const {'client_instance_id': _instance});
      expect(profiles.canNotify(_instance), isFalse);
    });

    test('an explicit positive declaration is honoured', () {
      final profiles = ClientInstanceProfiles();
      profiles.register(clientInstanceId: _instance, canNotify: 'true');
      expect(profiles.canNotify(_instance), isTrue);
    });
  });

  test('the registry is bounded', () {
    final profiles = ClientInstanceProfiles(capacity: 2);
    for (var index = 0; index < 4; index += 1) {
      profiles.register(
        clientInstanceId: '0000000$index-0000-4000-8000-000000000000',
        locale: 'ar',
      );
    }

    expect(profiles.length, 2);
    expect(
      profiles.localeFor('00000000-0000-4000-8000-000000000000'),
      NotificationLocale.fallback,
    );
    expect(
      profiles.localeFor('00000003-0000-4000-8000-000000000000'),
      NotificationLocale.arabic,
    );
  });
}
