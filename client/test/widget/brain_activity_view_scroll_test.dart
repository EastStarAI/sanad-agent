import 'dart:async';

import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/screens/brain_activity_view.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_device_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late DeviceCapabilitiesStore capabilities;
  late DeviceConnectionCoordinator resolver;
  late FakeConversationRepository conversationRepository;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit sessionMessagesCubit;
  late DeviceConfig agent;
  late StreamController<List<CanonicalEvent>> messagesController;

  setUp(() {
    socket = FakeSanadSocketService();
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilities = DeviceCapabilitiesStore(resolver);
    conversationRepository = FakeConversationRepository();
    agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    sessionMessagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    messagesController = StreamController<List<CanonicalEvent>>.broadcast();
  });

  tearDown(() async {
    await messagesController.close();
    await sessionMessagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    socket.dispose();
  });

  testWidgets('missing saved anchor falls back to the last user message without building all history', (tester) async {
    final messages = [
      for (var i = 0; i < 1000; i += 1) _event('old-$i', EventKind.finalAnswer, 'old answer $i'),
      _event('last-user', EventKind.userMessage, 'last user prompt'),
      _event('answer-after-last-user', EventKind.finalAnswer, 'answer after last user'),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      initialViewportAnchorEventId: 'missing-event',
    );
    await tester.pump();

    expect(find.text('last user prompt'), findsOneWidget);
    expect(find.text('old answer 0'), findsNothing);
  });

  testWidgets('prepending an older page preserves the visible anchor pixel', (tester) async {
    final tail = [
      _event('current-user', EventKind.userMessage, 'current prompt'),
      _event('current-answer', EventKind.finalAnswer, _lines(30)),
    ];
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: tail,
      initialViewportAnchorEventId: 'current-user',
    );
    await tester.pump();
    final before = tester.getTopLeft(find.text('current prompt')).dy;

    messagesController.add([
      _event('older-user', EventKind.userMessage, 'older prompt'),
      _event('older-answer', EventKind.finalAnswer, _lines(20)),
      ...tail,
    ]);
    await tester.pump();
    await tester.pump();

    final after = tester.getTopLeft(find.text('current prompt')).dy;
    expect(after, moreOrLessEquals(before, epsilon: 1));
  });

  testWidgets('older page arriving during upward scroll preserves the visible event', (tester) async {
    final tail = [
      for (var i = 0; i < 30; i += 1) _event('tail-$i', EventKind.finalAnswer, _lines(4)),
    ];
    final older = [
      for (var i = 0; i < 30; i += 1) _event('older-$i', EventKind.finalAnswer, _lines(4)),
    ];
    final notifier = ValueNotifier<List<CanonicalEvent>>(tail);
    final releasePage = Completer<void>();
    var calls = 0;

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: notifier.value,
      messagesNotifier: notifier,
      followLatestOnOpen: true,
      hasOlderHistory: true,
      onLoadOlderHistory: () async {
        calls += 1;
        await releasePage.future;
        notifier.value = [...older, ...tail];
      },
    );
    await tester.pump();
    await tester.pump();

    for (var attempt = 0; attempt < 10 && calls == 0; attempt += 1) {
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, 500),
      );
      await tester.pump();
    }
    expect(calls, 1);
    final visible = _topVisibleKnownEvent(tester, tail.map((event) => event.id));
    final before = tester.getTopLeft(find.byKey(ValueKey(visible))).dy;

    releasePage.complete();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(ValueKey(visible)), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(ValueKey(visible))).dy,
      moreOrLessEquals(before, epsilon: 1),
    );
    expect(
      _timelineController(tester).offset,
      isNot(
        moreOrLessEquals(
          _timelineController(tester).position.maxScrollExtent,
          epsilon: 1,
        ),
      ),
    );
    notifier.dispose();
  });

  testWidgets('an anchored response reopens the saved event at the visible top', (tester) async {
    const anchorId = 'history:session-1:42:user_message:0';
    final notifier = ValueNotifier<List<CanonicalEvent>>([
      _event('tail-user', EventKind.userMessage, 'tail prompt'),
    ]);

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: notifier.value,
      messagesNotifier: notifier,
      initialViewportAnchorEventId: anchorId,
      onLoadAnchoredHistory: (_) async {
        notifier.value = [
          _event('history:session-1:41:final_answer:0', EventKind.finalAnswer, _lines(20)),
          _event(anchorId, EventKind.userMessage, 'restored prompt'),
          _event('history:session-1:43:final_answer:0', EventKind.finalAnswer, _lines(10)),
        ];
      },
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('restored prompt'), findsOneWidget);
    expect(tester.getTopLeft(find.text('restored prompt')).dy, lessThan(160));
  });

  testWidgets('requests a missing saved anchor once before falling back', (tester) async {
    final requestedAnchors = <String>[];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: [
        _event('tail-user', EventKind.userMessage, 'tail prompt'),
      ],
      initialViewportAnchorEventId: 'history:session-1:42:user_message:0',
      onLoadAnchoredHistory: (eventId) async {
        requestedAnchors.add(eventId);
      },
    );
    await tester.pump();
    await tester.pump();

    expect(requestedAnchors, ['history:session-1:42:user_message:0']);
  });

  testWidgets('a short first page auto-fills once without a request loop', (tester) async {
    var calls = 0;
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: [
        _event('short-user', EventKind.userMessage, 'short prompt'),
      ],
      hasOlderHistory: true,
      onLoadOlderHistory: () async {
        calls += 1;
      },
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(calls, 1);
  });

  testWidgets('upward overscroll prefetches older history without a visible control', (tester) async {
    var calls = 0;
    final messages = [
      _event('user-1', EventKind.userMessage, 'current prompt'),
      _event('answer-1', EventKind.finalAnswer, _lines(100)),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      initialViewportAnchorEventId: 'user-1',
      hasOlderHistory: true,
      onLoadOlderHistory: () async {
        calls += 1;
      },
    );
    await tester.pump();

    expect(find.text('Show earlier'), findsNothing);
    expect(find.text('Retry earlier messages'), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('offline overscroll retries stop after three consecutive failures', (tester) async {
    final status = ValueNotifier<(bool, String?)>((false, 'offline'));
    var calls = 0;

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: SizedBox(
        width: 800,
        height: 600,
        child: ValueListenableBuilder<(bool, String?)>(
          valueListenable: status,
          builder: (_, pagination, _) => BrainActivityView(
            messagesStream: null,
            initialMessages: [
              _event('offline-anchor', EventKind.userMessage, 'offline prompt'),
              _event('offline-answer', EventKind.finalAnswer, _lines(100)),
            ],
            onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
            sessionId: 'offline-session',
            initialViewportAnchorEventId: 'offline-anchor',
            hasOlderHistory: true,
            isOlderHistoryLoading: pagination.$1,
            olderHistoryError: pagination.$2,
            onLoadOlderHistory: () async {
              calls += 1;
              status.value = (true, null);
            },
            visualState: ConversationVisualState.activeSession,
          ),
        ),
      ),
    );
    await tester.pump();

    for (var attempt = 0; attempt < 4; attempt += 1) {
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, 500),
      );
      await tester.pump();
      if (status.value.$1) {
        status.value = (false, 'offline');
        await tester.pump();
      }
    }

    expect(calls, 3);
    expect(find.text('Retry earlier messages'), findsNothing);

    status.value = (false, null);
    await tester.pump();
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, 500),
    );
    await tester.pump();
    expect(calls, 4, reason: 'authoritative recovery resets the retry budget');
    status.dispose();
  });

  testWidgets('short anchored page auto-fills newer history before any control is visible', (tester) async {
    var calls = 0;
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: [
        _event('anchor', EventKind.userMessage, 'restored prompt'),
      ],
      initialViewportAnchorEventId: 'anchor',
      hasNewerHistory: true,
      onLoadNewerHistory: () async {
        calls += 1;
      },
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Show later'), findsNothing);
    expect(find.text('Retry later messages'), findsNothing);
    expect(calls, 1);
  });

  testWidgets('forked session opens at the trailing fork marker', (tester) async {
    final messages = [
      for (var i = 0; i < 1000; i += 1) _event('fork-old-$i', EventKind.finalAnswer, 'fork old answer $i'),
      CanonicalEvent(
        id: 'fork_child-1',
        kind: EventKind.informational,
        text: 'Conversation forked',
        timestamp: DateTime.utc(2026, 8, 31),
        metadata: const {
          'informational_kind': 'session_fork',
          'fork_sequence': 1,
        },
      ),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      initialViewportAnchorEventId: 'fork-old-0',
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Conversation forked'), findsOneWidget);
    expect(find.text('fork old answer 0'), findsNothing);
    expect(
      _eventBottom(tester, 'fork_child-1'),
      lessThanOrEqualTo(_visibleTimelineBottom(tester)),
    );
  });

  testWidgets('restores a saved event for an idle session', (tester) async {
    final messages = [
      for (var i = 0; i < 1000; i += 1) _event('old-$i', EventKind.finalAnswer, 'old answer $i'),
      _event('saved-anchor', EventKind.finalAnswer, 'resume reading here'),
      _event('last-user', EventKind.userMessage, 'latest user prompt'),
      _event('latest-answer', EventKind.finalAnswer, 'latest answer'),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      initialViewportAnchorEventId: 'saved-anchor',
    );
    await tester.pump();

    expect(find.text('resume reading here'), findsOneWidget);
    expect(find.text('old answer 0'), findsNothing);
  });

  testWidgets('active work ignores a saved anchor and opens at the latest event', (
    tester,
  ) async {
    final messages = [
      _event('saved-anchor', EventKind.finalAnswer, 'stale reading position'),
      for (var i = 0; i < 1000; i += 1) _event('middle-$i', EventKind.finalAnswer, 'middle answer $i'),
      _event('latest-event', EventKind.thinking, 'latest active progress'),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      initialViewportAnchorEventId: 'saved-anchor',
      followLatestOnOpen: true,
    );
    expect(
      find.byKey(const Key('chat_messages_list')),
      findsNothing,
      reason: 'the timeline must not paint against an estimated composer height',
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('latest active progress'), findsOneWidget);
    expect(find.text('stale reading position'), findsNothing);

    final latestBottom = tester.getBottomLeft(find.byKey(const ValueKey('latest-event'))).dy;
    final composerTop = tester.getTopLeft(find.byType(ConversationInputPanel)).dy;
    expect(latestBottom, lessThanOrEqualTo(composerTop));
    expect(
      composerTop - latestBottom,
      lessThan(40),
      reason: 'active work should open at the visible tail above the composer',
    );
  });

  testWidgets('short active work opens at the top without a transient bottom frame', (tester) async {
    final messages = [
      _event('short-first', EventKind.finalAnswer, 'short active answer'),
      _event('short-latest', EventKind.thinking, 'brief active progress'),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      followLatestOnOpen: true,
    );
    await tester.pump();

    final hiddenTimeline = find.ancestor(
      of: find.byKey(const Key('chat_messages_list')),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(hiddenTimeline.first).opacity, 0);

    await tester.pump();

    expect(tester.widget<Opacity>(hiddenTimeline.first).opacity, 1);
    expect(tester.getTopLeft(find.byKey(const ValueKey('short-first'))).dy, lessThan(140));
    expect(_eventBottom(tester, 'short-latest'), lessThan(_visibleTimelineBottom(tester) - 100));
    expect(_timelineController(tester).position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('eligible short active work follows only after growth reaches the composer', (tester) async {
    final initialMessages = [
      _event('active-first', EventKind.finalAnswer, 'short active answer'),
    ];
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: initialMessages,
      followLatestOnOpen: true,
    );
    await tester.pump();
    await tester.pump();

    final controller = _timelineController(tester);
    final initialOffset = controller.offset;
    final shortUpdate = _event('short-update', EventKind.informational, 'still short');
    messagesController.add([...initialMessages, shortUpdate]);
    await tester.pump();
    await tester.pump();

    expect(controller.offset, moreOrLessEquals(initialOffset, epsilon: 1));

    messagesController.add([
      ...initialMessages,
      shortUpdate,
      _event('filling-update', EventKind.finalAnswer, _lines(50)),
    ]);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(controller.offset, moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('first message in an empty timeline remains top-anchored without follow', (tester) async {
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: const [],
    );
    await tester.pump();

    final firstUser = _event('first-user', EventKind.userMessage, 'first prompt at top');
    messagesController.add([firstUser]);
    await tester.pump();
    await tester.pump();

    final initialTop = tester.getTopLeft(find.byKey(const ValueKey('first-user'))).dy;
    expect(initialTop, lessThan(140));

    messagesController.add([
      firstUser,
      _event('long-reasoning', EventKind.reasoning, _lines(50)),
    ]);
    await tester.pump();
    await tester.pump();

    final controller = _timelineController(tester);
    expect(tester.getTopLeft(find.byKey(const ValueKey('first-user'))).dy, moreOrLessEquals(initialTop, epsilon: 1));
    expect(controller.offset, moreOrLessEquals(0, epsilon: 1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('a fully visible new user message does not move the timeline', (tester) async {
    final messages = [
      _event('user-1', EventKind.userMessage, 'existing prompt'),
      _event('answer-1', EventKind.finalAnswer, 'short existing answer'),
    ];
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
    );
    await tester.pump();

    final controller = _timelineController(tester);
    final previousOffset = controller.offset;
    messagesController.add([
      ...messages,
      _event('visible-user', EventKind.userMessage, 'already visible prompt'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(_eventBottom(tester, 'visible-user'), lessThanOrEqualTo(_visibleTimelineBottom(tester) + 0.5));
    expect(controller.offset, moreOrLessEquals(previousOffset, epsilon: 0.5));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('a partially obscured user message moves only enough to clear the composer', (tester) async {
    final messages = [
      _event('user-1', EventKind.userMessage, 'existing prompt'),
      for (var i = 0; i < 12; i += 1)
        _event('answer-$i', EventKind.finalAnswer, 'existing answer $i\nwith another line'),
    ];
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      followLatestOnOpen: true,
    );
    await tester.pump();

    final controller = _timelineController(tester);
    final previousOffset = controller.offset;
    messagesController.add([
      ...messages,
      _event('partial-user', EventKind.userMessage, 'reveal only this prompt'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(controller.offset, greaterThan(previousOffset));
    expect(_eventBottom(tester, 'partial-user'), moreOrLessEquals(_visibleTimelineBottom(tester), epsilon: 1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('widget-state updates never re-anchor a new user message to the top', (tester) async {
    final messages = [
      _event('user-1', EventKind.userMessage, 'existing prompt'),
      for (var i = 0; i < 20; i += 1)
        _event('answer-$i', EventKind.finalAnswer, 'existing answer $i\nwith another line'),
    ];
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      followLatestOnOpen: true,
    );
    await tester.pump();
    await tester.pump();

    final newUser = _event('prop-update-user', EventKind.userMessage, 'must stay above the composer');
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: [...messages, newUser],
      followLatestOnOpen: true,
    );
    await tester.pump();
    await tester.pump();

    final userTop = tester.getTopLeft(find.byKey(const ValueKey('prop-update-user'))).dy;
    expect(userTop, greaterThan(140), reason: 'only the first message of an empty timeline may be top-anchored');
    expect(_eventBottom(tester, 'prop-update-user'), moreOrLessEquals(_visibleTimelineBottom(tester), epsilon: 1));
    expect(_timelineController(tester).position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('a user message is minimally revealed then grants follow for streamed growth', (tester) async {
    final messages = [
      _event('anchor-user', EventKind.userMessage, 'reading starts here'),
      for (var i = 0; i < 18; i += 1)
        _event('answer-$i', EventKind.finalAnswer, 'existing answer $i\nwith another line'),
    ];
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
    );
    await tester.pump();

    final newUser = _event('below-user', EventKind.userMessage, 'prompt initially below the viewport');
    final trailing = _event('trailing-info', EventKind.informational, _lines(12));
    messagesController.add([...messages, newUser, trailing]);
    for (var i = 0; i < 8; i += 1) {
      await tester.pump();
    }

    final controller = _timelineController(tester);
    expect(find.byKey(const ValueKey('below-user')), findsOneWidget);
    expect(_eventBottom(tester, 'below-user'), moreOrLessEquals(_visibleTimelineBottom(tester), epsilon: 1));
    expect(controller.offset, lessThan(controller.position.maxScrollExtent - 1));
    final revealOffset = controller.offset;

    messagesController.add([
      ...messages,
      newUser,
      trailing,
      _event('reasoning-after-reveal', EventKind.reasoning, _lines(20)),
    ]);
    await tester.pump();
    await tester.pump();

    expect(controller.offset, greaterThan(revealOffset));
    expect(
      controller.offset,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1),
    );
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('manual scrolling records a visible event anchor', (tester) async {
    final recordedAnchors = <String>[];
    final messages = [
      for (var i = 0; i < 30; i += 1)
        _event('event-$i', EventKind.finalAnswer, 'message ${List.filled(8, i).join(' ')}'),
      _event('last-user', EventKind.userMessage, 'latest user prompt'),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      onViewportAnchorChanged: recordedAnchors.add,
    );
    await tester.pump();
    expect(recordedAnchors, isEmpty);

    await tester.drag(
      find.byKey(const Key('chat_messages_list')),
      const Offset(0, 300),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(recordedAnchors, isNotEmpty);
    expect(messages.map((event) => event.id), contains(recordedAnchors.last));
  });

  testWidgets('switching idle sessions restores each saved visible event independently', (tester) async {
    final sessionOne = [
      for (var i = 0; i < 40; i += 1) _event('session-one-$i', EventKind.finalAnswer, _lines(4)),
    ];
    final sessionTwo = [
      for (var i = 0; i < 40; i += 1) _event('session-two-$i', EventKind.finalAnswer, _lines(4)),
    ];
    final anchors = <String, String>{
      'session-one': 'session-one-20',
      'session-two': 'session-two-10',
    };
    final selected = ValueNotifier<(String, List<CanonicalEvent>)>(
      ('session-one', sessionOne),
    );

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: SizedBox(
        width: 800,
        height: 600,
        child: ValueListenableBuilder<(String, List<CanonicalEvent>)>(
          valueListenable: selected,
          builder: (_, fixture, _) => BrainActivityView(
            messagesStream: null,
            initialMessages: fixture.$2,
            onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
            sessionId: fixture.$1,
            initialViewportAnchorEventId: anchors[fixture.$1],
            onViewportAnchorChanged: (eventId) {
              anchors[fixture.$1] = eventId;
            },
            visualState: ConversationVisualState.activeSession,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('chat_messages_list')),
      const Offset(0, 300),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final savedSessionOne = anchors['session-one']!;

    selected.value = ('session-two', sessionTwo);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(ValueKey(anchors['session-two']!)),
      findsOneWidget,
    );

    selected.value = ('session-one', sessionOne);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(ValueKey(savedSessionOne)), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(ValueKey(savedSessionOne))).dy,
      lessThan(180),
    );
    selected.dispose();
  });

  testWidgets('manual opt-out survives reasoning tool final and informational events until manual return', (
    tester,
  ) async {
    final thinking = CanonicalEvent(
      id: 'manual-opt-out-thinking',
      kind: EventKind.thinking,
      status: EventStatus.running,
      text: _lines(20),
      timestamp: DateTime(2026, 1, 1),
    );
    final messages = [
      _event('user-1', EventKind.userMessage, 'current prompt'),
      for (var i = 0; i < 20; i += 1) _event('answer-$i', EventKind.finalAnswer, 'answer $i\nwith another line'),
      thinking,
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      followLatestOnOpen: true,
    );
    await tester.pump();

    final controller = _timelineController(tester);
    await tester.drag(find.byKey(const Key('chat_messages_list')), const Offset(0, 300));
    await tester.pumpAndSettle();
    final manualOffset = controller.offset;

    final updates = <CanonicalEvent>[
      _event('reasoning-event', EventKind.reasoning, _lines(16)),
      CanonicalEvent(
        id: 'tool-event',
        kind: EventKind.toolCall,
        text: 'tool result',
        tool: const {'name': 'shell', 'input': <String, dynamic>{}, 'output': 'ok'},
        timestamp: DateTime(2026, 1, 1),
      ),
      _event('final-event', EventKind.finalAnswer, _lines(12)),
      _event('runtime-event', EventKind.informational, 'runtime route updated'),
    ];
    final streamed = [...messages];
    for (final event in updates) {
      streamed.add(event);
      messagesController.add([...streamed]);
      await tester.pump();
      await tester.pump();
      expect(controller.offset, moreOrLessEquals(manualOffset, epsilon: 1));
    }
    expect(controller.offset, lessThan(controller.position.maxScrollExtent - 1));

    await tester.drag(find.byKey(const Key('chat_messages_list')), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(controller.offset, moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1));

    streamed.add(_event('post-return-answer', EventKind.finalAnswer, _lines(20)));
    messagesController.add([...streamed]);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(controller.offset, moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('session navigation cancels an inline message edit', (tester) async {
    final messages = [
      CanonicalEvent(
        id: 'editable-user',
        kind: EventKind.userMessage,
        text: 'editable prompt',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {
          'request_id': 'request-editable',
          'message_id': 'message-editable',
          'turn_id': 'turn-editable',
          'input_kind': 'root_turn',
          'replay_eligible': true,
        },
      ),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      sessionId: 'session-1',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pump();
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: messages,
      sessionId: 'session-2',
    );
    await tester.pump();

    expect(find.byKey(const Key('inline_message_editor')), findsNothing);
    expect(find.text('editable prompt'), findsOneWidget);
  });

  testWidgets('completed compaction hides replay actions for earlier messages', (
    tester,
  ) async {
    CanonicalEvent replayableUser(String id, DateTime timestamp) => CanonicalEvent(
      id: id,
      kind: EventKind.userMessage,
      text: id,
      timestamp: timestamp,
      metadata: {
        'request_id': 'request-$id',
        'message_id': 'message-$id',
        'turn_id': 'turn-$id',
        'input_kind': 'root_turn',
        'replay_eligible': true,
      },
    );
    final failedCompaction = CanonicalEvent(
      id: 'failed-compaction',
      kind: EventKind.informational,
      status: EventStatus.error,
      text: 'Context compaction failed',
      timestamp: DateTime.utc(2026, 7, 18, 0, 1),
      metadata: const {
        'compaction_event': true,
        'compaction_status': 'failed',
      },
    );
    final compaction = CanonicalEvent(
      id: 'compaction',
      kind: EventKind.informational,
      status: EventStatus.done,
      text: 'Context compacted',
      timestamp: DateTime.utc(2026, 7, 18, 0, 1),
      metadata: const {
        'compaction_event': true,
        'compaction_status': 'completed',
      },
    );

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: [
        replayableUser('before-compaction', DateTime.utc(2026, 7, 18)),
        failedCompaction,
      ],
    );
    await tester.pump();

    expect(find.byTooltip('Edit message'), findsOneWidget);
    expect(find.byTooltip('Retry message'), findsOneWidget);

    messagesController.add([
      replayableUser('before-compaction', DateTime.utc(2026, 7, 18)),
      failedCompaction,
      compaction,
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Edit message'), findsNothing);
    expect(find.byTooltip('Retry message'), findsNothing);

    messagesController.add([
      replayableUser('before-compaction', DateTime.utc(2026, 7, 18)),
      failedCompaction,
      compaction,
      replayableUser('after-compaction', DateTime.utc(2026, 7, 18, 0, 2)),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('Edit message'), findsOneWidget);
    expect(find.byTooltip('Retry message'), findsOneWidget);
  });

  testWidgets('followed thinking and final answer growth minimally clears the composer', (tester) async {
    final thinking = CanonicalEvent(
      id: 'thinking-step-1',
      kind: EventKind.thinking,
      status: EventStatus.running,
      text: _lines(12),
      timestamp: DateTime(2026, 1, 1),
      sessionId: 'session-1',
      runId: 'run-1',
      modelStepId: 'step-1',
    );
    final initialMessages = [
      _event('user-1', EventKind.userMessage, 'current prompt'),
      for (var i = 0; i < 16; i += 1) _event('answer-$i', EventKind.finalAnswer, 'answer $i\nwith another line'),
      thinking,
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: initialMessages,
      followLatestOnOpen: true,
    );
    await tester.pump();
    await tester.pump();

    final controller = _timelineController(tester);
    final initialOffset = controller.offset;
    final expandedThinking = thinking.copyWith(text: _lines(30));
    final messagesWithExpandedThinking = [
      ...initialMessages.sublist(0, initialMessages.length - 1),
      expandedThinking,
    ];

    messagesController.add(messagesWithExpandedThinking);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('line 30'), findsOneWidget);
    expect(controller.offset, greaterThan(initialOffset));
    expect(_eventBottom(tester, 'thinking-step-1'), moreOrLessEquals(_visibleTimelineBottom(tester), epsilon: 1));

    final finalAnswer = _event('streaming-final', EventKind.finalAnswer, _lines(8));
    messagesController.add([...messagesWithExpandedThinking, finalAnswer]);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    final finalInitialOffset = controller.offset;
    final finalInitialMaxExtent = controller.position.maxScrollExtent;

    messagesController.add([
      ...messagesWithExpandedThinking,
      finalAnswer.copyWith(text: _lines(30)),
    ]);
    await tester.pump();
    await tester.pump();

    expect(controller.position.maxScrollExtent, greaterThan(finalInitialMaxExtent));
    expect(controller.offset, greaterThan(finalInitialOffset));
    expect(_eventBottom(tester, 'streaming-final'), moreOrLessEquals(_visibleTimelineBottom(tester), epsilon: 1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('new agent events animate visually without moving the viewport', (tester) async {
    final initialMessages = [
      _event('user-1', EventKind.userMessage, 'current prompt'),
    ];
    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: initialMessages,
    );
    await tester.pump();

    final controller = _timelineController(tester);
    final initialOffset = controller.offset;
    final agentEvent = _event('animated-agent', EventKind.finalAnswer, 'new agent answer');
    messagesController.add([...initialMessages, agentEvent]);
    await tester.pump();

    final entrance = find.byKey(const ValueKey('agent-event-entrance:animated-agent'));
    final fade = find.descendant(
      of: entrance,
      matching: find.byWidgetPredicate(
        (widget) => widget is FadeTransition && widget.child is SlideTransition,
      ),
    );
    expect(tester.widget<FadeTransition>(fade).opacity.value, lessThan(1));
    expect(controller.offset, moreOrLessEquals(initialOffset, epsilon: 1));

    await tester.pump(const Duration(milliseconds: 110));
    final midpointOpacity = tester.widget<FadeTransition>(fade).opacity.value;
    expect(midpointOpacity, allOf(greaterThan(0), lessThan(1)));
    expect(controller.offset, moreOrLessEquals(initialOffset, epsilon: 1));

    await tester.pump(const Duration(milliseconds: 220));
    expect(fade, findsNothing, reason: 'completed events must leave opacity compositing');
    expect(find.descendant(of: entrance, matching: find.byType(SlideTransition)), findsNothing);

    final copyButton = find.descendant(of: entrance, matching: find.byTooltip('Copy'));
    final copyRect = tester.getRect(copyButton);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: copyRect.center);
    await tester.pump();
    expect(tester.getRect(copyButton), copyRect);

    messagesController.add([
      ...initialMessages,
      agentEvent.copyWith(text: 'updated existing event'),
    ]);
    await tester.pump();
    expect(fade, findsNothing);
    expect(tester.getRect(copyButton), copyRect);
    expect(controller.offset, moreOrLessEquals(initialOffset, epsilon: 1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
    await mouse.removePointer();
  });

  testWidgets('active follow animates a new agent event over 280ms', (tester) async {
    final initialMessages = [
      _event('user-1', EventKind.userMessage, 'current prompt'),
      for (var i = 0; i < 16; i += 1) _event('answer-$i', EventKind.finalAnswer, 'answer $i\nwith another line'),
      _event('active-tail', EventKind.informational, 'active tail'),
    ];

    await _pumpBrainActivityView(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      messagesController: messagesController,
      initialMessages: initialMessages,
      followLatestOnOpen: true,
    );
    await tester.pump();
    await tester.pump();

    final controller = _timelineController(tester);
    final initialOffset = controller.offset;
    messagesController.add([
      ...initialMessages,
      _event('animated-follow-answer', EventKind.finalAnswer, _lines(20)),
    ]);
    await tester.pump();

    expect(controller.position.isScrollingNotifier.value, isTrue);
    expect(controller.offset, moreOrLessEquals(initialOffset, epsilon: 1));
    final target = controller.position.maxScrollExtent;
    expect(target, greaterThan(initialOffset));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(controller.offset, allOf(greaterThan(initialOffset), lessThan(target)));
    expect(controller.position.isScrollingNotifier.value, isTrue);

    await tester.pump(const Duration(milliseconds: 139));
    expect(controller.position.isScrollingNotifier.value, isTrue);
    await tester.pumpAndSettle();

    expect(controller.offset, moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });
}

Future<void> _pumpBrainActivityView(
  WidgetTester tester, {
  required TestDeviceCubit agentCubit,
  required SessionCubit sessionCubit,
  required SessionMessagesCubit sessionMessagesCubit,
  required DeviceCapabilitiesStore capabilities,
  required StreamController<List<CanonicalEvent>> messagesController,
  required List<CanonicalEvent> initialMessages,
  String sessionId = 'session-1',
  String? initialViewportAnchorEventId,
  bool followLatestOnOpen = false,
  ValueChanged<String>? onViewportAnchorChanged,
  bool hasOlderHistory = false,
  Future<void> Function()? onLoadOlderHistory,
  bool hasNewerHistory = false,
  Future<void> Function()? onLoadNewerHistory,
  Future<void> Function(String eventId)? onLoadAnchoredHistory,
  ValueNotifier<List<CanonicalEvent>>? messagesNotifier,
}) {
  Widget buildView(List<CanonicalEvent> messages) => BrainActivityView(
    messagesStream: messagesController.stream,
    initialMessages: messages,
    onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
    sessionId: sessionId,
    initialViewportAnchorEventId: initialViewportAnchorEventId,
    followLatestOnOpen: followLatestOnOpen,
    onViewportAnchorChanged: onViewportAnchorChanged,
    hasOlderHistory: hasOlderHistory,
    onLoadOlderHistory: onLoadOlderHistory,
    hasNewerHistory: hasNewerHistory,
    onLoadNewerHistory: onLoadNewerHistory,
    onLoadAnchoredHistory: onLoadAnchoredHistory,
    visualState: ConversationVisualState.activeSession,
  );

  return pumpTestApp(
    tester,
    agentCubit: agentCubit,
    sessionCubit: sessionCubit,
    sessionMessagesCubit: sessionMessagesCubit,
    capabilities: capabilities,
    child: SizedBox(
      width: 800,
      height: 600,
      child: messagesNotifier == null
          ? buildView(initialMessages)
          : ValueListenableBuilder<List<CanonicalEvent>>(
              valueListenable: messagesNotifier,
              builder: (_, messages, _) => buildView(messages),
            ),
    ),
  );
}

CanonicalEvent _event(String id, EventKind kind, String text) {
  return CanonicalEvent(id: id, kind: kind, text: text, timestamp: DateTime(2026, 1, 1));
}

ScrollController _timelineController(WidgetTester tester) {
  return tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!;
}

String _topVisibleKnownEvent(
  WidgetTester tester,
  Iterable<String> eventIds,
) {
  final visibleTop = tester.getTopLeft(find.byKey(const Key('chat_messages_list'))).dy + 48;
  final visibleBottom = _visibleTimelineBottom(tester);
  final candidates = <(String, double)>[];
  for (final eventId in eventIds) {
    final finder = find.byKey(ValueKey(eventId));
    if (finder.evaluate().isEmpty) continue;
    final rect = tester.getRect(finder);
    if (rect.bottom <= visibleTop || rect.top >= visibleBottom) continue;
    candidates.add((eventId, rect.top));
  }
  candidates.sort((left, right) => left.$2.compareTo(right.$2));
  return candidates.first.$1;
}

double _eventBottom(WidgetTester tester, String eventId) {
  return tester.getBottomLeft(find.byKey(ValueKey(eventId))).dy;
}

double _visibleTimelineBottom(WidgetTester tester) {
  return tester.getTopLeft(find.byType(ConversationInputPanel)).dy - 12;
}

String _lines(int count) => List.generate(
  count,
  (index) => 'line ${index + 1}',
).join('  \n');
