import 'dart:async';

import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input_panel.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/l10n/app_localizations_ar.dart';
import 'package:sanad_client/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
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
  late _TestSessionMessagesCubit sessionMessagesCubit;
  late DeviceConfig agent;

  setUp(() async {
    await getIt.reset();
    ConversationInputPanel.debugOnValidationError = null;
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
    conversationRepository.slashCommandResults = const [
      SlashCommandEntry(
        sourceId: 'sanad-agent',
        command: 'compact',
        insertText: 'compact',
        description: 'Compact conversation context',
        type: SlashCommandType.runtimeAction,
      ),
    ];
    agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    conversationRepository.seedSessions(agent, [
      Session(
        id: 'session-compact',
        title: 'Compact test',
        deviceId: agent.id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ]);
    sessionMessagesCubit = _TestSessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    sessionMessagesCubit.emitState(
      const SessionMessagesState(
        activeSessionId: 'session-compact',
      ),
    );
    sessionMessagesCubit.setNextMessagePreferences(
      providerId: 'provider-1',
      model: 'model-1',
    );
  });

  tearDown(() async {
    ConversationInputPanel.debugOnValidationError = null;
    await sessionMessagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    socket.dispose();
    await getIt.reset();
  });

  testWidgets('exact /compact dispatches compact command without user message', (
    tester,
  ) async {
    var sendCalls = 0;
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {
          sendCalls += 1;
        },
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pumpAndSettle();

    expect(sendCalls, 0);
    expect(conversationRepository.compactSessionCalls, 1);
  });

  testWidgets('Enter on a partial runtime action executes it immediately', (
    tester,
  ) async {
    var sendCalls = 0;
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {
          sendCalls += 1;
        },
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/com');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(sendCalls, 0);
    expect(conversationRepository.compactSessionCalls, 1);
    expect(find.text('/compact'), findsNothing);
    expect(
      find.byKey(const Key('slash_suggestion_runtime_action_compact')),
      findsNothing,
    );
  });

  testWidgets('clicking a partial runtime action executes it immediately', (
    tester,
  ) async {
    var sendCalls = 0;
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {
          sendCalls += 1;
        },
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/co');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(
      find.byKey(const Key('slash_suggestion_runtime_action_compact')),
    );
    await tester.pumpAndSettle();

    expect(sendCalls, 0);
    expect(conversationRepository.compactSessionCalls, 1);
    expect(find.text('/compact'), findsNothing);
    expect(
      find.byKey(const Key('slash_suggestion_runtime_action_compact')),
      findsNothing,
    );
  });

  testWidgets('double Enter coalesces one in-flight runtime action', (
    tester,
  ) async {
    final compactResult = Completer<SessionCompactResult>();
    conversationRepository.compactSessionHandler = () => compactResult.future;
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/com');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(conversationRepository.compactSessionCalls, 1);
    compactResult.complete(
      const SessionCompactResult(outcome: 'accepted'),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('a selected skill inserts first and sends on the next Enter', (
    tester,
  ) async {
    conversationRepository.slashCommandResults = const [
      SlashCommandEntry(
        sourceId: 'skill',
        command: 'review',
        insertText: 'review',
        type: SlashCommandType.skill,
      ),
    ];
    final sentMessages = <String>[];
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (message, {intent = MessageDeliveryIntent.auto}) {
          sentMessages.add(message);
        },
      ),
    );

    await tester.enterText(
      find.byKey(const Key('chat_input')),
      'please /rev',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sentMessages, isEmpty);
    expect(conversationRepository.compactSessionCalls, 0);
    expect(find.text('review'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sentMessages, ['please review']);
    expect(conversationRepository.compactSessionCalls, 0);
  });

  testWidgets('a mid-message runtime invocation remains ordinary text', (
    tester,
  ) async {
    final sentMessages = <String>[];
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (message, {intent = MessageDeliveryIntent.auto}) {
          sentMessages.add(message);
        },
      ),
    );

    await tester.enterText(
      find.byKey(const Key('chat_input')),
      'please /compact',
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const Key('slash_suggestion_runtime_action_compact')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pump();

    expect(sentMessages, ['please /compact']);
    expect(conversationRepository.compactSessionCalls, 0);
  });

  testWidgets('/compact with arguments shows validation and keeps draft', (
    tester,
  ) async {
    String? validationError;
    ConversationInputPanel.debugOnValidationError = (message) {
      validationError = message;
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    await tester.enterText(
      find.byKey(const Key('chat_input')),
      '/compact force',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(validationError, '/compact does not accept arguments.');
    expect(conversationRepository.compactSessionCalls, 0);
    expect(find.text('/compact force'), findsOneWidget);
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('session busy compact outcome consumes command and shows feedback', (
    tester,
  ) async {
    conversationRepository.compactSessionResult = const SessionCompactResult(
      outcome: 'session_busy',
    );
    String? validationError;
    ConversationInputPanel.debugOnValidationError = (message) {
      validationError = message;
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pumpAndSettle();

    expect(conversationRepository.compactSessionCalls, 1);
    expect(
      validationError,
      'Session is busy. Try /compact again when idle.',
    );
    expect(find.text('/compact'), findsNothing);
    expect(
      find.byKey(const Key('slash_suggestion_runtime_action_compact')),
      findsNothing,
    );
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('compaction in progress outcome consumes command and shows feedback', (tester) async {
    conversationRepository.compactSessionResult = const SessionCompactResult(
      outcome: 'compaction_in_progress',
    );
    String? validationError;
    ConversationInputPanel.debugOnValidationError = (message) {
      validationError = message;
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pumpAndSettle();

    expect(conversationRepository.compactSessionCalls, 1);
    expect(
      validationError,
      'Context compaction is already in progress. Wait for the current operation to finish before retrying.',
    );
    expect(find.text('/compact'), findsNothing);
    expect(
      find.byKey(const Key('slash_suggestion_runtime_action_compact')),
      findsNothing,
    );
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
    'terminal compact failure consumes command and reports localized explanation with next action',
    (tester) async {
      conversationRepository.compactSessionResult = const SessionCompactResult(
        outcome: 'failed',
        failureReason: 'continuityValidationFailed',
      );
      String? validationError;
      ConversationInputPanel.debugOnValidationError = (message) {
        validationError = message;
      };

      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionMessagesCubit: sessionMessagesCubit,
        capabilities: capabilities,
        child: ConversationInputPanel(
          sessionId: 'session-compact',
          onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
        ),
      );

      await tester.enterText(find.byKey(const Key('chat_input')), '/co');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(conversationRepository.compactSessionCalls, 1);
      expect(
        validationError,
        'Summary failed continuity verification. Retry compaction to generate a complete summary.',
      );
      expect(find.text('/compact'), findsNothing);
      expect(
        find.byKey(const Key('slash_suggestion_runtime_action_compact')),
        findsNothing,
      );
      await tester.pump(ToastUtils.defaultDuration);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'thinking capability rejection feedback explains thinking unsupported with actionable advice',
    (tester) async {
      conversationRepository.compactSessionResult = const SessionCompactResult(
        outcome: 'failed',
        failureReason: 'summarization_failed',
        failureStage: 'preparation',
        failureCause: 'thinking_capability_unsupported',
      );
      String? validationError;
      ConversationInputPanel.debugOnValidationError = (message) {
        validationError = message;
      };

      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionMessagesCubit: sessionMessagesCubit,
        capabilities: capabilities,
        child: ConversationInputPanel(
          sessionId: 'session-compact',
          onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
        ),
      );

      await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_message_btn')));
      await tester.pumpAndSettle();

      expect(conversationRepository.compactSessionCalls, 1);
      expect(
        validationError,
        'Selected thinking mode is not supported by the active model or route. '
        'Select a supported thinking mode or route and try again.',
      );
      await tester.pump(ToastUtils.defaultDuration);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'provider timeout rejection feedback explains timeout with safe next action',
    (tester) async {
      conversationRepository.compactSessionResult = const SessionCompactResult(
        outcome: 'failed',
        failureReason: 'summarization_failed',
        failureStage: 'provider',
        failureCause: 'timeout',
      );
      String? validationError;
      ConversationInputPanel.debugOnValidationError = (message) {
        validationError = message;
      };

      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionMessagesCubit: sessionMessagesCubit,
        capabilities: capabilities,
        child: ConversationInputPanel(
          sessionId: 'session-compact',
          onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
        ),
      );

      await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_message_btn')));
      await tester.pumpAndSettle();

      expect(conversationRepository.compactSessionCalls, 1);
      expect(
        validationError,
        'Provider timed out during context summarization. Check network connection or try again.',
      );
      await tester.pump(ToastUtils.defaultDuration);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'Arabic locale delivers the localized toast explanation with next action',
    (tester) async {
      conversationRepository.compactSessionResult = const SessionCompactResult(
        outcome: 'failed',
        failureReason: 'summarization_failed',
        failureStage: 'preparation',
        failureCause: 'thinking_capability_unsupported',
      );
      String? validationError;
      ConversationInputPanel.debugOnValidationError = (message) {
        validationError = message;
      };

      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionMessagesCubit: sessionMessagesCubit,
        capabilities: capabilities,
        locale: const Locale('ar'),
        child: ConversationInputPanel(
          sessionId: 'session-compact',
          onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
        ),
      );

      await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_message_btn')));
      await tester.pumpAndSettle();

      // Expectations derive from the localization system: the root contract
      // forbids Arabic literals in handwritten Dart, including tests.
      final arabic = AppLocalizationsAr();
      expect(conversationRepository.compactSessionCalls, 1);
      expect(
        validationError,
        '${arabic.compactionFailureThinkingUnsupported} '
        '${arabic.compactionActionThinkingUnsupported}',
      );
      await tester.pump(ToastUtils.defaultDuration);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  group('slow acknowledgement (Task 119)', () {
    late Completer<SessionCompactResult> settlement;
    late List<String> validationErrors;
    late List<String> infoNotices;

    setUp(() {
      validationErrors = [];
      infoNotices = [];
      ConversationInputPanel.debugOnValidationError = validationErrors.add;
      ToastUtils.debugOnShowInfo = infoNotices.add;
    });

    tearDown(() => ToastUtils.debugOnShowInfo = null);

    // Toast animations never settle while a toast is visible, so advance a
    // bounded frame instead of pumpAndSettle.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    Future<void> runCompact(
      WidgetTester tester, {
      Locale? locale,
      String sessionId = 'session-compact',
    }) async {
      // Created inside the test body so its completion runs in the widget
      // tester's fake-async zone.
      settlement = Completer<SessionCompactResult>();
      conversationRepository.compactSessionResult = SessionCompactResult(
        outcome: SessionCompactResult.pendingOutcome,
        requestId: 'req-slow',
        settlement: settlement.future,
      );
      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionMessagesCubit: sessionMessagesCubit,
        capabilities: capabilities,
        locale: locale,
        wrapWithToastification: true,
        child: ConversationInputPanel(
          sessionId: sessionId,
          onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
        ),
      );
      await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_message_btn')));
      await settle(tester);
      expect(conversationRepository.compactSessionCalls, 1);
    }

    Future<void> drainToasts(WidgetTester tester) async {
      await tester.pump(ToastUtils.defaultDuration);
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('pending shows a neutral still-running notice, never a failure', (
      tester,
    ) async {
      await runCompact(tester);

      expect(conversationRepository.compactSessionCalls, 1);
      expect(validationErrors, isEmpty);
      expect(infoNotices, [AppLocalizationsEn().compactionPendingStillRunning]);
      await drainToasts(tester);
    });

    testWidgets('late success after pending shows no failure', (tester) async {
      await runCompact(tester);
      settlement.complete(
        const SessionCompactResult(outcome: 'accepted', compactionId: 'cmp-1'),
      );
      await settle(tester);

      expect(validationErrors, isEmpty);
      expect(conversationRepository.compactSessionCalls, 1);
      await drainToasts(tester);
    });

    testWidgets('late failure after pending is reported exactly once', (
      tester,
    ) async {
      await runCompact(tester);
      settlement.complete(
        const SessionCompactResult(
          outcome: 'failed',
          failureReason: 'summarization_failed',
          failureStage: 'provider',
          failureCause: 'timeout',
        ),
      );
      await settle(tester);

      expect(validationErrors, [
        'Provider timed out during context summarization. Check network connection or try again.',
      ]);
      expect(conversationRepository.compactSessionCalls, 1, reason: 'never resent');
      await drainToasts(tester);
    });

    testWidgets('late busy rejection after pending is reported', (tester) async {
      await runCompact(tester);
      settlement.complete(
        const SessionCompactResult(outcome: 'compaction_in_progress'),
      );
      await settle(tester);

      expect(validationErrors, [
        'Context compaction is already in progress. Wait for the current operation to finish before retrying.',
      ]);
      await drainToasts(tester);
    });

    testWidgets('pending releases the runtime action without resending', (
      tester,
    ) async {
      await runCompact(tester);
      expect(conversationRepository.compactSessionCalls, 1);

      // Only an explicit new user intent dispatches again; the daemon owns
      // whether it is admitted (for example compaction_in_progress).
      conversationRepository.compactSessionResult = const SessionCompactResult(
        outcome: 'compaction_in_progress',
      );
      await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_message_btn')));
      await settle(tester);

      expect(conversationRepository.compactSessionCalls, 2);
      expect(validationErrors, [
        'Context compaction is already in progress. Wait for the current operation to finish before retrying.',
      ]);
      await drainToasts(tester);
    });

    testWidgets('unconfirmed settlement adds no failure', (tester) async {
      await runCompact(tester);
      settlement.complete(
        const SessionCompactResult(outcome: SessionCompactResult.unconfirmedOutcome),
      );
      await settle(tester);

      expect(validationErrors, isEmpty);
      await drainToasts(tester);
    });

    testWidgets('late failure for a session the panel left is not shown here', (
      tester,
    ) async {
      await runCompact(tester);
      await pumpTestApp(
        tester,
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        sessionMessagesCubit: sessionMessagesCubit,
        capabilities: capabilities,
        wrapWithToastification: true,
        child: ConversationInputPanel(
          sessionId: 'session-other',
          onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
        ),
      );
      settlement.complete(const SessionCompactResult(outcome: 'failed'));
      await settle(tester);

      expect(validationErrors, isEmpty);
      await drainToasts(tester);
    });

    testWidgets('Arabic locale localizes the still-running notice', (
      tester,
    ) async {
      await runCompact(tester, locale: const Locale('ar'));

      expect(validationErrors, isEmpty);
      expect(infoNotices, [AppLocalizationsAr().compactionPendingStillRunning]);
      await drainToasts(tester);
    });
  });
}

class _TestSessionMessagesCubit extends SessionMessagesCubit {
  _TestSessionMessagesCubit({
    required super.agentCubit,
    required super.sessionCubit,
    required super.conversationRepository,
    required super.preferencesRepository,
  });

  void emitState(SessionMessagesState state) {
    emit(state);
  }
}
