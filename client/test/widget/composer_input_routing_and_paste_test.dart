import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, MethodCall, SystemChannels;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../helpers/pump_app.dart' show FakeVoiceStreamCubit;

class _FakeReadProgress extends Fake implements ReadProgress {
  @override
  ValueListenable<double?> get fraction => ValueNotifier<double?>(1.0);

  @override
  ValueListenable<bool> get cancellable => ValueNotifier<bool>(false);

  @override
  void cancel() {}
}

class _FakeDataReaderFile extends Fake implements DataReaderFile {
  final Uint8List _bytes;
  _FakeDataReaderFile(this._bytes);

  @override
  int get fileSize => _bytes.length;

  @override
  Future<Uint8List> readAll() async => _bytes;

  @override
  void close() {}
}

class _FakeItemReader extends Fake implements ClipboardDataReader {
  final Map<DataFormat, Object?> values;
  final Map<FileFormat, Uint8List> files;
  final String? suggestedName;

  _FakeItemReader({
    this.values = const {},
    this.files = const {},
    this.suggestedName,
  });

  @override
  bool canProvide(DataFormat format) => values.containsKey(format) || files.containsKey(format);

  @override
  Future<T?> readValue<T extends Object>(ValueFormat<T> format) async {
    return values[format] as T?;
  }

  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) {
    if (format != null && files.containsKey(format)) {
      final bytes = files[format]!;
      unawaited(Future.microtask(() => onFile(_FakeDataReaderFile(bytes))));
      return _FakeReadProgress();
    }
    return null;
  }

  @override
  Future<String?> getSuggestedName() async => suggestedName;
}

class _UnreadableItemReader extends _FakeItemReader {
  _UnreadableItemReader() : super(values: {Formats.fileUri: Uri.file('/gone/missing.txt')});

  @override
  Future<T?> readValue<T extends Object>(ValueFormat<T> format) async => throw StateError('clipboard item gone');
}

class _FakeClipboardReader extends Fake implements ClipboardReader {
  @override
  final List<ClipboardDataReader> items;

  _FakeClipboardReader(this.items);

  @override
  bool canProvide(DataFormat format) => items.any((item) => item.canProvide(format));
}

