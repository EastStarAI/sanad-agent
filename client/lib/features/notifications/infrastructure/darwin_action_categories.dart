import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';

/// The macOS notification categories that carry approval buttons.
///
/// macOS fixes a category's buttons when the category is registered, and
/// `DarwinInitializationSettings.notificationCategories` is read exactly once,
/// at `initialize`. A single `sanad_ask` category would therefore present all
/// three approval buttons for every ask — including an ask whose payload offered
/// only a subset — and a button the payload never offered could be pressed and
/// would become a decision the Agent did not ask for.
///
/// This class derives one category per non-empty subset of
/// [NotificationAction.approvalActions]. The adapter registers that family once
/// at startup, and a presented notification selects the category whose actions
/// equal what the payload offered, so the presented action set can never exceed
/// it. A payload that offers no action this build can name matches no category
/// and is presented without buttons, which fails closed.
abstract final class DarwinActionCategories {
  /// The category for the full approval set, and the identifier root of the
  /// family (`sanad_ask`, `sanad_ask.allow_once`, …).
  static const String baseCategoryId = 'sanad_ask';

  /// The approval actions, in the order macOS presents them.
  static List<NotificationAction> get approvalActions =>
      NotificationAction.approvalActions;

  /// Every category registered at startup: one per non-empty subset of
  /// [approvalActions], in canonical action order.
  static List<List<NotificationAction>> get registeredActionSets {
    final base = approvalActions;
    final sets = <List<NotificationAction>>[];
    for (var mask = 1; mask < (1 << base.length); mask++) {
      sets.add(<NotificationAction>[
        for (var index = 0; index < base.length; index++)
          if (mask & (1 << index) != 0) base[index],
      ]);
    }
    return List<List<NotificationAction>>.unmodifiable(sets);
  }

  /// The category id for exactly [offeredActionIds], or `null` when the payload
  /// offers no approval action this build knows.
  ///
  /// Order and repetition in [offeredActionIds] do not matter: the set is
  /// canonicalized against [approvalActions], and an id outside that set is
  /// dropped rather than registered, so a category can never show a button the
  /// payload did not offer.
  static String? categoryFor(Iterable<String> offeredActionIds) {
    final offered = offeredActionIds.toSet();
    final actions = <NotificationAction>[
      for (final action in approvalActions)
        if (offered.contains(action.id)) action,
    ];
    if (actions.isEmpty) return null;
    return idFor(actions);
  }

  /// The canonical category id for a non-empty set of [actions].
  ///
  /// [actions] must be non-empty and taken from [approvalActions]; an empty set
  /// has no registered category, and a caller that has no action must not select
  /// one at all (see [categoryFor]).
  static String idFor(List<NotificationAction> actions) {
    final ids = <String>[for (final action in actions) action.id];
    final baseIds = <String>[for (final action in approvalActions) action.id];
    if (ids.length == baseIds.length && baseIds.every(ids.contains)) {
      return baseCategoryId;
    }
    return '$baseCategoryId.${ids.join('+')}';
  }
}
