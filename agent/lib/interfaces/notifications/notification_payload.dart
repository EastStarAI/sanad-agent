/// Plan 174 — composition of the redacted notification instruction.
///
/// This is the last place a notification field is written before it leaves the
/// device. Every text field crosses [SecretsRedactor] here and is bounded here,
/// so no other module needs to remember either rule. The payload carries the
/// finished copy and one target instruction; it carries no transcript, no tool
/// output, no tool schema, no workspace path, and no credential.
library;

import 'dart:convert';

import '../../core/secrets_redactor.dart';
import 'notification_ask.dart';
import 'notification_copy.dart';
import 'notification_kind.dart';

/// Protocol identity of the notification instruction.
abstract final class NotificationWire {
  /// Envelope protocol token carried next to the version.
  static const protocol = 'sanad.notification';

  /// Instruction schema version. A receiver that does not know it ignores the
  /// instruction rather than guessing.
  static const version = 1;

  /// Payload key holding the instruction object inside the canonical payload.
  static const payloadKey = 'notification';
}

/// Who a dispatch step is addressed to.
enum NotificationTargetScope {
  clientInstance('client_instance'),
  account('account');

  const NotificationTargetScope(this.wireName);

  final String wireName;
}

/// The single target instruction a content-opaque relay resolves.
final class NotificationTarget {
  const NotificationTarget._(this.scope, this.clientInstanceId);

  /// One named Client instance.
  factory NotificationTarget.clientInstance(String clientInstanceId) {
    final normalized = clientInstanceId.trim().toLowerCase();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        clientInstanceId,
        'clientInstanceId',
        'A client_instance target needs an instance id.',
      );
    }
    return NotificationTarget._(
      NotificationTargetScope.clientInstance,
      normalized,
    );
  }

  /// Every push-capable device of the account.
  static const account = NotificationTarget._(
    NotificationTargetScope.account,
    null,
  );

  final NotificationTargetScope scope;
  final String? clientInstanceId;

  bool get isAccountWide => scope == NotificationTargetScope.account;

  Map<String, dynamic> toJson() => {
    'scope': scope.wireName,
    if (clientInstanceId != null) 'client_instance_id': clientInstanceId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotificationTarget &&
          other.scope == scope &&
          other.clientInstanceId == clientInstanceId);

  @override
  int get hashCode => Object.hash(scope, clientInstanceId);

  @override
  String toString() => isAccountWide
      ? 'NotificationTarget(account)'
      : 'NotificationTarget(client_instance)';
}

/// Which step of the delivery policy produced an instruction.
enum NotificationDispatchStep {
  /// First delivery, addressed to the originating Client instance.
  origin('origin'),

  /// The 90-second escalation, addressed to the whole account.
  escalation('escalation'),

  /// A single account-wide delivery that replaced the timer.
  immediate('immediate');

  const NotificationDispatchStep(this.wireName);

  final String wireName;
}

/// Whether an instruction raises or withdraws a notification.
enum NotificationInstruction {
  dispatch('dispatch'),
  withdraw('withdraw');

  const NotificationInstruction(this.wireName);

  final String wireName;
}

/// Composes the redacted, bounded notification instruction.
class NotificationPayloadComposer {
  const NotificationPayloadComposer({
    this.redactor = const SecretsRedactor(),
    this.maxTitleLength = 120,
    this.maxBodyLength = 280,
    this.maxActionLabelLength = 32,
    this.lifetime = defaultLifetime,
  });

  /// How long an instruction stays meaningful. A device that receives it later
  /// than this must not wake the user for an ask that is already over.
  static const defaultLifetime = Duration(minutes: 30);

  final SecretsRedactor redactor;
  final int maxTitleLength;
  final int maxBodyLength;
  final int maxActionLabelLength;
  final Duration lifetime;