class _FakeSessionMessagesCubit extends Cubit<SessionMessagesState> implements SessionMessagesCubit {
  _FakeSessionMessagesCubit() : super(const SessionMessagesState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late SlashCommandTextController chatController;
  late FocusNode focusNode;
  late ComposerSlashCommandsCubit slashCubit;
  late FakeVoiceStreamCubit voiceCubit;
  late _FakeSessionMessagesCubit messagesCubit;
  late ConversationInputCubit inputCubit;

  final localAgent = DeviceConfig(
    id: 'local-agent-1',
    name: 'Local Agent',
    isOnline: true,
    metadata: const {'is_local_candidate': true},
  );

  final remoteAgent = DeviceConfig(
    id: 'remote-agent-1',
    name: 'Remote Agent',
    isOnline: true,
    metadata: const {'is_local_candidate': false},
  );

  setUp(() {
    chatController = SlashCommandTextController();
    focusNode = FocusNode();
    slashCubit = ComposerSlashCommandsCubit(
      searcher: ({query, workspaceId}) async => const <SlashCommandEntry>[],
    );
    voiceCubit = FakeVoiceStreamCubit();
    messagesCubit = _FakeSessionMessagesCubit();
    inputCubit = ConversationInputCubit(messagesCubit: messagesCubit);
  });

  tearDown(() async {
    chatController.dispose();
    focusNode.dispose();
    await slashCubit.close();
    await voiceCubit.close();
    await inputCubit.close();
    await messagesCubit.close();
  });

  ConversationInputSlice idleSlice() => const ConversationInputSlice(
    isProcessing: false,
    nextMessageModel: null,
    nextMessageProviderId: null,
    nextMessageThinkingMode: null,
    availableWorkspaces: [],
    selectedWorkspace: null,
    isLoadingWorkspaces: false,
    requiresWorkspace: false,
    permissionMode: WorkspacePermissionMode.defaultMode,
    isLoadingPermissionMode: false,
    pendingSuspendedRequest: null,
    runtimeNotice: null,
    queuedMessages: [],
  );

  Future<void> pumpComposer(
    WidgetTester tester, {
    required DeviceConfig activeAgent,
    Capability capabilities = const Capability(supportsAttachments: true),
    Future<ClipboardReader?> Function()? readClipboard,
    Future<List<XFile>> Function()? pickAttachmentFiles,
    Locale? locale,
  }) async {
    final agentSlice = ConversationInputAgentSlice(
      activeAgent: activeAgent,
      agents: [activeAgent],
    );

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<ComposerSlashCommandsCubit>.value(value: slashCubit),
          BlocProvider<VoiceStreamCubit>.value(value: voiceCubit),
          BlocProvider<ConversationInputCubit>.value(value: inputCubit),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: Scaffold(
            body: ConversationInputComposer(
              chatController: chatController,
              chatFocusNode: focusNode,
              agentSlice: agentSlice,
              inputSlice: idleSlice(),
              capabilities: capabilities,
              inputBgColor: Colors.white,
              borderColor: Colors.grey,
              dimTextColor: Colors.black54,
              chipBgColor: Colors.grey.shade200,
              onSelectSlashSuggestion: (_) {},
              onSendAttempt: ({intent = MessageDeliveryIntent.auto}) {},
              onStop: () {},
              sessionId: 'session-1',
              onConfirmFullAccess: () async => true,
              agentSelectorKey: GlobalKey<PopupMenuButtonState<String>>(),
              onPickAndCreateWorkspace: (_) async {},
              pickAttachmentFiles: pickAttachmentFiles,
              readClipboard: readClipboard,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('Composer paste capture & routing', () {
    testWidgets('pasting screenshot image bytes routes to attachment', (tester) async {
      final imageBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(
          files: {Formats.png: imageBytes},
          suggestedName: 'screenshot.png',
        ),
      ]);

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        readClipboard: () async => fakeReader,
      );

      focusNode.requestFocus();
      await tester.pump();

      // Invoke paste action
      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);
      Actions.invoke(tester.element(textField), const ComposerPasteIntent());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Verify attachment was added to cubit
      expect(inputCubit.state.draftAttachments, hasLength(1));
      final attachment = inputCubit.state.draftAttachments.first;
      expect(attachment.name, 'screenshot.png');
      expect(attachment.bytes, imageBytes);
      expect(attachment.source, DraftAttachmentSource.paste);
    });

    testWidgets('pasting file URL on local candidate agent inserts file path token', (tester) async {
      final fileUri = Uri.file('/path/to/local_document.pdf');
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(
          values: {Formats.fileUri: fileUri},
        ),
      ]);

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        readClipboard: () async => fakeReader,
      );

      focusNode.requestFocus();
      await tester.pump();

      final textField = find.byType(TextField);
      Actions.invoke(tester.element(textField), const ComposerPasteIntent());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Verify no attachments were added
      expect(inputCubit.state.draftAttachments, isEmpty);

      // Verify file token was inserted in controller
      expect(chatController.text.contains('/path/to/local_document.pdf'), isFalse);
      expect(chatController.fileTokensByMarker, hasLength(1));
      expect(
        chatController.exportPlainText(),
        '[local_document.pdf](file:///path/to/local_document.pdf) ',
      );
    });

    testWidgets('pasting file URL on remote agent routes to attachment when size <= 5 MiB', (tester) async {
      final fileUri = Uri.file('/path/to/remote_file.png');
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(
          values: {Formats.fileUri: fileUri},
        ),
      ]);

      await pumpComposer(
        tester,
        activeAgent: remoteAgent,
        readClipboard: () async => fakeReader,
      );

      focusNode.requestFocus();
      await tester.pump();

      final textField = find.byType(TextField);
      Actions.invoke(tester.element(textField), const ComposerPasteIntent());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // File was routed to attachment on remote agent
      expect(inputCubit.state.draftAttachments, hasLength(1));
      final attachment = inputCubit.state.draftAttachments.first;
      expect(attachment.name, 'remote_file.png');
      expect(attachment.source, DraftAttachmentSource.paste);
    });

    testWidgets('pasting plain text without file or image falls back to text paste', (tester) async {
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(
          values: {Formats.plainText: 'Just some copied text'},
        ),
      ]);

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        readClipboard: () async => fakeReader,
      );

      focusNode.requestFocus();
      await tester.pump();

      final textField = find.byType(TextField);
      Actions.invoke(tester.element(textField), const ComposerPasteIntent());
      await tester.pump();

      // No attachments, no file tokens created
      expect(inputCubit.state.draftAttachments, isEmpty);
      expect(chatController.fileTokensByMarker, isEmpty);
    });
  });

  group('Attachment rail alignment', () {
    testWidgets('composer card Column uses CrossAxisAlignment.start', (tester) async {
      await pumpComposer(
        tester,
        activeAgent: localAgent,
      );

      // Find the inner Column that holds the attachment rail and text field
      final columns = tester.widgetList<Column>(find.byType(Column));
      // The composer card column has CrossAxisAlignment.start
      final composerColumn = columns.firstWhere(
        (col) => col.crossAxisAlignment == CrossAxisAlignment.start,
      );
      expect(composerColumn.crossAxisAlignment, CrossAxisAlignment.start);
    });
  });

  group('Attachment picker button (+) routing', () {
    testWidgets('picker button routes picked image through ComposerInputRouter', (tester) async {
      final pickedFiles = [
        XFile.fromData(
          Uint8List.fromList([1, 2, 3]),
          path: 'picked.png',
        ),
      ];

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        pickAttachmentFiles: () async => pickedFiles,
      );

      // Find and tap the attach button (+)
      final attachBtn = find.byKey(const Key('composer_add_attachment'));
      expect(attachBtn, findsOneWidget);
      await tester.tap(attachBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(inputCubit.state.draftAttachments, hasLength(1));
      final attachment = inputCubit.state.draftAttachments.first;
      expect(attachment.name, 'picked.png');
      expect(attachment.source, DraftAttachmentSource.picker);
      // Bytes come from the XFile itself: its path is not a readable local
      // file (as on web, where it is a blob URL).
      expect(attachment.bytes, [1, 2, 3]);
    });
  });

  group('Paste key event binding (Cmd/Ctrl+V -> ComposerPasteIntent)', () {
    Future<void> pressMetaV(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    Future<void> pressControlV(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('Cmd+V key event routes clipboard image to attachment exactly once', (tester) async {
      final imageBytes = Uint8List.fromList([9, 8, 7]);
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(
          files: {Formats.png: imageBytes},
          suggestedName: 'screenshot.png',
        ),
      ]);

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        readClipboard: () async => fakeReader,
      );

      focusNode.requestFocus();
      await tester.pump();

      await pressMetaV(tester);
      await tester.pump(const Duration(milliseconds: 50));

      // Exactly one attachment: proves the shortcut binding fired and that no
      // second (default) paste handler double-handled the same key event.
      expect(inputCubit.state.draftAttachments, hasLength(1));
      expect(inputCubit.state.draftAttachments.single.name, 'screenshot.png');
      expect(inputCubit.state.draftAttachments.single.source, DraftAttachmentSource.paste);
      expect(chatController.text, isEmpty);
      expect(chatController.fileTokensByMarker, isEmpty);
    });

    testWidgets('Ctrl+V key event routes clipboard file to path token on local agent', (tester) async {
      final fileUri = Uri.file('/path/to/ctrl_key_document.md');
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(values: {Formats.fileUri: fileUri}),
      ]);

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        readClipboard: () async => fakeReader,
      );

      focusNode.requestFocus();
      await tester.pump();

      await pressControlV(tester);
      await tester.pump(const Duration(milliseconds: 50));

      expect(inputCubit.state.draftAttachments, isEmpty);
      expect(chatController.fileTokensByMarker, hasLength(1));
      expect(
        chatController.exportPlainText(),
        '[ctrl_key_document.md](file:///path/to/ctrl_key_document.md) ',
      );
    });

    testWidgets('Cmd+V while another composer control has focus never reads the clipboard', (tester) async {
      var clipboardReads = 0;
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(
          files: {
            Formats.png: Uint8List.fromList([1, 2, 3]),
          },
          suggestedName: 'screenshot.png',
        ),
      ]);

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        readClipboard: () async {
          clipboardReads++;
          return fakeReader;
        },
      );

      final addButtonFocus = Focus.of(
        tester.element(
          find.descendant(of: find.byKey(const Key('composer_add_attachment')), matching: find.byType(Icon)),
        ),
      );
      addButtonFocus.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      await pressMetaV(tester);
      await tester.pump(const Duration(milliseconds: 50));

      expect(clipboardReads, 0);
      expect(inputCubit.state.draftAttachments, isEmpty);
      expect(chatController.text, isEmpty);
    });

    testWidgets('Cmd+V with text-only clipboard inserts text exactly once via fallback', (tester) async {
      final fakeReader = _FakeClipboardReader([
        _FakeItemReader(values: {Formats.plainText: 'pasted text'}),
      ]);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': 'pasted text'};
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpComposer(
        tester,
        activeAgent: localAgent,
        readClipboard: () async => fakeReader,
      );

      focusNode.requestFocus();
      await tester.pump();

      await pressMetaV(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The PasteTextIntent fallback must reach EditableText's paste action.
      // Exact equality catches a double insert if the key were handled twice.
      expect(chatController.text, 'pasted text');
      expect(inputCubit.state.draftAttachments, isEmpty);
      expect(chatController.fileTokensByMarker, isEmpty);
    });
  });

  group('Attachment rejection feedback (114 live defect)', () {
    // A 1 MiB agent limit proves the copy states the advertised limit
    // instead of a fixed "5 MiB".
    const oneMiB = 1024 * 1024;
    const limited = Capability(supportsAttachments: true, attachmentMaxFileBytes: oneMiB);

    Future<void> pickOversized(WidgetTester tester, {Locale? locale}) async {
      await pumpComposer(
        tester,
        activeAgent: remoteAgent,
        capabilities: limited,
        locale: locale,
        pickAttachmentFiles: () async => [XFile.fromData(Uint8List(2 * oneMiB), path: 'huge.png')],
      );
      await tester.tap(find.byKey(const Key('composer_add_attachment')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('states the real limit and is dismissed with its close control', (tester) async {
      await pickOversized(tester);

      expect(inputCubit.state.draftAttachments, isEmpty);
      expect(tester.widget<Text>(find.byKey(const Key('attachment_error'))).data, 'Each attachment must be 1 MiB or smaller.');

      await tester.tap(find.byKey(const Key('attachment_error_dismiss')));
      await tester.pump();
      expect(find.byKey(const Key('attachment_error')), findsNothing);
      expect(inputCubit.state.attachmentError, isNull);
    });

    testWidgets('is localized in Arabic with the same limit', (tester) async {
      await pickOversized(tester, locale: const Locale('ar'));

      final ar = lookupAppLocalizations(const Locale('ar'));
      expect(tester.widget<Text>(find.byKey(const Key('attachment_error'))).data, ar.attachmentErrorTooLarge('1 MiB'));
      expect(ar.attachmentErrorTooLarge('1 MiB'), isNot('Each attachment must be 1 MiB or smaller.'));
      expect(find.byKey(const Key('attachment_error_dismiss')), findsOneWidget);
    });
  });

  group('Multi-file paste reports per-file failures (114 D3)', () {
    testWidgets('one unreadable item never drops the other pasted files', (tester) async {
      final fakeReader = _FakeClipboardReader([
        _UnreadableItemReader(),
        _FakeItemReader(values: {Formats.fileUri: Uri.file('/path/to/code114.py')}),
      ]);
      await pumpComposer(tester, activeAgent: localAgent, readClipboard: () async => fakeReader);
      focusNode.requestFocus();
      await tester.pump();

      Actions.invoke(tester.element(find.byType(TextField)), const ComposerPasteIntent());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(chatController.fileTokensByMarker.values.map((token) => token.fileName), ['code114.py']);
      expect(find.byKey(const Key('attachment_error')), findsOneWidget, reason: 'the unreadable item is reported');
    });
  });

  group('Attachment rail file type icons', () {
    testWidgets('a file shows its type icon while an image keeps a preview', (tester) async {
      await pumpComposer(tester, activeAgent: remoteAgent);
      const capability = Capability(supportsAttachments: true);
      // The cubit awaits a zero delay before marking the item ready, which
      // fake time only advances through a pump.
      unawaited(
        inputCubit.addDraftAttachment(
          name: 'report.pdf',
          bytes: Uint8List.fromList(const [1, 2, 3]),
          source: DraftAttachmentSource.picker,
          capability: capability,
        ),
      );
      await tester.pump();
      // The cubit awaits a zero delay before marking the item ready, which
      // fake time only advances through a pump.
      unawaited(
        inputCubit.addDraftAttachment(
          name: 'shot.png',
          bytes: Uint8List.fromList(const [4, 5, 6]),
          source: DraftAttachmentSource.picker,
          capability: capability,
        ),
      );
      await tester.pump();
      await tester.pump();

      final [file, image] = inputCubit.state.draftAttachments;
      final fileTile = find.byKey(ValueKey('draft_attachment_${file.id}'));
      final icon = find.descendant(of: fileTile, matching: find.byType(FileExtensionIcon));
      expect(icon, findsOneWidget);
      expect(tester.widget<FileExtensionIcon>(icon).fileName, 'report.pdf');
      expect(tester.widget<FileExtensionIcon>(icon).size, 20);
      expect(tester.getSize(icon), const Size(20, 20), reason: 'the 32px slot keeps the icon at its own size');

      final imageTile = find.byKey(ValueKey('draft_attachment_${image.id}'));
      expect(find.descendant(of: imageTile, matching: find.byType(Image)), findsOneWidget);
      expect(find.descendant(of: imageTile, matching: find.byType(FileExtensionIcon)), findsNothing);
      // Let composer timers started by the draft change elapse.
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('File token presentation and span rendering', () {
    testWidgets('renders FileExtensionIcon and file name in controller text span', (tester) async {
      await pumpComposer(
        tester,
        activeAgent: localAgent,
      );

      chatController.insertFileToken('/Users/dev/code/main.dart', fileName: 'main.dart');
      await tester.pump();

      // Build text span from controller
      final span = chatController.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        withComposing: false,
      );

      expect(span.children, isNotEmpty);
      final widgetSpan = span.children!.whereType<WidgetSpan>().firstOrNull;
      expect(widgetSpan, isNotNull);

      // Verify the widget inside the span contains FileExtensionIcon and the file name
      expect(widgetSpan!.child, isA<Widget>());
      // Pump a separate widget tree to verify internal components of the token widget
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: widgetSpan.child,
          ),
        ),
      );

      expect(find.byType(FileExtensionIcon), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.textContaining('/Users/dev/code/main.dart'), findsNothing);
    });
  });
}
