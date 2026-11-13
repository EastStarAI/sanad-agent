import 'package:sanad_agent/interfaces/notifications/client_instance_profiles.dart';
import 'package:sanad_agent/interfaces/notifications/notification_copy.dart';
import 'package:sanad_agent/interfaces/notifications/notification_kind.dart';
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

  group('connection-scoped forgetting', () {
    test(
      'a closing socket does not erase an instance another socket holds',
      () {
        final profiles = ClientInstanceProfiles();
        profiles.register(
          clientInstanceId: _instance,
          locale: 'ar',
          canNotify: false,
          connectionKey: 'socket-a',
        );
        profiles.register(
          clientInstanceId: _instance,
          connectionKey: 'socket-b',
        );

        profiles.forget(_instance, connectionKey: 'socket-a');

        expect(
          profiles.localeFor(_instance),
          NotificationLocale.arabic,
          reason: 'socket-b still holds the same instance',
        );
        expect(profiles.canNotify(_instance), isFalse);

        profiles.forget(_instance, connectionKey: 'socket-b');

        expect(profiles.localeFor(_instance), NotificationLocale.fallback);
        expect(profiles.canNotify(_instance), isTrue);
      },
    );

    test('a hello registration is released with its own socket', () {
      final profiles = ClientInstanceProfiles();
      profiles.registerFromHello(const {
        'client_instance_id': _instance,
        'locale': 'ar',
      }, connectionKey: 'socket-a');

      profiles.forget(_instance, connectionKey: 'socket-other');
      expect(profiles.localeFor(_instance), NotificationLocale.arabic);

      profiles.forget(_instance, connectionKey: 'socket-a');
      expect(profiles.localeFor(_instance), NotificationLocale.fallback);
    });

    test('a bare forget cannot erase a registration a socket holds', () {
      final profiles = ClientInstanceProfiles();
      profiles.register(
        clientInstanceId: _instance,
        locale: 'ar',
        connectionKey: 'socket-a',
      );

      profiles.forget(_instance);
      expect(profiles.localeFor(_instance), NotificationLocale.arabic);

      profiles.clear();
      expect(profiles.localeFor(_instance), NotificationLocale.fallback);
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

  group('per-device notification preferences', () {
    test('a hello declaration is stored for that instance alone', () {
      final profiles = ClientInstanceProfiles();
      const other = '22222222-2222-4222-8222-222222222222';

      profiles.registerFromHello(const {
        'client_instance_id': _instance,
        'notifications': {
          'enabled': true,
          'kinds': {'completed': 'off', 'failed': 'normal'},
        },
      });
      profiles.registerFromHello(const {'client_instance_id': other});

      expect(profiles.allows(_instance, NotificationKind.completed), isFalse);
      expect(profiles.allows(other, NotificationKind.completed), isTrue,
          reason: 'one device lowering a kind never changes another device');
      expect(
        profiles.urgencyFor(_instance, NotificationKind.failed, NotificationUrgency.high),
        NotificationUrgency.normal,
      );
      expect(
        profiles.urgencyFor(other, NotificationKind.failed, NotificationUrgency.high),
        NotificationUrgency.high,
        reason: 'the other device keeps the product default',
      );
    });

    test('an unregistered instance keeps the product default', () {
      final profiles = ClientInstanceProfiles();

      expect(profiles.allows(null, NotificationKind.completed), isTrue);
      expect(profiles.allows('33333333-3333-4333-8333-333333333333', NotificationKind.blocked), isTrue);
      expect(
        profiles.urgencyFor(null, NotificationKind.completed, NotificationUrgency.high),
        NotificationUrgency.high,
      );
    });

    test('a re-registration that declares nothing keeps the stored choice', () {
      final profiles = ClientInstanceProfiles();
      profiles.register(
        clientInstanceId: _instance,
        notifications: const {
          'kinds': {'completed': 'off'},
        },
      );

      profiles.registerFromHello(const {'client_instance_id': _instance});

      expect(profiles.allows(_instance, NotificationKind.completed), isFalse,
          reason: 'a reconnect without a declaration is not a reset');
    });

    test('a declaration nested in display metadata is accepted too', () {
      final profiles = ClientInstanceProfiles();
      profiles.registerFromHello(const {
        'client_instance_id': _instance,
        'metadata': {
          'notifications': {
            'kinds': {'blocked': 'off'},
          },
        },
      });

      expect(profiles.allows(_instance, NotificationKind.blocked), isFalse);
    });

    test('a muted kind is read as muted and never as a quietened one', () {
      final profiles = ClientInstanceProfiles();
      profiles.registerFromHello(const {
        'client_instance_id': _instance,
        'notifications': {
          'enabled': true,
          'kinds': {'completed': 'off'},
        },
      });

      expect(profiles.allows(_instance, NotificationKind.completed), isFalse,
          reason: 'the Agent reads the declaration as a ceiling, so a mute must gate delivery');
      expect(
        profiles.urgencyFor(_instance, NotificationKind.completed, NotificationUrgency.high),
        NotificationUrgency.high,
        reason: 'a muted kind has no ceiling to lower an Agent decision with',
      );
    });

    test('a well-formed empty declaration resets to the product default', () {
      final profiles = ClientInstanceProfiles();
      profiles.register(
        clientInstanceId: _instance,
        notifications: const {
          'kinds': {'completed': 'off'},
        },
      );

      profiles.register(
        clientInstanceId: _instance,
        notifications: const <String, dynamic>{'enabled': true, 'kinds': <String, dynamic>{}},
      );

      expect(profiles.allows(_instance, NotificationKind.completed), isTrue);
    });
  });
}
