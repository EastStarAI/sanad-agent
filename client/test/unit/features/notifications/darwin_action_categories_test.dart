import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/infrastructure/darwin_action_categories.dart';

List<String> _ids(Iterable<NotificationAction> actions) => <String>[
      for (final action in actions) action.id,
    ];

void main() {
  group('macOS action categories', () {
    test('one category is registered per non-empty offered subset', () {
      final sets = DarwinActionCategories.registeredActionSets;

      expect(sets, hasLength((1 << NotificationAction.approvalActions.length) - 1));
      for (final set in sets) {
        expect(set, isNotEmpty);
        // Every category is a canonical subsequence of the approval order, so a
        // registration can never introduce an action of its own.
        var cursor = 0;
        for (final action in set) {
          final index = NotificationAction.approvalActions.indexOf(action);
          expect(index, greaterThanOrEqualTo(cursor), reason: 'out of order: $set');
          cursor = index;
        }
      }
    });

    test('the category ids are unique and the full set keeps the base id', () {
      final ids = <String>{
        for (final set in DarwinActionCategories.registeredActionSets)
          DarwinActionCategories.idFor(set),
      };

      expect(ids, hasLength(DarwinActionCategories.registeredActionSets.length));
      expect(
        DarwinActionCategories.idFor(NotificationAction.approvalActions),
        DarwinActionCategories.baseCategoryId,
      );
      expect(DarwinActionCategories.baseCategoryId, 'sanad_ask');
    });

    test('the presented set is exactly what the payload offered', () {
      for (final offered in DarwinActionCategories.registeredActionSets) {
        final category = DarwinActionCategories.categoryFor(_ids(offered));

        expect(category, isNotNull);
        // The category the adapter registered under this id carries exactly the
        // offered actions and nothing else.
        final registered = DarwinActionCategories.registeredActionSets.firstWhere(
          (set) => DarwinActionCategories.idFor(set) == category,
          orElse: () => fail('no category registered for $category'),
        );
        expect(_ids(registered), _ids(offered));
      }
    });

    test('a subset never selects the category that adds the missing action', () {
      final allowOnceOnly = DarwinActionCategories.categoryFor(<String>[
        NotificationAction.allowOnceId,
      ]);

      expect(allowOnceOnly, isNotNull);
      expect(allowOnceOnly, isNot(DarwinActionCategories.baseCategoryId));
      final registered = DarwinActionCategories.registeredActionSets.firstWhere(
        (set) => DarwinActionCategories.idFor(set) == allowOnceOnly,
      );
      expect(_ids(registered), <String>[NotificationAction.allowOnceId]);
      expect(_ids(registered), isNot(contains(NotificationAction.denyId)));
      expect(_ids(registered), isNot(contains(NotificationAction.allowSessionId)));
    });

    test('order and repetition in the payload do not change the category', () {
      final denyAndOnce = DarwinActionCategories.categoryFor(<String>[
        NotificationAction.denyId,
        NotificationAction.allowOnceId,
        NotificationAction.denyId,
      ]);

      expect(
        denyAndOnce,
        DarwinActionCategories.categoryFor(<String>[
          NotificationAction.allowOnceId,
          NotificationAction.denyId,
        ]),
      );
      expect(denyAndOnce, isNot(DarwinActionCategories.baseCategoryId));
    });

    test('nothing offered means no category, so no button can be invented', () {
      expect(DarwinActionCategories.categoryFor(const <String>[]), isNull);
      expect(DarwinActionCategories.categoryFor(<String>['unknown_action']), isNull);
      expect(
        DarwinActionCategories.categoryFor(<String>[
          NotificationAction.openId,
          'unknown_action',
        ]),
        isNull,
        reason: 'a plain open action is not an approval action',
      );
    });
  });
}
