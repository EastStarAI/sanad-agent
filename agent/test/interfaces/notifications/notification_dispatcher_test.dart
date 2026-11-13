import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/notifications/client_instance_profiles.dart';
import 'package:sanad_agent/interfaces/notifications/notification_ask.dart';
import 'package:sanad_agent/interfaces/notifications/notification_dispatcher.dart';
import 'package:sanad_agent/interfaces/notifications/notification_kind.dart';
import 'package:sanad_agent/interfaces/notifications/notification_payload.dart';
import 'package:sanad_agent/interfaces/notifications/notification_presence.dart';
import 'package:test/test.dart';

const _desktopInstance = '11111111-1111-4111-8111-111111111111';
const _phoneInstance = '22222222-2222-4222-8222-222222222222';

/// A timer the test owns, so no case waits for the escalation window.
final class _RecordingTimer implements NotificationTimer {
  _RecordingTimer(this.delay, this.onFire);

  final Duration delay;
  final void Function() onFire;
  bool cancelled = false;
  bool fired = false;

  @override
  void cancel() => cancelled = true;
}

final class _Timers {
  final List<_RecordingTimer> started = [];

  NotificationTimer create(Duration delay, void Function() onFire) {
    final timer = _RecordingTimer(delay, onFire);
    started.add(timer);
    return timer;
  }

  void fire(_RecordingTimer timer) {
    if (timer.cancelled || timer.fired) return;
    timer.fired = true;
    timer.onFire();
  }

  void fireAll() {
    for (final timer in List<_RecordingTimer>.from(started)) {
      fire(timer);
    }
  }
}

final class _Presence implements NotificationTargetPresence {
  _Presence([Set<String> attached = const {}]) : attached = {...attached};

  final Set<String> attached;

  @override
  bool isInstanceAttached(String clientInstanceId) =>
      attached.contains(clientInstanceId.toLowerCase());
}

final class _Harness {
  _Harness({Set<String> attached = const {_desktopInstance}}) {
    presence = _Presence(attached);
    dispatcher = NotificationDispatcher(
      sink: instructions.add,
      presence: presence,
      profiles: profiles,
      sessionTitle: (sessionId) => sessionTitles[sessionId],
      timerFactory: timers.create,
      now: () => DateTime.utc(2026, 11, 13, 10),
      escalationDelay: NotificationDispatcher.defaultEscalationDelay,
    );
  }

  final List<NotificationInstructionMessage> instructions = [];
  final ClientInstanceProfiles profiles = ClientInstanceProfiles();
  final Map<String, String> sessionTitles = {'session-1': 'Fix the build'};
  final _Timers timers = _Timers();
  late final _Presence presence;
  late final NotificationDispatcher dispatcher;

  static const origin = OriginContext(
    platformFamily: PlatformFamily.sanadClient,
    transport: PlatformTransport.local,
    platformId: 'local-daemon',
    sessionId: 'session-1',
    clientInstanceId: _desktopInstance,
  );

  List<NotificationInstructionMessage> get dispatches => instructions
      .where((i) => i.eventType == 'notification.dispatch')
      .toList(growable: false);

  List<NotificationInstructionMessage> get withdrawals => instructions
      .where((i) => i.eventType == 'notification.withdraw')
      .toList(growable: false);

  Map<String, dynamic> notificationOf(NotificationInstructionMessage message) =>
      message.payload[NotificationWire.payloadKey] as Map<String, dynamic>;
}

NotificationAsk _ask({
  String requestId = 'request-1',
  String sessionId = 'session-1',
  NotificationKind kind = NotificationKind.permissionRequest,
  String excerpt = 'shell_execute: git status',
}) => NotificationAsk(
  sessionId: sessionId,
  requestId: requestId,
  eventId: 'evt-$requestId',
  kind: kind,
  excerpt: excerpt,
);

