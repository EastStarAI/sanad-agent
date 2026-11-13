import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level contract for the web delivery surface.
///
/// No browser runs on this host, so the executable proof stops at the build and
/// the source contract. Everything a browser would prove — a real push, a
/// click, an installed iOS app — is recorded as unexecuted in
/// `docs/plans/tasks/174d-web-push-and-pwa.md`.
void main() {
  final manifest = jsonDecode(File('web/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
  final worker = File('web/sw.js').readAsStringSync();
  final index = File('web/index.html').readAsStringSync();

  group('installable PWA', () {
    test('the manifest is served standalone with installable icons', () {
      expect(manifest['display'], 'standalone');
      expect(manifest['start_url'], isNotEmpty);
      final icons = (manifest['icons'] as List<dynamic>).cast<Map<String, dynamic>>();
      final sizes = icons.map((icon) => icon['sizes']).toSet();
      expect(sizes, containsAll(<String>['192x192', '512x512']));
      expect(
        icons.any((icon) => icon['purpose'] == 'maskable'),
        isTrue,
        reason: 'Android install prompts need a maskable icon',
      );
    });
  });

  group('service worker ownership', () {
    test('the bootstrap registers the owned worker and not the Flutter worker', () {
      expect(bootstrap, contains('{{flutter_js}}'));
      expect(bootstrap, contains('{{flutter_build_config}}'));
      expect(bootstrap, contains("register(new URL('sw.js', scope).toString()"));
      // Exactly one registration exists, and it is the owned worker.
      expect(RegExp(r'serviceWorker\s*\n?\s*\.register\(').allMatches(bootstrap), hasLength(1));
      expect(bootstrap, contains('_flutter.loader.load()'));
    });

    test('the page loads the bootstrap instead of registering a worker itself', () {
      expect(index, contains('<script src="flutter_bootstrap.js" async></script>'));
      expect(index, isNot(contains('serviceWorker.register')));
    });

    test('the owned worker handles push, clicks, and rotation', () {
      expect(worker, contains("addEventListener('push'"));
      expect(worker, contains("addEventListener('notificationclick'"));
      expect(worker, contains("addEventListener('pushsubscriptionchange'"));
      expect(worker, contains('showNotification'));
      expect(worker, contains('openWindow'));
    });

    test('the worker caches no app shell, so offline behavior is unchanged', () {
      // Flutter 3.47's generated worker is a self-unregistering tombstone; this
      // worker replaces it and deliberately adds no fetch handler.
      expect(worker, isNot(contains("addEventListener('fetch'")));
      expect(worker, contains("startsWith('flutter')"), reason: 'legacy caches are cleared');
    });
  });

  group('foreground authority', () {
    test('a visible tab receives a wake-up and shows nothing', () {
      expect(worker, contains("visibilityState === 'visible'"));
      expect(worker, contains('postMessage({ type: PUSH_MESSAGE'));
      final visibleBranch = worker.indexOf("visibilityState === 'visible'");
      final showCall = worker.indexOf('self.registration.showNotification');
      expect(visibleBranch, isNonNegative);
      expect(showCall, greaterThan(visibleBranch), reason: 'show comes after the visible check');
    });

    test('the worker derives the same collapse identity as the Client', () {
      expect(worker, contains('0x811c9dc5'));
      expect(worker, contains('0x01000193'));
      expect(worker, contains(r'ask\u0000'));
      final collapse = File(
        'lib/features/notifications/domain/models/notification_collapse_key.dart',
      ).readAsStringSync();
      expect(collapse, contains('0x811c9dc5'));
      expect(collapse, contains('0x01000193'));
      expect(collapse, contains(r'ask\u0000'));
    });

    test('the worker knows every Agent-owned kind and no Client-owned kind', () {
      final kinds = File('lib/features/notifications/domain/models/notification_kind.dart').readAsStringSync();
      final wires = RegExp(r"[a-zA-Z]+\('([a-z_]+)'\)").allMatches(kinds).map((m) => m.group(1)!);
      // The two Client-owned kinds are raised locally and never traverse the
      // relay, so the worker must not accept them from a push.
      const clientOwned = <String>{'connection_lost', 'auth_required'};
      for (final wire in wires) {
        if (clientOwned.contains(wire)) {
          expect(worker, isNot(contains("'$wire'")), reason: '$wire is Client-owned');
        } else {
          expect(worker, contains("'$wire'"), reason: '$wire is Agent-owned');
        }
      }
    });

    test('a withdrawal closes the notification instead of raising one', () {
      expect(worker, contains("instruction === 'withdraw'"));
      expect(worker, contains('closeByTag'));
    });

    test('the closed-tab path honours the mirrored preferences', () {
      expect(worker, contains('sanad_web_push_policy'));
      expect(worker, contains('muted_kinds'));
    });
  });

  group('subscription lifecycle', () {
    test('the VAPID public key is a build define, never a private key', () {
      final config = File('lib/core/config/app_config.dart').readAsStringSync();
      expect(config, contains("String.fromEnvironment(\n    'SANAD_WEB_PUSH_VAPID_PUBLIC_KEY'"));
      for (final path in <String>[
        'lib/features/notifications/application/web_push_subscription_service.dart',
        'lib/features/notifications/data/http_web_push_subscription_registrar.dart',
        'lib/features/notifications/infrastructure/web_notification_runtime.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source.toLowerCase(), isNot(contains('private_key')));
        expect(source.toLowerCase(), isNot(contains('vapid_private')));
      }
    });

    test('the subscription is registered with the authenticated account', () {
      final registrar = File(
        'lib/features/notifications/data/http_web_push_subscription_registrar.dart',
      ).readAsStringSync();
      expect(registrar, contains("'/api/notifications/web-push/subscriptions'"));
      expect(registrar, contains("'authorization': 'Bearer \$accessToken'"));

      final service = File(
        'lib/features/notifications/application/web_push_subscription_service.dart',
      ).readAsStringSync();
      expect(service, contains('failure: WebPushFailure.signInRequired'));
      expect(service, contains('revokeForLogout'));
    });

    test('permission is never requested outside an explicit Settings action', () {
      final bridge = File(
        'lib/features/notifications/presentation/notification_bridge.dart',
      ).readAsStringSync();
      expect(bridge, isNot(contains('requestPermission')));
      final service = File('lib/features/notifications/application/notification_service.dart').readAsStringSync();
      expect(service, isNot(contains('requestPermission')));
      final cubit = File(
        'lib/features/notifications/presentation/bloc/notification_settings_cubit.dart',
      ).readAsStringSync();
      expect(cubit, contains('Future<void> requestPermission()'));
    });

    test('the iOS install requirement is stated instead of hidden', () {
      final runtime = File(
        'lib/features/notifications/infrastructure/web_notification_runtime.dart',
      ).readAsStringSync();
      expect(runtime, contains("RegExp(r'iPad|iPhone|iPod')"));
      expect(runtime, contains('isStandalone'));
      expect(runtime, contains('WebPushAvailability.installRequired'));
    });

    test('actions route through the existing response path', () {
      final bridge = File(
        'lib/features/notifications/presentation/notification_bridge.dart',
      ).readAsStringSync();
      expect(bridge, contains('_actionRouter.handle(payload, interaction.actionId)'));
      final page = File(
        'lib/features/settings/presentation/widgets/settings_pages/notifications_page.dart',
      ).readAsStringSync();
      expect(page, contains('notificationsWebInstallRequiredBody'));
      expect(page, contains('notificationsWebDisable'));
    });
  });

  group('localization', () {
    test('every web string exists in both locales', () {
      final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
      final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync()) as Map<String, dynamic>;
      final webKeys = en.keys.where((key) => key.startsWith('notificationsWeb')).toList();
      expect(webKeys, isNotEmpty);
      for (final key in webKeys) {
        expect(ar.containsKey(key), isTrue, reason: '$key is missing from the Arabic source');
        expect((ar[key] as String).trim(), isNotEmpty);
      }
    });

    test('the Settings page holds no literal interface copy', () {
      final page = File(
        'lib/features/settings/presentation/widgets/settings_pages/notifications_page.dart',
      ).readAsStringSync();
      expect(page, isNot(contains('Desktop alerts when')));
      expect(page, isNot(contains('Browser alerts when')));
      expect(page, contains('l10n.'));
    });
  });
}
