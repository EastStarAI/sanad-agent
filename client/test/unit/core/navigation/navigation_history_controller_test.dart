import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';

void main() {
  late ConversationHistoryController controller;

  setUp(() {
    controller = ConversationHistoryController();
  });

  tearDown(() {
    controller.dispose();
  });

  group('initial state', () {
    test('current is null, stacks are empty', () {
      final snap = controller.snapshot;
      expect(snap.current, isNull);
      expect(snap.backStack, isEmpty);
      expect(snap.forwardStack, isEmpty);
      expect(snap.canGoBack, isFalse);
      expect(snap.canGoForward, isFalse);
    });
  });

  group('destination route encoding', () {
    test('encodes path and workspace identities without changing logical values', () {
      const destination = ConversationDestination.newConversation(
        deviceId: 'device/with space',
        workspaceId: '/repo/a & b#fragment',
      );

      final uri = Uri.parse(destination.routePath);
      expect(uri.pathSegments, ['conversations', 'device/with space', 'new']);
      expect(uri.queryParameters['workspace'], '/repo/a & b#fragment');
    });
  });

  group('navigateTo', () {
    test('sets current when no previous destination', () {
      final dest = ConversationDestination.newConversation(deviceId: 'd1');
      controller.navigateTo(dest);
      expect(controller.snapshot.current, dest);
      expect(controller.snapshot.backStack, isEmpty);
      expect(controller.snapshot.forwardStack, isEmpty);
    });

    test('pushes previous current to back stack', () {
      final dest1 = ConversationDestination.newConversation(deviceId: 'd1');
      final dest2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      controller.navigateTo(dest1);
      controller.navigateTo(dest2);

      final snap = controller.snapshot;
      expect(snap.current, dest2);
      expect(snap.backStack, [dest1]);
      expect(snap.forwardStack, isEmpty);
    });

    test('clears forward stack', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      final d3 = ConversationDestination.session(deviceId: 'd1', sessionId: 's2');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      controller.goBack(); // now back to d1, d2 in forward
      controller.navigateTo(d3); // should clear forward

      final snap = controller.snapshot;
      expect(snap.current, d3);
      expect(snap.backStack, [d1]);
      expect(snap.forwardStack, isEmpty);
    });

    test('is no-op when destination equals current', () {
      final dest = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      controller.navigateTo(dest);

      final snapBefore = controller.snapshot;
      controller.navigateTo(dest);
      final snapAfter = controller.snapshot;

      expect(snapAfter.backStack, snapBefore.backStack);
      expect(snapAfter.current, snapBefore.current);
      expect(snapAfter.forwardStack, snapBefore.forwardStack);
    });
  });

  group('goBack', () {
    test('returns null when back stack is empty', () {
      expect(controller.goBack(), isNull);
    });

    test('moves current to forward, pops back as current', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);

      final result = controller.goBack();
      expect(result, d1);

      final snap = controller.snapshot;
      expect(snap.current, d1);
      expect(snap.backStack, isEmpty);
      expect(snap.forwardStack, [d2]);
    });
  });

  group('goForward', () {
    test('returns null when forward stack is empty', () {
      expect(controller.goForward(), isNull);
    });

    test('moves current to back, pops forward as current', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      controller.goBack();

      final result = controller.goForward();
      expect(result, d2);

      final snap = controller.snapshot;
      expect(snap.current, d2);
      expect(snap.backStack, [d1]);
      expect(snap.forwardStack, isEmpty);
    });
  });

  group('back and forward round-trip', () {
    test('navigateTo → goBack → goForward restores original state', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      expect(controller.snapshot.current, d2);

      controller.goBack();
      expect(controller.snapshot.current, d1);

      controller.goForward();
      expect(controller.snapshot.current, d2);
      expect(controller.snapshot.canGoForward, isFalse);
    });
  });

  group('replaceCurrent', () {
    test('replaces current without affecting stacks', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      final d3 = ConversationDestination.session(deviceId: 'd1', sessionId: 's2');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      controller.replaceCurrent(d3);

      final snap = controller.snapshot;
      expect(snap.current, d3);
      expect(snap.backStack, [d1]);
      expect(snap.forwardStack, isEmpty);
    });
  });

  group('removeFromHistory', () {
    test('removes destination from back and forward stacks', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      final d3 = ConversationDestination.session(deviceId: 'd1', sessionId: 's2');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      controller.navigateTo(d3);
      controller.goBack(); // back to d2
      controller.goBack(); // back to d1

      // stacks: back=[], current=d1, forward=[d2, d3]
      controller.removeFromHistory(d2);

      final snap = controller.snapshot;
      expect(snap.current, d1);
      expect(snap.forwardStack, [d3]);
      expect(snap.backStack, isEmpty);
    });

    test('does not affect current even if matching', () {
      final dest = ConversationDestination.newConversation(deviceId: 'd1');
      controller.navigateTo(dest);
      controller.removeFromHistory(dest);

      expect(controller.snapshot.current, dest);
    });
  });

  group('removeSessionFromHistory', () {
    test('removes session destinations by device and session id', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final s1 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      final s2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's2');

      controller.navigateTo(d1);
      controller.navigateTo(s1);
      controller.navigateTo(s2);
      controller.goBack();

      // stacks: back=[d1, s1], current=s2, forward=[]
      controller.removeSessionFromHistory('d1', 's1');

      expect(controller.snapshot.backStack, [d1]);
    });
  });

  group('findPreviousSameDevice', () {
    test('finds last same-device destination in back stack', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.newConversation(deviceId: 'd2');
      final s1 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      controller.navigateTo(s1);

      // back=[d1, d2], current=s1
      final found = controller.findPreviousSameDevice('d1');
      expect(found, d1);
    });

    test('returns null when no same-device destination in back stack', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.newConversation(deviceId: 'd2');

      controller.navigateTo(d1);
      controller.navigateTo(d2);

      expect(controller.findPreviousSameDevice('d3'), isNull);
    });
  });

  group('findForwardSameDevice', () {
    test('finds first same-device destination in forward stack', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final s1 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      final s2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's2');
      final d2 = ConversationDestination.newConversation(deviceId: 'd2');

      controller.navigateTo(d1);
      controller.navigateTo(s1);
      controller.navigateTo(s2);
      controller.navigateTo(d2);
      controller.goBack(); // back to s2
      controller.goBack(); // back to s1

      // back=[d1], current=s1, forward=[s2, d2]
      final found = controller.findForwardSameDevice('d1');
      expect(found, s2);
    });

    test('returns null when no same-device destination in forward stack', () {
      expect(controller.findForwardSameDevice('d1'), isNull);
    });
  });

  group('consuming deletion fallbacks', () {
    test('takes previous valid destination and prunes invalid entries', () {
      final valid = ConversationDestination.session(deviceId: 'd1', sessionId: 'valid');
      final invalid = ConversationDestination.session(deviceId: 'd1', sessionId: 'deleted');
      final current = ConversationDestination.session(deviceId: 'd1', sessionId: 'current');
      controller
        ..navigateTo(valid)
        ..navigateTo(invalid)
        ..navigateTo(current);

      final fallback = controller.takePreviousSameDevice(
        'd1',
        isValid: (destination) => destination.sessionId == 'valid',
      );

      expect(fallback, valid);
      expect(controller.snapshot.backStack, isEmpty);
    });

    test('takes forward destination without leaving a duplicate', () {
      final first = ConversationDestination.session(deviceId: 'd1', sessionId: 'first');
      final second = ConversationDestination.session(deviceId: 'd1', sessionId: 'second');
      controller
        ..navigateTo(first)
        ..navigateTo(second)
        ..goBack();

      expect(controller.takeForwardSameDevice('d1'), second);
      expect(controller.snapshot.forwardStack, isEmpty);
    });
  });

  group('setInitial', () {
    test('sets current without affecting stacks', () {
      final dest = ConversationDestination.newConversation(deviceId: 'd1');
      controller.setInitial(dest);

      final snap = controller.snapshot;
      expect(snap.current, dest);
      expect(snap.backStack, isEmpty);
      expect(snap.forwardStack, isEmpty);
    });
  });

  group('clear', () {
    test('resets current and stacks', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      controller.clear();

      final snap = controller.snapshot;
      expect(snap.current, isNull);
      expect(snap.backStack, isEmpty);
      expect(snap.forwardStack, isEmpty);
    });
  });

  group('stream changes', () {
    test('emits snapshot on navigateTo', () async {
      final changes = <NavigationHistorySnapshot>[];
      final sub = controller.changes.listen(changes.add);

      // Let stream settle after initial constructor emission (which is lost)
      await Future.microtask(() {});

      final dest = ConversationDestination.newConversation(deviceId: 'd1');
      controller.navigateTo(dest);

      await Future.microtask(() {});
      expect(changes.length, 1); // only navigateTo (initial was lost)
      expect(changes.last.current, dest);

      unawaited(sub.cancel());
    });

    test('emits snapshot on goBack', () async {
      final changes = <NavigationHistorySnapshot>[];
      final sub = controller.changes.listen(changes.add);

      await Future.microtask(() {}); // settle

      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      controller.navigateTo(d1);
      await Future.microtask(() {});
      controller.navigateTo(d2);
      await Future.microtask(() {});

      final beforeBack = changes.length;
      controller.goBack();

      await Future.microtask(() {});
      expect(changes.length, beforeBack + 1);
      expect(changes.last.current, d1);

      unawaited(sub.cancel());
    });

    test('does not emit when navigateTo is no-op (duplicate)', () async {
      final changes = <NavigationHistorySnapshot>[];
      final sub = controller.changes.listen(changes.add);

      await Future.microtask(() {}); // settle

      final dest = ConversationDestination.newConversation(deviceId: 'd1');
      controller.navigateTo(dest);
      await Future.microtask(() {});

      final beforeDup = changes.length;
      controller.navigateTo(dest); // duplicate - no-op

      await Future.microtask(() {});
      expect(changes.length, beforeDup);

      unawaited(sub.cancel());
    });
  });

  group('cross-device navigation', () {
    test('navigateTo switches device context', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'device-a');
      final d2 = ConversationDestination.session(deviceId: 'device-b', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);

      final snap = controller.snapshot;
      expect(snap.current, d2);
      expect(snap.backStack, [d1]);
    });

    test('goBack across devices restores previous device context', () {
      final d1 = ConversationDestination.newConversation(deviceId: 'device-a');
      final d2 = ConversationDestination.session(deviceId: 'device-b', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);
      controller.goBack();

      expect(controller.snapshot.current, d1);
    });
  });

  group('reconcile', () {
    test('takes the first externally applied route as the initial destination', () {
      final dest = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      expect(controller.reconcile(dest), NavigationReconciliation.setInitial);
      expect(controller.snapshot.current, dest);
      expect(controller.snapshot.backStack, isEmpty);
      expect(controller.snapshot.forwardStack, isEmpty);
    });

    test('is a no-op when the route already describes the current destination', () {
      final dest = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      controller.setInitial(dest);

      expect(controller.reconcile(dest), NavigationReconciliation.noop);
      expect(controller.snapshot.backStack, isEmpty);
      expect(controller.snapshot.forwardStack, isEmpty);
    });

    test('follows the existing back and forward stacks instead of appending', () {
      final d1 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's2');
      controller
        ..navigateTo(d1)
        ..navigateTo(d2);

      expect(controller.reconcile(d1), NavigationReconciliation.goBack);
      expect(controller.snapshot.current, d1);
      expect(controller.snapshot.forwardStack, [d2]);
      expect(controller.snapshot.backStack, isEmpty);

      expect(controller.reconcile(d2), NavigationReconciliation.goForward);
      expect(controller.snapshot.current, d2);
      expect(controller.snapshot.backStack, [d1]);
      expect(controller.snapshot.forwardStack, isEmpty);
    });

    test('navigates when the route belongs to neither stack', () {
      final d1 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's2');
      controller.navigateTo(d1);

      expect(controller.reconcile(d2), NavigationReconciliation.navigateTo);
      expect(controller.snapshot.current, d2);
      expect(controller.snapshot.backStack, [d1]);
    });
  });

  group('GoRouterHistorySync', () {
    // Unit-level GoRouterHistorySync tests require a GoRouter instance.
    // These test the reconciliation logic indirectly through the controller.

    test('canGoBack and canGoForward reflect stack state', () {
      expect(controller.snapshot.canGoBack, isFalse);
      expect(controller.snapshot.canGoForward, isFalse);

      final d1 = ConversationDestination.newConversation(deviceId: 'd1');
      final d2 = ConversationDestination.session(deviceId: 'd1', sessionId: 's1');

      controller.navigateTo(d1);
      controller.navigateTo(d2);

      expect(controller.snapshot.canGoBack, isTrue);
      expect(controller.snapshot.canGoForward, isFalse);

      controller.goBack();

      expect(controller.snapshot.canGoBack, isFalse);
      expect(controller.snapshot.canGoForward, isTrue);
    });
  });
}
