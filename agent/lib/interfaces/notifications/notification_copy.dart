/// Plan 174 — Agent-owned notification copy for the kinds and action labels.
///
/// The Agent renders notification copy (plan 174, locked decision 13): the
/// payload leaves the device already localized, and the session title is never
/// translated. This table covers the notification kinds and the action labels
/// only, and nothing else.
///
/// Every authored key is named exactly like the Client localization key that
/// will carry the same sentence in `client/lib/l10n/app_en.arb`, so the parity
/// test can fail the moment the two codebases drift. The Arabic column is
/// user-facing interface copy — the same kind of literal the Client's own
/// generated localizations carry — not agent-facing output, a log, or a
/// protocol description.
library;

import 'notification_kind.dart';

/// The interface locale a notification is rendered in.
enum NotificationLocale {
  english('en'),
  arabic('ar');

  const NotificationLocale(this.code);

  /// The authored locale tag (`en`, `ar`).
  final String code;

  /// The locale used when a Client registers nothing, or registers something
  /// this table does not cover. English is the authored source locale.
  static const fallback = english;

  /// Parses a BCP-47 style tag (`ar`, `ar-SA`, `ar_SA`) into a supported locale.
  ///
  /// Returns `null` — never a guessed locale — when the tag is absent or not
  /// covered, so the caller applies [fallback] explicitly.
  static NotificationLocale? tryParse(Object? value) {
    final raw = value?.toString().trim().toLowerCase() ?? '';
    if (raw.isEmpty) return null;
    final primary = raw.split(RegExp('[-_]')).first;
    for (final locale in NotificationLocale.values) {
      if (locale.code == primary) return locale;
    }
    return null;
  }

  /// Resolves a registered tag to a locale, applying [fallback] when absent.
  static NotificationLocale resolve(Object? value) =>
      tryParse(value) ?? fallback;
}

/// Placeholder a body template uses for the rendered ask.
const String notificationAskPlaceholder = '{ask}';

/// One localized notification template for one kind.
final class NotificationCopyTemplate {
  const NotificationCopyTemplate({
    required this.titleKey,
    required this.titles,
    required this.bodyKey,
    required this.bodies,
    required this.actionIds,
  });

  /// Client localization key of the fallback title.
  final String titleKey;

  /// Fallback title per locale, used only when the session has no title.
  final Map<NotificationLocale, String> titles;

  /// Client localization key of the body sentence.
  final String bodyKey;

  /// Body sentence per locale; may carry [notificationAskPlaceholder].
  final Map<NotificationLocale, String> bodies;

  /// Action ids offered for this kind, in display order.
  final List<String> actionIds;

  /// Rendered fallback title, or the English one when the locale has none.
  String titleFor(NotificationLocale locale) =>
      titles[locale] ?? titles[NotificationLocale.fallback]!;

  /// Rendered body sentence, or the English one when the locale has none.
  String bodyFor(NotificationLocale locale) =>
      bodies[locale] ?? bodies[NotificationLocale.fallback]!;
}

/// One localized notification action label.
final class NotificationActionCopy {
  const NotificationActionCopy({
    required this.id,
    required this.clientKey,
    required this.labels,
  });

  /// The stable action id the Client and the relay carry verbatim.
  final String id;

  /// Client localization key of the same label.
  final String clientKey;

  /// Label per locale.
  final Map<NotificationLocale, String> labels;

  /// Rendered label, or the English one when the locale has none.
  String labelFor(NotificationLocale locale) =>
      labels[locale] ?? labels[NotificationLocale.fallback]!;
}

/// Action ids. They are stable wire values, not localized text.
abstract final class NotificationActionIds {
  static const allowOnce = 'allow_once';
  static const allowSession = 'allow_session';
  static const deny = 'deny';
  static const answer = 'answer';
  static const open = 'open';
}