void main() {
  group('origin-first dispatch', () {
    test('a reachable origin is dispatched once and arms one timer', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

      expect(harness.dispatches, hasLength(1));
      final notification = harness.notificationOf(harness.dispatches.single);
      expect(notification['step'], 'origin');
      expect((notification['target'] as Map)['scope'], 'client_instance');
      expect(
        (notification['target'] as Map)['client_instance_id'],
        _desktopInstance,
      );
      expect(harness.timers.started, hasLength(1));
      expect(harness.timers.started.single.delay, const Duration(seconds: 90));
      expect(
        harness.dispatcher.isEscalationArmed(
          sessionId: 'session-1',
          requestId: 'request-1',
        ),
        isTrue,
      );
    });

    test('an unreachable origin reaches the account immediately', () {
      final harness = _Harness(attached: {_phoneInstance});
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

      expect(harness.dispatches, hasLength(1));
      final notification = harness.notificationOf(harness.dispatches.single);
      expect(notification['step'], 'immediate');
      expect((notification['target'] as Map)['scope'], 'account');
      expect(harness.timers.started, isEmpty);
    });

    test('a missing origin reaches the account immediately', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask());

      expect(harness.dispatches, hasLength(1));
      expect(
        harness.notificationOf(harness.dispatches.single)['step'],
        'immediate',
      );
      expect(harness.timers.started, isEmpty);
    });

    test('a CLI origin reaches the account immediately', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(
        ask: _ask(),
        origin: const OriginContext(
          platformFamily: PlatformFamily.cli,
          transport: PlatformTransport.cli,
          clientInstanceId: _desktopInstance,
        ),
      );

      expect(
        harness.notificationOf(harness.dispatches.single)['step'],
        'immediate',
      );
      expect(harness.timers.started, isEmpty);
    });
  });

  group('escalation timer', () {
    test('the 90-second expiry fans out to the account exactly once', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

      harness.timers.fireAll();
      harness.timers.fireAll();

      expect(harness.dispatches, hasLength(2));
      expect(
        harness.notificationOf(harness.dispatches.last)['step'],
        'escalation',
      );
      expect(
        (harness.notificationOf(harness.dispatches.last)['target']
            as Map)['scope'],
        'account',
      );
      // The timer never arms a second window for the same ask.
      expect(harness.timers.started, hasLength(1));
    });

    test('an immediate fan-out never arms a timer to escalate again', () {
      final harness = _Harness(attached: {_phoneInstance});
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);
      harness.timers.fireAll();

      expect(harness.dispatches, hasLength(1));
      expect(harness.timers.started, isEmpty);
    });

    test('duplicate creation is a no-op, so one ask keeps one timer', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

      expect(harness.dispatches, hasLength(1));
      expect(harness.timers.started, hasLength(1));
      expect(harness.dispatcher.pendingCount, 1);
    });

    test('two asks of one session each own one timer', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);
      harness.dispatcher.onAskCreated(
        ask: _ask(requestId: 'request-2'),
        origin: _Harness.origin,
      );

      expect(harness.timers.started, hasLength(2));
      expect(harness.dispatcher.pendingCount, 2);
    });
  });

  group('resolution and cancellation', () {
    test('resolution 10 seconds in prevents the fan-out and withdraws', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

      harness.dispatcher.onAskResolved(
        sessionId: 'session-1',
        requestId: 'request-1',
        reason: NotificationWithdrawReason.resolved,
      );
      harness.timers.fireAll();

      expect(harness.dispatches, hasLength(1));
      expect(harness.timers.started.single.cancelled, isTrue);
      expect(harness.withdrawals, hasLength(1));
      expect(
        harness.notificationOf(harness.withdrawals.single)['reason'],
        NotificationWithdrawReason.resolved,
      );
      expect(harness.dispatcher.pendingCount, 0);
    });

    test(
      'resolution after the fan-out withdraws once and never re-notifies',
      () {
        final harness = _Harness();
        harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);
        harness.timers.fireAll();

        harness.dispatcher.onAskResolved(
          sessionId: 'session-1',
          requestId: 'request-1',
          reason: NotificationWithdrawReason.alreadyResolved,
        );
        harness.dispatcher.onAskResolved(
          sessionId: 'session-1',
          requestId: 'request-1',
          reason: NotificationWithdrawReason.alreadyResolved,
        );

        expect(harness.dispatches, hasLength(2));
        expect(harness.withdrawals, hasLength(1));
      },
    );

    test('no notification is created for a key that is already resolved', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);
      harness.dispatcher.onAskResolved(
        sessionId: 'session-1',
        requestId: 'request-1',
        reason: NotificationWithdrawReason.resolved,
      );
      final dispatchesBefore = harness.dispatches.length;

      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

      expect(harness.dispatches, hasLength(dispatchesBefore));
      expect(harness.timers.started, hasLength(1));
    });

    test(
      'a terminal session state withdraws every live ask of the session',
      () {
        final harness = _Harness();
        harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);
        harness.dispatcher.onAskCreated(
          ask: _ask(requestId: 'request-2'),
          origin: _Harness.origin,
        );
        harness.dispatcher.onAskCreated(
          ask: _ask(requestId: 'request-3', sessionId: 'session-2'),
          origin: _Harness.origin,
        );

        harness.dispatcher.onSessionTerminal('session-1');

        expect(harness.withdrawals, hasLength(2));
        for (final withdrawal in harness.withdrawals) {
          expect(
            harness.notificationOf(withdrawal)['reason'],
            NotificationWithdrawReason.sessionTerminal,
          );
          expect(withdrawal.sessionId, 'session-1');
        }
        expect(harness.dispatcher.pendingCount, 1);
        for (final timer in harness.timers.started.take(2)) {
          expect(timer.cancelled, isTrue);
        }
      },
    );

    test(
      'dispose withdraws what is still tracked and cancels the timers',
      () async {
        final harness = _Harness();
        harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

        await harness.dispatcher.dispose();

        expect(harness.withdrawals, hasLength(1));
        expect(
          harness.notificationOf(harness.withdrawals.single)['reason'],
          NotificationWithdrawReason.disposed,
        );
        expect(harness.timers.started.single.cancelled, isTrue);
        expect(harness.dispatcher.pendingCount, 0);
      },
    );
  });

  group('copy, target and failure containment', () {
    test(
      'a registered Arabic locale renders Arabic with the title untouched',
      () {
        final harness = _Harness();
        harness.profiles.register(
          clientInstanceId: _desktopInstance,
          locale: 'ar',
        );

        harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

        final notification = harness.notificationOf(harness.dispatches.single);
        expect(notification['locale'], 'ar');
        expect(notification['title'], 'Fix the build');
        expect(notification['body'], contains('مطلوب موافقة'));
        final actions = notification['actions'] as List;
        expect((actions.first as Map)['label'], 'اسمح مرة واحدة');
      },
    );

    test('an unregistered locale falls back to English', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin);

      final notification = harness.notificationOf(harness.dispatches.single);
      expect(notification['locale'], 'en');
      expect(notification['title'], 'Fix the build');
    });

    test('the session title is resolved when the ask carries none', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(
        ask: NotificationAsk(
          sessionId: 'session-1',
          requestId: 'request-1',
          eventId: 'evt-1',
          kind: NotificationKind.userQuestion,
          excerpt: 'Which database?',
        ),
        origin: _Harness.origin,
      );

      expect(
        harness.notificationOf(harness.dispatches.single)['title'],
        'Fix the build',
      );
    });

    test('a Client-owned kind is never dispatched by the Agent', () {
      final harness = _Harness();
      harness.dispatcher.onAskCreated(
        ask: _ask(kind: NotificationKind.connectionLost),
        origin: _Harness.origin,
      );

      expect(harness.instructions, isEmpty);
      expect(harness.dispatcher.pendingCount, 0);
    });

    test('a throwing sink never reaches the ask and never leaks payload', () {
      var calls = 0;
      final dispatcher = NotificationDispatcher(
        sink: (_) {
          calls += 1;
          throw StateError('transport down');
        },
        presence: _Presence({_desktopInstance}),
        profiles: ClientInstanceProfiles(),
      );

      // The dispatch is attempted and contained; the waiter keeps its ask.
      expect(
        () => dispatcher.onAskCreated(ask: _ask(), origin: _Harness.origin),
        returnsNormally,
      );
      expect(calls, 1);
      expect(dispatcher.pendingCount, 1);
    });
  });
}
