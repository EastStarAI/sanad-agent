import 'dart:convert';

import 'package:sanad_agent/interfaces/notifications/notification_ask.dart';
import 'package:sanad_agent/interfaces/notifications/notification_copy.dart';
import 'package:sanad_agent/interfaces/notifications/notification_kind.dart';
import 'package:sanad_agent/interfaces/notifications/notification_payload.dart';
import 'package:test/test.dart';

const _instance = '11111111-1111-4111-8111-111111111111';
final _dispatchedAt = DateTime.utc(2026, 11, 13, 10, 0);

NotificationAsk _permissionAsk({
  String excerpt = 'shell_execute: git status',
  String? title = 'Fix the build',
}) => NotificationAsk(
  sessionId: 'session-1',
  requestId: 'request-1',
  eventId: 'evt-01JABCDEF',
  kind: NotificationKind.permissionRequest,
  excerpt: excerpt,
  sessionTitle: title,
);

Map<String, dynamic> _notificationOf(Map<String, dynamic> payload) =>
    payload[NotificationWire.payloadKey] as Map<String, dynamic>;

const _composer = NotificationPayloadComposer();

void main() {
  group('dispatch payload', () {
    test('carries every field the wire contract names', () {
      final payload = _composer.composeDispatch(
        ask: _permissionAsk(),
        locale: NotificationLocale.english,
        target: NotificationTarget.clientInstance(_instance),
        step: NotificationDispatchStep.origin,
        dispatchedAt: _dispatchedAt,
      );

      expect(payload['protocol'], NotificationWire.protocol);
      expect(payload['version'], NotificationWire.version);
      expect(payload['session_id'], 'session-1');
      final notification = _notificationOf(payload);
      expect(notification['instruction'], 'dispatch');
      expect(notification['step'], 'origin');
      expect(notification['event_id'], 'evt-01JABCDEF');
      expect(notification['request_id'], 'request-1');
      expect(notification['kind'], 'permission_request');
      expect(notification['urgency'], 'high');
      expect(notification['target'], {
        'scope': 'client_instance',
        'client_instance_id': _instance,
      });
      expect(notification['locale'], 'en');
      expect(notification['title'], 'Fix the build');
      expect(notification['body'], contains('git status'));
      expect(notification['deep_link'], {
        'session_id': 'session-1',
        'request_id': 'request-1',
      });
      expect(notification['collapse_key'], 'session-1:permission_request');
      expect(notification['created_at'], '2026-11-13T10:00:00.000Z');
      expect(notification['expires_at'], '2026-11-13T10:30:00.000Z');
      expect(notification['platform_hints'], {
        'android_channel_id': 'sanad_permission_request_high',
        'ios_category': 'SANAD_PERMISSION_REQUEST',
        'thread_id': 'session-1',
      });
      final actions = (notification['actions'] as List).cast<Map>();
      expect(actions.map((action) => action['id']), [
        'allow_once',
        'allow_session',
        'deny',
        'open',
      ]);
      expect(actions.first['label'], 'Allow once');
    });

    test(
      'an account-wide fan-out names the account and keeps one identity',
      () {
        final originPayload = _composer.composeDispatch(
          ask: _permissionAsk(),
          locale: NotificationLocale.english,
          target: NotificationTarget.clientInstance(_instance),
          step: NotificationDispatchStep.origin,
          dispatchedAt: _dispatchedAt,
        );
        final escalation = _composer.composeDispatch(
          ask: _permissionAsk(),
          locale: NotificationLocale.english,
          target: NotificationTarget.account,
          step: NotificationDispatchStep.escalation,
          dispatchedAt: _dispatchedAt.add(const Duration(seconds: 90)),
        );

        final escalationNotification = _notificationOf(escalation);
        expect(escalationNotification['target'], {'scope': 'account'});
        // One ask keeps one identity and one collapse key across every step.
        expect(
          escalationNotification['event_id'],
          _notificationOf(originPayload)['event_id'],
        );
        expect(
          escalationNotification['collapse_key'],
          _notificationOf(originPayload)['collapse_key'],
        );
      },
    );

    test(
      'a session without a title uses the kind fallback title in Arabic',
      () {
        final payload = _composer.composeDispatch(
          ask: _permissionAsk(title: null),
          locale: NotificationLocale.arabic,
          target: NotificationTarget.account,
          step: NotificationDispatchStep.immediate,
          dispatchedAt: _dispatchedAt,
        );

        final notification = _notificationOf(payload);
        expect(notification['title'], 'الموافقة مطلوبة');
        expect(notification['body'], contains('git status'));
      },
    );
  });

  group('redaction', () {
    test('a secret-bearing command is absent from every text field', () {
      final payload = _composer.composeDispatch(
        ask: _permissionAsk(
          excerpt:
              'shell_execute: curl -H "Authorization: Bearer abc123def456" '
              'https://api.example.com?api_key=sk-live-1234567890abcdef',
        ),
        locale: NotificationLocale.english,
        target: NotificationTarget.account,
        step: NotificationDispatchStep.immediate,
        dispatchedAt: _dispatchedAt,
      );

      final encoded = jsonEncode(payload);
      expect(encoded, isNot(contains('abc123def456')));
      expect(encoded, isNot(contains('sk-live-1234567890abcdef')));
      // The borrowed redactor masks the header value; only the mask survives.
      expect(_notificationOf(payload)['body'], contains('***'));
    });

    test('a registered secret in the session title is redacted too', () {
      final payload = _composer.composeDispatch(
        ask: _permissionAsk(title: 'Rotate token=supersecretvalue1'),
        locale: NotificationLocale.english,
        target: NotificationTarget.account,
        step: NotificationDispatchStep.immediate,
        dispatchedAt: _dispatchedAt,
      );

      expect(jsonEncode(payload), isNot(contains('supersecretvalue1')));
      expect(_notificationOf(payload)['title'], 'Rotate token: ***');
    });
  });

  group('bounds', () {
    test('title, body and labels are bounded after redaction', () {
      final composer = NotificationPayloadComposer(
        maxTitleLength: 10,
        maxBodyLength: 20,
        maxActionLabelLength: 4,
      );
      final payload = composer.composeDispatch(
        ask: _permissionAsk(
          title: 'A very long session title that cannot fit anywhere',
          excerpt: 'shell_execute: ${'x' * 400}',
        ),
        locale: NotificationLocale.english,
        target: NotificationTarget.account,
        step: NotificationDispatchStep.immediate,
        dispatchedAt: _dispatchedAt,
      );

      final notification = _notificationOf(payload);
      expect((notification['title']! as String).length, lessThanOrEqualTo(10));
      expect((notification['body']! as String).length, lessThanOrEqualTo(20));
      for (final action in (notification['actions'] as List).cast<Map>()) {
        expect((action['label']! as String).length, lessThanOrEqualTo(4));
      }
    });
  });

  group('content discipline', () {
    test(
      'no transcript, tool output, schema, or credential enters the payload',
      () {
        const secret = 'sk-super-secret-value-123456';
        final ask = NotificationAsk.fromSuspension(
          sessionId: 'session-1',
          requestId: 'request-1',
          eventId: 'evt-1',
          kind: NotificationKind.permissionRequest,
          payload: {
            'tool_name': 'shell_execute',
            'tool_input': {'command': 'ls -la'},
            'tool_output': 'total 0 drwx------ transcript of the run',
            'tool': {'description': 'full tool schema', 'schema': 'noise'},
            'workspace_path': '/Users/someone/private/project',
            'policy_key': 'policy-key-value',
            'api_key': secret,
            'transcript': 'user: hello, assistant: hi',
          },
        );
        final payload = _composer.composeDispatch(
          ask: ask,
          locale: NotificationLocale.english,
          target: NotificationTarget.account,
          step: NotificationDispatchStep.immediate,
          dispatchedAt: _dispatchedAt,
        );

        final encoded = jsonEncode(payload);
        expect(encoded, isNot(contains('transcript of the run')));
        expect(encoded, isNot(contains('full tool schema')));
        expect(encoded, isNot(contains('/Users/someone/private/project')));
        expect(encoded, isNot(contains('policy-key-value')));
        expect(encoded, isNot(contains(secret)));
        expect(encoded, isNot(contains('user: hello')));
        // The ask itself survives: the tool and its command are the decision.
        expect(_notificationOf(payload)['body'], contains('ls -la'));
      },
    );

    test(
      'a user question excerpt is the question, and its values stay out',
      () {
        final ask = NotificationAsk.fromSuspension(
          sessionId: 'session-1',
          requestId: 'request-2',
          eventId: 'evt-2',
          kind: NotificationKind.userQuestion,
          payload: {
            'tool_name': 'system_ask_user',
            'questions': [
              {
                'question': 'Which database should I target?',
                'options': ['local', 'staging', 'production'],
              },
            ],
          },
        );

        expect(ask.excerpt, 'Which database should I target?');
        final payload = _composer.composeDispatch(
          ask: ask,
          locale: NotificationLocale.english,
          target: NotificationTarget.account,
          step: NotificationDispatchStep.immediate,
          dispatchedAt: _dispatchedAt,
        );
        final body = _notificationOf(payload)['body'] as String;
        expect(body, 'Which database should I target?');
        expect(body, isNot(contains('production')));
      },
    );

    test('a secret form uses its reason and never its field names', () {
      final ask = NotificationAsk.fromSuspension(
        sessionId: 'session-1',
        requestId: 'request-3',
        eventId: 'evt-3',
        kind: NotificationKind.userQuestion,
        payload: {
          'tool_name': 'system_request_secret',
          'reason': 'A deployment token is required to continue.',
          'fields': [
            {'name': 'DEPLOY_TOKEN', 'label': 'Deployment token'},
          ],
        },
      );

      expect(ask.excerpt, 'A deployment token is required to continue.');
      final payload = _composer.composeDispatch(
        ask: ask,
        locale: NotificationLocale.english,
        target: NotificationTarget.account,
        step: NotificationDispatchStep.immediate,
        dispatchedAt: _dispatchedAt,
      );
      expect(jsonEncode(payload), isNot(contains('DEPLOY_TOKEN')));
    });
  });

  group('withdrawal payload', () {
    test('carries the identity, the reason, and no copy', () {
      final payload = _composer.composeWithdraw(
        ask: _permissionAsk(),
        reason: NotificationWithdrawReason.resolved,
        withdrawnAt: _dispatchedAt.add(const Duration(seconds: 10)),
      );

      expect(payload['protocol'], NotificationWire.protocol);
      expect(payload['version'], NotificationWire.version);
      final notification = _notificationOf(payload);
      expect(notification['instruction'], 'withdraw');
      expect(notification['event_id'], 'evt-01JABCDEF');
      expect(notification['request_id'], 'request-1');
      expect(notification['reason'], 'resolved');
      expect(notification['target'], {'scope': 'account'});
      expect(notification.containsKey('title'), isFalse);
      expect(notification.containsKey('body'), isFalse);
      expect(notification.containsKey('actions'), isFalse);
    });
  });
}
