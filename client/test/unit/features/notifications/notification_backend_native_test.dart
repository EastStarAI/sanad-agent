import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/infrastructure/darwin_action_categories.dart';
import 'package:sanad_client/features/notifications/infrastructure/notification_backend_native.dart';

const Map<NotificationActionIntent, String> _localized = <NotificationActionIntent, String>{
  NotificationActionIntent.allowOnce: 'Autoriser une fois',
  NotificationActionIntent.allowSession: 'Autoriser pour la session',
  NotificationActionIntent.deny: 'Refuser',
  NotificationActionIntent.open: 'Ouvrir',
};

NotificationPresentationRequest _request({
  List<NotificationPresentationAction> actions = const <NotificationPresentationAction>[],
  bool offersApprovalActions = true,
}) {
  return NotificationPresentationRequest(
    id: 1,
    title: 'Approve the command?',
    body: 'shell wants to run ls',
    urgency: NotificationUrgency.high,
    payload: '{}',
    actions: actions,
    offersApprovalActions: offersApprovalActions,
  );
}

NotificationPresentationAction _action(NotificationAction action) =>
    NotificationPresentationAction(id: action.id, label: action.intent.name);

void main() {
  group('native adapter registration', () {
    test('registers the localized action copy with the platform', () {
      final settings = FlutterLocalNotificationsAdapter.buildSettings(
        approvalActionLabels: _localized,
      );

      expect(
        settings.linux!.defaultActionName,
        _localized[NotificationActionIntent.open],
        reason: 'the freedesktop default action is localized, not a literal',
      );

      final categories = settings.macOS!.notificationCategories;
      expect(categories, hasLength(DarwinActionCategories.registeredActionSets.length));
      final full = categories.firstWhere(
        (category) => category.identifier == DarwinActionCategories.baseCategoryId,
      );
      expect(
        <String>[for (final action in full.actions) action.identifier],
        <String>[for (final action in NotificationAction.approvalActions) action.id],
      );
      expect(
        <String>[for (final action in full.actions) action.title],
        <String>[
          _localized[NotificationActionIntent.allowOnce]!,
          _localized[NotificationActionIntent.allowSession]!,
          _localized[NotificationActionIntent.deny]!,
        ],
      );
    });

    test('registers English fallback copy only when no labels are supplied', () {
      final settings = FlutterLocalNotificationsAdapter.buildSettings();

      expect(settings.linux!.defaultActionName, 'Open');
      final categories = settings.macOS!.notificationCategories;
      final titles = <String>[
        for (final category in categories)
          for (final action in category.actions) action.title,
      ];
      expect(titles, isNotEmpty);
      for (final title in titles) {
        expect(title.trim(), isNotEmpty);
        // A raw intent name is protocol vocabulary, never button copy.
        for (final intent in NotificationActionIntent.values) {
          expect(title, isNot(intent.name));
        }
      }
    });

    test('every registered category carries the actions its identifier names', () {
      final categories = FlutterLocalNotificationsAdapter.buildSettings().macOS!
          .notificationCategories;

      for (final category in categories) {
        final actions = <String>[for (final action in category.actions) action.identifier];
        expect(actions, isNotEmpty);
        // The category id encodes exactly the registered set, and the request
        // selects the category by that same derivation.
        expect(
          category.identifier,
          DarwinActionCategories.idFor(<NotificationAction>[
            for (final id in actions) NotificationAction(id: id, intent: NotificationAction.intentForWireId(id)!),
          ]),
        );
      }
    });
  });

  group('native adapter presentation', () {
    test('selects the category matching the actions the payload offered', () {
      final offered = <NotificationPresentationAction>[
        _action(NotificationAction.approvalActions[0]),
        _action(NotificationAction.approvalActions[2]),
      ];

      final category = FlutterLocalNotificationsAdapter.approvalCategoryFor(
        _request(actions: offered),
      );

      expect(category, isNotNull);
      expect(category, isNot(DarwinActionCategories.baseCategoryId));
      final registered = FlutterLocalNotificationsAdapter.buildSettings()
          .macOS!
          .notificationCategories
          .firstWhere((entry) => entry.identifier == category);
      expect(
        <String>[for (final action in registered.actions) action.identifier],
        offered.map((action) => action.id).toList(),
        reason: 'the presented category cannot add the action the payload omitted',
      );
    });

    test('selects no category when the payload offered no action', () {
      expect(FlutterLocalNotificationsAdapter.approvalCategoryFor(_request()), isNull);
    });

    test('selects no category when the request is not an approval answer', () {
      expect(
        FlutterLocalNotificationsAdapter.approvalCategoryFor(
          _request(
            actions: <NotificationPresentationAction>[_action(NotificationAction.approvalActions[0])],
            offersApprovalActions: false,
          ),
        ),
        isNull,
      );
    });
  });

  group('native adapter launch interaction', () {
    test('maps the interaction that launched the process', () {
      final details = NotificationAppLaunchDetails(
        true,
        notificationResponse: const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          id: 1,
          actionId: NotificationAction.allowOnceId,
          payload: '{"session_id":"s1"}',
          data: <String, dynamic>{'extra': 7},
        ),
      );

      final mapped = FlutterLocalNotificationsAdapter.launchResponseFrom(details);

      expect(mapped, isNotNull);
      expect(mapped!.actionId, NotificationAction.allowOnceId);
      expect(mapped.payload, '{"session_id":"s1"}');
      expect(mapped.data, <String, String>{'extra': '7'});
    });

    test('reports no launch interaction when the process was not started by one', () {
      expect(FlutterLocalNotificationsAdapter.launchResponseFrom(null), isNull);
      expect(
        FlutterLocalNotificationsAdapter.launchResponseFrom(
          const NotificationAppLaunchDetails(false),
        ),
        isNull,
      );
      expect(
        FlutterLocalNotificationsAdapter.launchResponseFrom(
          const NotificationAppLaunchDetails(true),
        ),
        isNull,
        reason: 'a launch without a response is not an interaction',
      );
    });
  });
}