  /// Composes one dispatch instruction.
  ///
  /// [dispatchEventId] is assigned by the transport layer to the canonical
  /// event that carries this payload; it is kept on the instruction as
  /// `instruction_event_id` only so diagnostics never confuse it with
  /// [NotificationAsk.eventId], which is the notification's identity.
  Map<String, dynamic> composeDispatch({
    required NotificationAsk ask,
    required NotificationLocale locale,
    required NotificationTarget target,
    required NotificationDispatchStep step,
    required DateTime dispatchedAt,
    String? dispatchEventId,
  }) {
    final text = NotificationCopy.render(
      kind: ask.kind,
      locale: locale,
      sessionTitle: ask.sessionTitle,
      ask: ask.excerpt,
    );
    final expiresAt = dispatchedAt.toUtc().add(lifetime);
    return {
      'protocol': NotificationWire.protocol,
      'version': NotificationWire.version,
      'session_id': _identifier(ask.sessionId),
      NotificationWire.payloadKey: {
        'instruction': NotificationInstruction.dispatch.wireName,
        'step': step.wireName,
        'event_id': _identifier(ask.eventId),
        'request_id': _identifier(ask.requestId),
        'kind': ask.kind.value,
        'urgency': ask.effectiveUrgency.wireName,
        'target': target.toJson(),
        'locale': locale.code,
        'title': _text(text.title, maxTitleLength),
        'body': _text(text.body, maxBodyLength),
        'actions': [
          for (final action in text.actions)
            {
              'id': action.id,
              'label': _text(action.label, maxActionLabelLength),
            },
        ],
        'deep_link': {
          'session_id': _identifier(ask.sessionId),
          'request_id': _identifier(ask.requestId),
        },
        'collapse_key': collapseKeyFor(ask),
        'created_at': _timestamp(dispatchedAt),
        'expires_at': _timestamp(expiresAt),
        'platform_hints': platformHintsFor(
          kind: ask.kind,
          urgency: ask.effectiveUrgency,
          sessionId: ask.sessionId,
        ),
        if (dispatchEventId != null)
          'instruction_event_id': _identifier(dispatchEventId),
      },
    };
  }

  /// Composes one withdrawal instruction for a notification that may already
  /// be visible somewhere.
  ///
  /// Withdrawal is account-scoped because the Agent names targets, not tokens:
  /// it cannot know which devices the relay reached, and a device that never
  /// saw the identity drops the withdrawal. It carries no copy.
  Map<String, dynamic> composeWithdraw({
    required NotificationAsk ask,
    required String reason,
    required DateTime withdrawnAt,
    String? dispatchEventId,
  }) => {
    'protocol': NotificationWire.protocol,
    'version': NotificationWire.version,
    'session_id': _identifier(ask.sessionId),
    NotificationWire.payloadKey: {
      'instruction': NotificationInstruction.withdraw.wireName,
      'event_id': _identifier(ask.eventId),
      'request_id': _identifier(ask.requestId),
      'kind': ask.kind.value,
      'target': NotificationTarget.account.toJson(),
      'collapse_key': collapseKeyFor(ask),
      'reason': reason,
      'created_at': _timestamp(withdrawnAt),
      'expires_at': _timestamp(withdrawnAt.toUtc().add(lifetime)),
      if (dispatchEventId != null)
        'instruction_event_id': _identifier(dispatchEventId),
    },
  };

  /// The dedupe and grouping key shared by every step of one ask.
  String collapseKeyFor(NotificationAsk ask) =>
      _identifier('${ask.sessionId}:${ask.kind.value}');

  /// The platform hints the Agent already decided for one kind.
  ///
  /// The Android channel is per kind so muting one kind cannot mute the rest,
  /// and the Apple category is per kind so a Client can attach the right
  /// actions without reading copy. The thread identifier is the session, so
  /// one conversation groups on every platform.
  Map<String, dynamic> platformHintsFor({
    required NotificationKind kind,
    required NotificationUrgency urgency,
    required String sessionId,
  }) => {
    'android_channel_id': _identifier(
      'sanad_${kind.value}_${urgency.wireName}',
    ),
    'ios_category': _identifier('SANAD_${kind.value.toUpperCase()}'),
    'thread_id': _identifier(sessionId),
  };

  /// Redacts, collapses, and bounds one text field.
  String _text(String raw, int bound) {
    final redacted = redactor.redact(raw);
    final collapsed = redacted.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= bound) return collapsed;
    return collapsed.substring(0, bound).trimRight();
  }

  /// Bounds an identifier without redacting it; an id is not prose.
  String _identifier(String raw) {
    final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 128) return collapsed;
    return collapsed.substring(0, 128);
  }

  static String _timestamp(DateTime value) => value.toUtc().toIso8601String();

  /// Serializes a composed instruction for a transport payload.
  String encode(Map<String, dynamic> payload) => jsonEncode(payload);
}
