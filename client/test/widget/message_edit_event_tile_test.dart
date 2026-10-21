import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';
import 'package:sanad_client/utils/app_platform.dart';

class _FakeLoader implements UserAttachmentMediaLoader {
  static final Uint8List _png = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );

  _FakeLoader({this.shouldFail = false});
  final bool shouldFail;
  final List<String> loadedIds = [];

  @override
  ViewImageMediaLoad loadAttachment({
    required UserMessageAttachment attachment,
    required String sessionId,
  }) {
    loadedIds.add(attachment.id);
    if (shouldFail) {
      return ViewImageMediaLoad(
        bytes: Future.error(Exception('Failed to load')),
        cancel: () {},
      );
    }
    return ViewImageMediaLoad(
      bytes: Future.value(_png),
      cancel: () {},
    );
  }
}

UserMessageAttachment existingImage({bool isAvailable = true}) => UserMessageAttachment(
  id: 'existing-image-1',
  mediaId: 'media-existing-image-1',
  safeName: 'photo.png',
  mimeType: 'image/png',
  sizeBytes: 68,
  sha256: 'a' * 64,
  isImage: true,
  isAvailable: isAvailable,
);

void main() {
  setUp(() => AppPlatform.overrideIsMobile = null);
  tearDown(() => AppPlatform.overrideIsMobile = null);

  final event = CanonicalEvent(
    id: 'user-request-1',
    kind: EventKind.userMessage,
    text: 'original message',
    timestamp: DateTime.utc(2026, 7, 18),
    metadata: const {'request_id': 'request-1'},
  );

  testWidgets('eligible user message exposes edit and retry actions', (
    tester,
  ) async {
    var editPressed = false;
    var retryPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            onBeginEdit: () => editPressed = true,
            onRetry: () async => retryPressed = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Edit message'));
    await tester.tap(find.byTooltip('Retry message'));
    await tester.pump();

    expect(editPressed, isTrue);
    expect(retryPressed, isTrue);
  });

  testWidgets('steer bubbles do not expose edit or retry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: CanonicalEvent(
              id: 'steer-1',
              kind: EventKind.userMessage,
              text: 'nudge',
              timestamp: DateTime.utc(2026, 7, 18),
              metadata: const {
                'request_id': 'steer-1',
                'input_kind': 'steer',
                'steer': true,
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Edit message'), findsNothing);
    expect(find.byTooltip('Retry message'), findsNothing);
  });

  testWidgets('inline editor renders Send and Cancel below the input', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'edited message');
    addTearDown(controller.dispose);
    var sent = false;
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            onSubmitEdit: () async => sent = true,
            onCancelEdit: () => cancelled = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Send'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(sent, isTrue);
    expect(cancelled, isTrue);
  });

  testWidgets('desktop inline editor submits with Enter and adds a line with Shift+Enter', (tester) async {
    final controller = TextEditingController(text: 'first line');
    controller.selection = TextSelection.collapsed(offset: controller.text.length);
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            onSubmitEdit: () async => submissions += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.text, 'first line\n');
    expect(submissions, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submissions, 1);
  });

  testWidgets('mobile inline editor Enter stays multiline without submitting', (tester) async {
    AppPlatform.overrideIsMobile = true;
    final controller = TextEditingController(text: 'first line');
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            onSubmitEdit: () async => submissions += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    final inputFinder = find.byKey(const Key('inline_message_editor'));
    await tester.tap(inputFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.enterText(inputFinder, 'first line\nsecond line');
    await tester.pump();

    final input = tester.widget<TextField>(inputFinder);
    expect(input.keyboardType, TextInputType.multiline);
    expect(input.textInputAction, TextInputAction.newline);
    expect(controller.text, 'first line\nsecond line');
    expect(submissions, 0);
  });

  testWidgets('inline editor restores existing and new attachments with isolated actions', (tester) async {
    final controller = TextEditingController(text: 'edited message');
    addTearDown(controller.dispose);
    final removed = <String>[];
    final retried = <String>[];
    var addCalls = 0;
    final attachments = [
      const InlineEditAttachment(
        id: 'existing-1',
        name: 'photo.png',
        sizeBytes: 68,
        isImage: true,
        isExisting: true,
      ),
      const InlineEditAttachment(
        id: 'new-1',
        name: 'notes.txt',
        sizeBytes: 12,
        isImage: false,
        isExisting: false,
      ),
      const InlineEditAttachment(
        id: 'failed-1',
        name: 'failed.txt',
        sizeBytes: 12,
        isImage: false,
        isExisting: false,
        status: InlineEditAttachmentStatus.failed,
        error: 'Upload failed',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            editAttachments: attachments,
            editAttachmentError: 'Upload failed',
            onAddEditAttachment: () async => addCalls += 1,
            onRemoveEditAttachment: removed.add,
            onRetryEditAttachment: retried.add,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('inline_edit_attachment_rail')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('inline_edit_attachment_existing-1')),
      findsOneWidget,
    );
    expect(find.text('Ready · existing'), findsOneWidget);
    expect(find.text('Ready · new'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.byKey(const Key('inline_edit_attachment_error')), findsOneWidget);

    await tester.tap(find.byKey(const Key('add_inline_edit_attachment')));
    await tester.tap(
      find.byKey(const ValueKey('remove_inline_edit_attachment_existing-1')),
    );
    await tester.tap(
      find.byKey(const ValueKey('retry_inline_edit_attachment_failed-1')),
    );
    await tester.pump();

    expect(addCalls, 1);
    expect(removed, ['existing-1']);
    expect(retried, ['failed-1']);
  });

  testWidgets('EventTile inline edit renders thumbnail with userAttachmentMediaLoader and sessionId', (tester) async {
    final controller = TextEditingController(text: 'edited message');
    addTearDown(controller.dispose);
    final loader = _FakeLoader();

    final attachments = [InlineEditAttachment.existing(existingImage())];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            sessionId: 'session-1',
            userAttachmentMediaLoader: loader,
            canReplay: true,
            isEditing: true,
            editController: controller,
            editAttachments: attachments,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inline_edit_attachment_rail')), findsOneWidget);
    final chip = find.byKey(const ValueKey('inline_edit_attachment_existing-image-1'));
    expect(chip, findsOneWidget);
    expect(loader.loadedIds, ['existing-image-1']);
    expect(find.descendant(of: chip, matching: find.byType(Image)), findsOneWidget);
  });

  testWidgets('EventTile inline edit falls back to icon when userAttachmentMediaLoader fails', (tester) async {
    final controller = TextEditingController(text: 'edited message');
    addTearDown(controller.dispose);
    final loader = _FakeLoader(shouldFail: true);

    final attachments = [InlineEditAttachment.existing(existingImage())];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            sessionId: 'session-1',
            userAttachmentMediaLoader: loader,
            canReplay: true,
            isEditing: true,
            editController: controller,
            editAttachments: attachments,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('inline_edit_attachment_existing-image-1'));
    expect(chip, findsOneWidget);
    expect(loader.loadedIds, ['existing-image-1']);
    expect(find.descendant(of: chip, matching: find.byIcon(Icons.image_outlined)), findsOneWidget);
    expect(find.descendant(of: chip, matching: find.byType(Image)), findsNothing);
  });

  testWidgets('EventTile inline edit never requests an unavailable existing attachment', (tester) async {
    final controller = TextEditingController(text: 'edited message');
    addTearDown(controller.dispose);
    final loader = _FakeLoader();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            sessionId: 'session-1',
            userAttachmentMediaLoader: loader,
            canReplay: true,
            isEditing: true,
            editController: controller,
            editAttachments: [InlineEditAttachment.existing(existingImage(isAvailable: false))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('inline_edit_attachment_existing-image-1'));
    expect(chip, findsOneWidget);
    expect(loader.loadedIds, isEmpty);
    expect(find.descendant(of: chip, matching: find.byIcon(Icons.image_outlined)), findsOneWidget);
  });

  testWidgets('EventTile inline edit rebuild with a new loader instance does not refetch', (tester) async {
    final controller = TextEditingController(text: 'edited message');
    addTearDown(controller.dispose);
    final firstLoader = _FakeLoader();
    final secondLoader = _FakeLoader();

    Widget host(UserAttachmentMediaLoader loader) => MaterialApp(
      home: Scaffold(
        body: EventTile(
          event: event,
          sessionId: 'session-1',
          userAttachmentMediaLoader: loader,
          canReplay: true,
          isEditing: true,
          editController: controller,
          editAttachments: [InlineEditAttachment.existing(existingImage())],
        ),
      ),
    );

    await tester.pumpWidget(host(firstLoader));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(secondLoader));
    await tester.pumpAndSettle();

    expect(firstLoader.loadedIds, ['existing-image-1']);
    expect(secondLoader.loadedIds, isEmpty);
  });
}