const List<NotificationActionCopy> notificationActionCopy = [
  NotificationActionCopy(
    id: NotificationActionIds.allowOnce,
    clientKey: 'notificationActionAllowOnce',
    labels: {
      NotificationLocale.english: 'Allow once',
      NotificationLocale.arabic: 'اسمح مرة واحدة',
    },
  ),
  NotificationActionCopy(
    id: NotificationActionIds.allowSession,
    clientKey: 'notificationActionAllowSession',
    labels: {
      NotificationLocale.english: 'Allow for this session',
      NotificationLocale.arabic: 'اسمح لهذه الجلسة',
    },
  ),
  NotificationActionCopy(
    id: NotificationActionIds.deny,
    clientKey: 'notificationActionDeny',
    labels: {
      NotificationLocale.english: 'Deny',
      NotificationLocale.arabic: 'ارفض',
    },
  ),
  NotificationActionCopy(
    id: NotificationActionIds.answer,
    clientKey: 'notificationActionAnswer',
    labels: {
      NotificationLocale.english: 'Answer',
      NotificationLocale.arabic: 'أجب',
    },
  ),
  NotificationActionCopy(
    id: NotificationActionIds.open,
    clientKey: 'notificationActionOpen',
    labels: {
      NotificationLocale.english: 'Open',
      NotificationLocale.arabic: 'افتح',
    },
  ),
];

const Map<String, NotificationCopyTemplate> _notificationTemplates = {
  'permission_request': NotificationCopyTemplate(
    titleKey: 'notificationPermissionRequestTitle',
    titles: {
      NotificationLocale.english: 'Approval needed',
      NotificationLocale.arabic: 'الموافقة مطلوبة',
    },
    bodyKey: 'notificationPermissionRequestBody',
    bodies: {
      NotificationLocale.english:
          'Approval requested: $notificationAskPlaceholder',
      NotificationLocale.arabic: 'مطلوب موافقة: $notificationAskPlaceholder',
    },
    actionIds: [
      NotificationActionIds.allowOnce,
      NotificationActionIds.allowSession,
      NotificationActionIds.deny,
      NotificationActionIds.open,
    ],
  ),
  'user_question': NotificationCopyTemplate(
    titleKey: 'notificationUserQuestionTitle',
    titles: {
      NotificationLocale.english: 'Your answer is needed',
      NotificationLocale.arabic: 'إجابتك مطلوبة',
    },
    bodyKey: 'notificationUserQuestionBody',
    bodies: {
      NotificationLocale.english: notificationAskPlaceholder,
      NotificationLocale.arabic: notificationAskPlaceholder,
    },
    actionIds: [NotificationActionIds.answer, NotificationActionIds.open],
  ),
  'blocked': NotificationCopyTemplate(
    titleKey: 'notificationBlockedTitle',
    titles: {
      NotificationLocale.english: 'Session blocked',
      NotificationLocale.arabic: 'الجلسة متوقفة',
    },
    bodyKey: 'notificationBlockedBody',
    bodies: {
      NotificationLocale.english:
          'This session cannot continue without your intervention.',
      NotificationLocale.arabic: 'لا يمكن لهذه الجلسة المتابعة بدون تدخلك.',
    },
    actionIds: [NotificationActionIds.open],
  ),
  'failed': NotificationCopyTemplate(
    titleKey: 'notificationFailedTitle',
    titles: {
      NotificationLocale.english: 'Run failed',
      NotificationLocale.arabic: 'فشل التشغيل',
    },
    bodyKey: 'notificationFailedBody',
    bodies: {
      NotificationLocale.english: notificationAskPlaceholder,
      NotificationLocale.arabic: notificationAskPlaceholder,
    },
    actionIds: [NotificationActionIds.open],
  ),
  'completed': NotificationCopyTemplate(
    titleKey: 'notificationCompletedTitle',
    titles: {
      NotificationLocale.english: 'Result ready',
      NotificationLocale.arabic: 'النتيجة جاهزة',
    },
    bodyKey: 'notificationCompletedBody',
    bodies: {
      NotificationLocale.english: notificationAskPlaceholder,
      NotificationLocale.arabic: notificationAskPlaceholder,
    },
    actionIds: [NotificationActionIds.open],
  ),
  'background_task_done': NotificationCopyTemplate(
    titleKey: 'notificationBackgroundTaskDoneTitle',
    titles: {
      NotificationLocale.english: 'Background task finished',
      NotificationLocale.arabic: 'اكتملت مهمة الخلفية',
    },
    bodyKey: 'notificationBackgroundTaskDoneBody',
    bodies: {
      NotificationLocale.english: notificationAskPlaceholder,
      NotificationLocale.arabic: notificationAskPlaceholder,
    },
    actionIds: [NotificationActionIds.open],
  ),
  'scheduled_result': NotificationCopyTemplate(
    titleKey: 'notificationScheduledResultTitle',
    titles: {
      NotificationLocale.english: 'Scheduled result ready',
      NotificationLocale.arabic: 'النتيجة المجدولة جاهزة',
    },
    bodyKey: 'notificationScheduledResultBody',
    bodies: {
      NotificationLocale.english: notificationAskPlaceholder,
      NotificationLocale.arabic: notificationAskPlaceholder,
    },
    actionIds: [NotificationActionIds.open],
  ),
  'provider_quota': NotificationCopyTemplate(
    titleKey: 'notificationProviderQuotaTitle',
    titles: {
      NotificationLocale.english: 'Provider limit reached',
      NotificationLocale.arabic: 'تم بلوغ حد المزوّد',
    },
    bodyKey: 'notificationProviderQuotaBody',
    bodies: {
      NotificationLocale.english: notificationAskPlaceholder,
      NotificationLocale.arabic: notificationAskPlaceholder,
    },
    actionIds: [NotificationActionIds.open],
  ),
};

