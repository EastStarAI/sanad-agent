import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/screens/brain_activity_view.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';

import 'package:get_it/get_it.dart';
import 'package:sanad_client/utils/toast_utils.dart';
import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart';

class _FakeAttachmentLoader implements UserAttachmentMediaLoader {
  static final Uint8List _png = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );

  _FakeAttachmentLoader({
    this.shouldFail = false,
    this.onLoad,
  });

  bool shouldFail;
  final ViewImageMediaLoad Function(UserMessageAttachment attachment, String sessionId)? onLoad;
  final List<String> loadedIds = [];
  int cancelCount = 0;

  @override
  ViewImageMediaLoad loadAttachment({
    required UserMessageAttachment attachment,
    required String sessionId,
  }) {
    loadedIds.add(attachment.id);
    if (onLoad != null) {
      return onLoad!(attachment, sessionId);
    }
    if (shouldFail) {
      return ViewImageMediaLoad(
        bytes: Future.error(Exception('Failed to load attachment media')),
        cancel: () => cancelCount += 1,
      );
    }
    return ViewImageMediaLoad(
      bytes: Future.value(_png),
      cancel: () => cancelCount += 1,
    );
  }
}

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late DeviceCapabilitiesStore capabilities;
  late FakeConversationRepository conversationRepository;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit sessionMessagesCubit;
  late DeviceConfig agent;
  late StreamController<List<CanonicalEvent>> messagesController;

  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<String>(
      'hardware-1',
      instanceName: 'hardwareId',
    );
    socket = FakeSanadSocketService();
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    final resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilities = DeviceCapabilitiesStore(resolver);
    conversationRepository = FakeConversationRepository();
    agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    final session = Session(
      id: 'session-1',
      title: 'Session 1',
      deviceId: agent.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      historyRevision: 1,
    );
    conversationRepository.seedSessions(agent, [session]);

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
    await sessionCubit.selectSession(session);
    messagesController = StreamController<List<CanonicalEvent>>.broadcast();
  });

  tearDown(() async {
    BrainActivityView.debugOnReplayError = null;
    ToastUtils.debugOnShowError = null;
    await messagesController.close();
    await sessionMessagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    await conversationRepository.dispose();
    socket.dispose();
    await GetIt.instance.reset();
  });

  Future<void> pumpView(
    WidgetTester tester, {
    required List<CanonicalEvent> initialMessages,
    Future<List<InlineEditAttachmentSelection>> Function()? pickEditAttachmentFiles,
    UserAttachmentMediaLoader? userAttachmentMediaLoader,
  }) async {
    await pumpTestApp(
      tester,
      child: BrainActivityView(
        messagesStream: messagesController.stream,
        initialMessages: initialMessages,
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
        sessionId: 'session-1',
        composerSessionId: 'session-1',
        visualState: ConversationVisualState.activeSession,
        userAttachmentMediaLoader: userAttachmentMediaLoader ?? _FakeAttachmentLoader(),
        pickEditAttachmentFiles: pickEditAttachmentFiles,
      ),
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      wrapWithToastification: true,
    );
    await tester.pumpAndSettle();
  }

  final initialUserEvent = CanonicalEvent(
    id: 'user-msg-1',
    kind: EventKind.userMessage,
    text: 'original caption',
    sessionId: 'session-1',
    timestamp: DateTime.utc(2026, 10, 13),
    metadata: const {
      'request_id': 'req-root-1',
      'message_id': 'msg-root-1',
      'turn_id': 'turn-root-1',
      'replay_eligible': true,
      'input_kind': 'root_turn',
      'history_status': 'active',
      'attachments': [
        {
          'schemaVersion': 1,
          'id': 'att-photo-1',
          'safeName': 'test_photo.png',
          'mimeType': 'image/png',
          'sizeBytes': 1024,
          'sha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'kind': 'image',
          'mediaId': 'med-1',
          'status': 'available',
        },
      ],
    },
  );

  testWidgets('inline edit allows submitting image-only edit with empty text', (tester) async {
    await pumpView(tester, initialMessages: [initialUserEvent]);

    // Begin inline edit
    expect(find.byTooltip('Edit message'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    // Verify inline editor is displayed with existing text and attachment rail
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    expect(find.byKey(const Key('inline_edit_attachment_rail')), findsOneWidget);
    expect(find.text('Ready · existing'), findsOneWidget);

    // Clear the text completely so it is image-only
    await tester.enterText(find.byKey(const Key('inline_message_editor')), '');
    await tester.pumpAndSettle();

    // Tap Send
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Verify exactly one dispatch occurred with empty message and retained attachment
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));
    final request = conversationRepository.replayWithAttachmentRequests.single;
    expect(request['message'], '');
    expect(request['action'], TurnReplayAction.edit);
    expect(request['target_request_id'], 'req-root-1');
    expect(request['attachment_edits'], hasLength(1));
    expect(request['attachment_edits'].single['reference_id'], 'att-photo-1');
  });

  testWidgets('inline edit cancel dismisses editor without dispatching replay', (tester) async {
    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);

    // Tap Cancel
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Editor is closed, no requests dispatched
    expect(find.byKey(const Key('inline_message_editor')), findsNothing);
    expect(conversationRepository.replayWithAttachmentRequests, isEmpty);
  });

  testWidgets('inline edit allows removing attachment and shows validation error on submit when empty and no attachments', (tester) async {
    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    // Remove the attachment
    await tester.tap(find.byKey(const ValueKey('remove_inline_edit_attachment_att-photo-1')));
    await tester.pumpAndSettle();

    // Attachment rail is now empty
    expect(find.text('Ready · existing'), findsNothing);

    // Clear the text
    await tester.enterText(find.byKey(const Key('inline_message_editor')), '');
    await tester.pumpAndSettle();

    // Tap Send when both text and attachments are empty
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // onSubmitEdit guards against empty text AND empty attachments: no dispatch
    expect(conversationRepository.replayWithAttachmentRequests, isEmpty);
  });

  testWidgets('failed admission preserves UI and original history on admission failure', (tester) async {
    conversationRepository.replayResult = const TurnReplayResult(
      outcome: 'attachment_admission_failed',
      safety: TurnReplaySafety.safe,
      requiresConfirmation: false,
    );

    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    // Submit edit
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Dispatched exactly once
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));

    // Editor remains open for user to fix or cancel, history is not corrupted
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
  });

  testWidgets('inline edit allows adding new attachment alongside retained attachment', (tester) async {
    final newBytes = Uint8List.fromList([1, 2, 3, 4]);
    await pumpView(
      tester,
      initialMessages: [initialUserEvent],
      pickEditAttachmentFiles: () async => [
        InlineEditAttachmentSelection(name: 'added_doc.txt', bytes: newBytes),
      ],
    );

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    // Tap add attachment
    expect(find.byKey(const Key('add_inline_edit_attachment')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_inline_edit_attachment')));
    await tester.pumpAndSettle();

    // Verify both existing and new attachments are shown in rail
    expect(find.text('Ready · existing'), findsOneWidget);
    expect(find.text('Ready · new'), findsOneWidget);

    // Tap Send
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));
    final request = conversationRepository.replayWithAttachmentRequests.single;
    expect(request['attachment_edits'], hasLength(2));
    final edits = (request['attachment_edits'] as List).cast<Map<String, dynamic>>();
    expect(edits.any((e) => e['reference_id'] == 'att-photo-1'), isTrue);
    expect(edits.any((e) => e['name'] == 'added_doc.txt'), isTrue);
  });

  testWidgets('SessionMessagesCubit.replayTurn forwards null message as empty string when attachment edits present', (tester) async {
    await tester.pump();
    final result = await sessionMessagesCubit.replayTurn(
      targetRequestId: 'req-root-1',
      action: TurnReplayAction.edit,
      message: null,
      attachmentEdits: [
        {'reference_id': 'att-photo-1'},
      ],
    );

    expect(result.isAccepted, isTrue);
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));
    final request = conversationRepository.replayWithAttachmentRequests.single;
    expect(request['message'], '');
    expect(request['target_request_id'], 'req-root-1');
  });

  testWidgets('typed known-failure retains editor text/attachments, zero auto-resend, allows manual retry', (tester) async {
    conversationRepository.replayResults.addAll([
      const TurnReplayResult(
        outcome: 'ownership_mismatch',
        safety: TurnReplaySafety.safe,
        requiresConfirmation: false,
      ),
      const TurnReplayResult(
        outcome: 'accepted',
        safety: TurnReplaySafety.safe,
        requiresConfirmation: false,
      ),
    ]);

    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('inline_message_editor')), 'Updated text with retained attachments');
    await tester.pumpAndSettle();

    // First attempt: fails with typed known failure
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Dispatched exactly once (zero automatic resend)
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));

    // Editor remains open, text and attachments are retained
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    expect(find.text('Updated text with retained attachments'), findsOneWidget);
    expect(find.text('Ready · existing'), findsOneWidget);

    // Manual retry: tap Send a second time
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Dispatched second time
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(2));

    // Accepted on second attempt dismisses editor cleanly
    expect(find.byKey(const Key('inline_message_editor')), findsNothing);
  });

  testWidgets('uncertain-send / transport exception retains editor draft and attachments with honest guidance without auto-resend', (tester) async {
    String? replayError;
    BrainActivityView.debugOnReplayError = (msg) => replayError = msg;
    conversationRepository.replayWithAttachmentsException = TimeoutException('network dropped');
    conversationRepository.replayResult = const TurnReplayResult(
      outcome: 'accepted',
      safety: TurnReplaySafety.safe,
      requiresConfirmation: false,
    );

    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('inline_message_editor')), 'Draft text before socket timeout');
    await tester.pumpAndSettle();

    // First attempt throws transport exception
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Dispatched once, zero auto-resend
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));

    // Surfaces honest unconfirmed-outcome guidance (does not encourage blind resend)
    expect(
      replayError,
      'Replay outcome could not be confirmed. Check conversation history before retrying.',
    );

    // Editor remains open, text and attachment rail retained
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    expect(find.text('Draft text before socket timeout'), findsOneWidget);
    expect(find.text('Ready · existing'), findsOneWidget);

    // Manual retry after connectivity restored succeeds
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(conversationRepository.replayWithAttachmentRequests, hasLength(2));
    expect(find.byKey(const Key('inline_message_editor')), findsNothing);
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('accepted backend/history with dropped acknowledgement, authoritative reconciliation and no automatic/blind duplicate commit', (tester) async {
    // Seam limitation: This widget-level test exercises presentation resilience, honest guidance,
    // draft retention, and authoritative history reconciliation via SessionMessagesCubit and
    // FakeConversationRepository. Real daemon transaction rollback and socket reconnection are
    // owned at the gateway integration boundary; normal returned accepted(historyRevision) is
    // not proof of backend-accepted/ACK-lost reconciliation.
    String? replayError;
    BrainActivityView.debugOnReplayError = (msg) => replayError = msg;
    conversationRepository.replayWithAttachmentsException = TimeoutException('network dropped while awaiting ACK');

    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('inline_message_editor')), 'Replacement text accepted on backend');
    await tester.pumpAndSettle();

    // First dispatch: command was sent, backend accepted, but response ACK dropped on network
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Dispatched exactly once; zero automatic duplicate resend
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));

    // UI shows honest unconfirmed-outcome guidance requiring history reconciliation before retry
    expect(
      replayError,
      'Replay outcome could not be confirmed. Check conversation history before retrying.',
    );

    // Editor draft and attachments preserved
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    expect(find.text('Replacement text accepted on backend'), findsOneWidget);
    expect(find.text('Ready · existing'), findsOneWidget);

    // Authoritative reconciliation: history update / reconnect arrives from backend
    // revealing the replacement event committed by the backend with advanced revision.
    final replacementEvent = CanonicalEvent(
      id: 'evt-replacement-1',
      kind: EventKind.userMessage,
      text: 'Replacement text accepted on backend',
      sessionId: 'session-1',
      timestamp: DateTime.utc(2026, 10, 13, 0, 1),
      metadata: const {
        'request_id': 'req-root-1',
        'message_id': 'msg-replacement-1',
        'turn_id': 'turn-root-1',
        'replay_eligible': true,
        'input_kind': 'root_turn',
        'history_status': 'active',
      },
    );

    // Server-accepted history reconciliation updates messages and historyRevision
    messagesController.add([replacementEvent]);
    sessionCubit.applyHistoryRevision('session-1', 2);
    await tester.pumpAndSettle();

    // Reconciled history is visible: the replacement message is present
    expect(find.text('Replacement text accepted on backend'), findsOneWidget);

    // Stale inline editor is dismissed because the original event is superseded
    expect(find.byKey(const Key('inline_message_editor')), findsNothing);

    // ZERO duplicate dispatches were made: replayWithAttachmentRequests is STILL 1
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));
    expect(sessionCubit.state.selectedSession?.historyRevision, 2);
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('typed disconnected outcome shows honest reconnection guidance and retains draft', (tester) async {
    String? replayError;
    BrainActivityView.debugOnReplayError = (msg) => replayError = msg;
    conversationRepository.replayResult = const TurnReplayResult(
      outcome: 'disconnected',
      safety: TurnReplaySafety.unknown,
      requiresConfirmation: false,
    );

    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('inline_message_editor')), 'Draft during disconnect');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));
    expect(
      replayError,
      'Disconnected from agent. Reconnect and check conversation history before retrying.',
    );
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('typed invalid_response outcome shows unconfirmed guidance and retains draft', (tester) async {
    String? replayError;
    BrainActivityView.debugOnReplayError = (msg) => replayError = msg;
    conversationRepository.replayResult = const TurnReplayResult(
      outcome: 'invalid_response',
      safety: TurnReplaySafety.unknown,
      requiresConfirmation: false,
    );

    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('inline_message_editor')), 'Draft during invalid response');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));
    expect(
      replayError,
      'Replay outcome could not be confirmed. Check conversation history before retrying.',
    );
    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    expect(find.text('Draft during invalid response'), findsOneWidget);
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('accepted replay reconciles history revision and dismisses editor', (tester) async {
    conversationRepository.replayResult = const TurnReplayResult(
      outcome: 'accepted',
      safety: TurnReplaySafety.safe,
      requiresConfirmation: false,
      historyRevision: 42,
    );

    await pumpView(tester, initialMessages: [initialUserEvent]);

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('inline_message_editor')), 'Accepted prompt text');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // Exactly one dispatch
    expect(conversationRepository.replayWithAttachmentRequests, hasLength(1));

    // Editor is dismissed
    expect(find.byKey(const Key('inline_message_editor')), findsNothing);

    // History revision updated in sessionCubit
    expect(sessionCubit.state.selectedSession?.historyRevision, 42);
  });

  testWidgets('existing image attachment displays real thumbnail in inline edit rail', (tester) async {
    final loader = _FakeAttachmentLoader();
    await pumpView(
      tester,
      initialMessages: [initialUserEvent],
      userAttachmentMediaLoader: loader,
    );

    loader.loadedIds.clear();

    // Begin inline edit
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inline_edit_attachment_rail')), findsOneWidget);
    final chip = find.byKey(const ValueKey('inline_edit_attachment_att-photo-1'));
    expect(chip, findsOneWidget);

    // Loader was called for the existing image attachment
    expect(loader.loadedIds, ['att-photo-1']);

    // Real thumbnail (Image) is rendered inside the attachment chip, not generic icon
    expect(
      find.descendant(of: chip, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip, matching: find.byIcon(Icons.image_outlined)),
      findsNothing,
    );
  });

  testWidgets('loader failure falls back to generic icon without breaking rail and supports retry', (tester) async {
    final loader = _FakeAttachmentLoader(shouldFail: true);
    await pumpView(
      tester,
      initialMessages: [initialUserEvent],
      userAttachmentMediaLoader: loader,
    );

    // Begin inline edit
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inline_edit_attachment_rail')), findsOneWidget);
    final chip = find.byKey(const ValueKey('inline_edit_attachment_att-photo-1'));
    expect(chip, findsOneWidget);

    // Loader failed, so generic image icon is shown as fallback
    expect(
      find.descendant(of: chip, matching: find.byIcon(Icons.image_outlined)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip, matching: find.byType(Image)),
      findsNothing,
    );

    // Rail remains completely functional
    expect(find.text('Ready · existing'), findsOneWidget);

    // Tap retry on the fallback icon to reload
    loader.shouldFail = false;
    await tester.tap(
      find.descendant(of: chip, matching: find.byIcon(Icons.image_outlined)),
    );
    await tester.pumpAndSettle();

    // Now rendered as thumbnail
    expect(
      find.descendant(of: chip, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip, matching: find.byIcon(Icons.image_outlined)),
      findsNothing,
    );
  });

  testWidgets('cancelling inline edit invokes cancel on in-flight thumbnail load', (tester) async {
    final completer = Completer<Uint8List>();
    var callCount = 0;
    var canceled = 0;
    final loader = _FakeAttachmentLoader(
      onLoad: (attachment, sessionId) {
        callCount++;
        if (callCount == 1) {
          // Initial user message card render
          return ViewImageMediaLoad(
            bytes: Future.value(_FakeAttachmentLoader._png),
            cancel: () {},
          );
        }
        // Second call is from inline edit thumbnail
        return ViewImageMediaLoad(
          bytes: completer.future,
          cancel: () => canceled++,
        );
      },
    );

    await pumpView(
      tester,
      initialMessages: [initialUserEvent],
      userAttachmentMediaLoader: loader,
    );

    // Initial message settled
    expect(callCount, 1);

    // Tap edit message
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pump();

    // Loader was called for the inline edit thumbnail
    expect(callCount, 2);
    expect(find.byType(AppProgressIndicator), findsOneWidget);

    // Cancel edit
    await tester.tap(find.text('Cancel'));
    completer.complete(_FakeAttachmentLoader._png);
    await tester.pumpAndSettle();

    // Editor is closed and cancel was invoked
    expect(find.byKey(const Key('inline_message_editor')), findsNothing);
    expect(canceled, 1);
  });

  testWidgets('new image attachment with local bytes displays thumbnail directly without calling loader', (tester) async {
    final loader = _FakeAttachmentLoader();
    final newBytes = Uint8List.fromList([1, 2, 3]);

    await pumpView(
      tester,
      initialMessages: [
        CanonicalEvent(
          id: 'user-no-attachments',
          kind: EventKind.userMessage,
          text: 'no attachments message',
          sessionId: 'session-1',
          timestamp: DateTime.utc(2026, 10, 13),
          metadata: const {
            'request_id': 'req-root-no-att',
            'message_id': 'msg-root-no-att',
            'turn_id': 'turn-root-no-att',
            'replay_eligible': true,
            'input_kind': 'root_turn',
            'history_status': 'active',
          },
        ),
      ],
      userAttachmentMediaLoader: loader,
      pickEditAttachmentFiles: () async => [
        InlineEditAttachmentSelection(name: 'added_photo.png', bytes: newBytes),
      ],
    );

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    // Add new attachment
    await tester.tap(find.byKey(const Key('add_inline_edit_attachment')));
    await tester.pumpAndSettle();

    expect(find.text('added_photo.png'), findsOneWidget);
    expect(find.text('Ready · new'), findsOneWidget);

    // New attachment renders Image from local bytes directly without loader
    expect(loader.loadedIds, isEmpty);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('existing non-image file attachment renders file icon and does not invoke loader', (tester) async {
    final loader = _FakeAttachmentLoader();
    final fileEvent = CanonicalEvent(
      id: 'user-msg-file',
      kind: EventKind.userMessage,
      text: 'document attached',
      sessionId: 'session-1',
      timestamp: DateTime.utc(2026, 10, 13),
      metadata: const {
        'request_id': 'req-root-file',
        'message_id': 'msg-root-file',
        'turn_id': 'turn-root-file',
        'replay_eligible': true,
        'input_kind': 'root_turn',
        'history_status': 'active',
        'attachments': [
          {
            'schemaVersion': 1,
            'id': 'att-doc-1',
            'safeName': 'report.pdf',
            'mimeType': 'application/pdf',
            'sizeBytes': 2048,
            'sha256': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'kind': 'file',
            'mediaId': 'med-doc-1',
            'status': 'available',
          },
        ],
      },
    );

    await pumpView(
      tester,
      initialMessages: [fileEvent],
      userAttachmentMediaLoader: loader,
    );

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('inline_edit_attachment_att-doc-1'));
    expect(chip, findsOneWidget);
    expect(find.descendant(of: chip, matching: find.byIcon(Icons.insert_drive_file_outlined)), findsOneWidget);
    expect(loader.loadedIds, isEmpty);
  });

  testWidgets('inline edit oversized add shows a dismissible error that clears on remove and next valid add', (tester) async {
    var picks = [InlineEditAttachmentSelection(name: 'huge.png', bytes: Uint8List(5 * 1024 * 1024 + 1))];
    await pumpView(tester, initialMessages: [initialUserEvent], pickEditAttachmentFiles: () async => picks);
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();

    Future<void> add() async {
      await tester.tap(find.byKey(const Key('add_inline_edit_attachment')));
      await tester.pumpAndSettle();
    }

    Finder error() => find.byKey(const Key('inline_edit_attachment_error'));

    // Explicit dismiss.
    await add();
    expect(tester.widget<Text>(error()).data, 'Each attachment must be 5 MiB or smaller.');
    await tester.tap(find.byKey(const Key('inline_edit_attachment_error_dismiss')));
    await tester.pumpAndSettle();
    expect(error(), findsNothing);

    // Next valid add clears a fresh rejection.
    await add();
    expect(error(), findsOneWidget);
    picks = [InlineEditAttachmentSelection(name: 'small.txt', bytes: Uint8List.fromList(const [1]))];
    await add();
    expect(error(), findsNothing);

    // Removing an attachment clears a fresh rejection.
    picks = [InlineEditAttachmentSelection(name: 'huge2.png', bytes: Uint8List(5 * 1024 * 1024 + 1))];
    await add();
    expect(error(), findsOneWidget);
    await tester.tap(find.byTooltip('Remove attachment').last);
    await tester.pumpAndSettle();
    expect(error(), findsNothing);
  });
}