/// One rendered action, ready to be packed into a payload.
final class NotificationRenderedAction {
  const NotificationRenderedAction({
    required this.id,
    required this.clientKey,
    required this.label,
  });

  final String id;
  final String clientKey;
  final String label;
}

/// One fully rendered notification text group.
final class NotificationRenderedText {
  const NotificationRenderedText({
    required this.title,
    required this.body,
    required this.actions,
  });

  final String title;
  final String body;
  final List<NotificationRenderedAction> actions;
}

/// The authored copy table.
abstract final class NotificationCopy {
  /// Every authored template, keyed by kind value.
  static Map<String, NotificationCopyTemplate> get templates =>
      Map.unmodifiable(_notificationTemplates);

  /// The template for [kind], or `null` when the table does not cover it.
  static NotificationCopyTemplate? templateFor(NotificationKind kind) =>
      _notificationTemplates[kind.value];

  /// The authored action copy for [id], or `null` when the table has none.
  static NotificationActionCopy? actionFor(String id) {
    for (final action in notificationActionCopy) {
      if (action.id == id) return action;
    }
    return null;
  }

  /// Every authored Client localization key this table depends on.
  ///
  /// The parity test compares exactly this set with the Client localization
  /// keys, so a key added on either side without the other fails.
  static Set<String> get clientKeys => {
    for (final template in _notificationTemplates.values) ...[
      template.titleKey,
      template.bodyKey,
    ],
    for (final action in notificationActionCopy) action.clientKey,
  };

  /// Renders the copy for one ask.
  ///
  /// [sessionTitle] is carried verbatim (bounded and redacted later by the
  /// payload composer) because a session title is never translated. When it is
  /// absent the kind's authored fallback title is used.
  ///
  /// [ask] is the already-selected ask excerpt; it is not redacted here.
  ///
  /// Throws [ArgumentError] when the table does not cover [kind], so a new
  /// Agent kind cannot ship without copy.
  static NotificationRenderedText render({
    required NotificationKind kind,
    required NotificationLocale locale,
    String? sessionTitle,
    required String ask,
  }) {
    final template = templateFor(kind);
    if (template == null) {
      throw ArgumentError.value(
        kind.value,
        'kind',
        'No notification copy is authored for this kind.',
      );
    }
    final title = _boundedTitle(sessionTitle) ?? template.titleFor(locale);
    final body = _fillAsk(template.bodyFor(locale), ask);
    return NotificationRenderedText(
      title: title,
      body: body,
      actions: [
        for (final actionId in template.actionIds)
          if (actionFor(actionId) case final action?)
            NotificationRenderedAction(
              id: action.id,
              clientKey: action.clientKey,
              label: action.labelFor(locale),
            ),
      ],
    );
  }

  static String? _boundedTitle(String? raw) {
    final title = raw?.trim();
    if (title == null || title.isEmpty) return null;
    return title;
  }

  static String _fillAsk(String template, String ask) {
    final replacement = ask.trim();
    if (replacement.isNotEmpty) {
      return template.replaceAll(notificationAskPlaceholder, replacement);
    }
    return template
        .replaceAll(notificationAskPlaceholder, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[\s:—–-]+$'), '')
        .trim();
  }
}
