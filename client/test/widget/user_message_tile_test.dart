import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';
import 'package:sanad_client/utils/toast_utils.dart';

void main() {
  testWidgets('short user message does not show Read more', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-1',
      kind: EventKind.userMessage,
      text: 'Short message',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(event: event),
        ),
      ),
    );

    expect(find.text('Read more'), findsNothing);
    expect(find.text('See less'), findsNothing);
  });

  testWidgets('long user message with > 5 lines shows Read more and toggles to See less when tapped', (tester) async {
    final longText = List.generate(10, (index) => 'Line ${index + 1}').join('\n');
    final event = CanonicalEvent(
      id: 'msg-2',
      kind: EventKind.userMessage,
      text: longText,
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UserMessageTile(event: event),
          ),
        ),
      ),
    );

    expect(find.text('Read more'), findsOneWidget);
    expect(find.text('See less'), findsNothing);

    // Tap anywhere on the message tile
    await tester.tap(find.text('Read more'));
    await tester.pumpAndSettle();

    expect(find.text('Read more'), findsNothing);
    expect(find.text('See less'), findsOneWidget);

    // Tap again to collapse
    await tester.tap(find.text('See less'));
    await tester.pumpAndSettle();

    expect(find.text('Read more'), findsOneWidget);
    expect(find.text('See less'), findsNothing);
  });

  testWidgets('single-line user message renders without newlines', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-single',
      kind: EventKind.userMessage,
      text: 'Single line message',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(event: event),
        ),
      ),
    );

    expect(find.text('Single line message'), findsOneWidget);
    expect(find.text('Read more'), findsNothing);
  });

  testWidgets('two-line Shift+Enter message renders as two lines', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-two-lines',
      kind: EventKind.userMessage,
      text: 'First line\nSecond line',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(event: event),
        ),
      ),
    );

    // MarkdownBody preserves soft line break so \n is kept rather than collapsed into a space
    expect(find.text('First line\nSecond line'), findsOneWidget);
    expect(find.text('First line Second line'), findsNothing);
  });

  testWidgets('file link renders as a chip with icon+name and does not trigger external open', (tester) async {
    String? openedUrl;
    final event = CanonicalEvent(
      id: 'msg-file-link',
      kind: EventKind.userMessage,
      text: 'Review this file: [spec.dart](file:///workspace/lib/spec.dart)',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(
            event: event,
            onOpenUrl: (url) async {
              openedUrl = url;
            },
          ),
        ),
      ),
    );

    // Renders the custom chip
    expect(find.byType(UserMessageFileChip), findsOneWidget);
    expect(find.byKey(const Key('user_message_file_chip')), findsOneWidget);

    // FileExtensionIcon is displayed
    expect(find.byType(FileExtensionIcon), findsOneWidget);

    // File name is displayed
    expect(find.text('spec.dart'), findsOneWidget);

    // Raw path is not displayed as plain text
    expect(find.text('file:///workspace/lib/spec.dart'), findsNothing);

    // Tooltip contains full path
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const Key('user_message_file_chip')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, contains('spec.dart'));

    // Tapping the chip does not trigger external open
    await tester.tap(find.byType(UserMessageFileChip));
    await tester.pump();
    expect(openedUrl, isNull);
  });

  testWidgets('file link without label extracts file name from URI', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-file-autolink',
      kind: EventKind.userMessage,
      text: '<file:///workspace/docs/guide.pdf>',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(event: event),
        ),
      ),
    );

    expect(find.byType(UserMessageFileChip), findsOneWidget);
    expect(find.text('guide.pdf'), findsOneWidget);
    expect(find.text('file:///workspace/docs/guide.pdf'), findsNothing);
  });

  testWidgets('https links remain unchanged and trigger open on tap', (tester) async {
    String? openedUrl;
    final event = CanonicalEvent(
      id: 'msg-https-link',
      kind: EventKind.userMessage,
      text: 'Visit [Sanad Website](https://sanad.ai)',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(
            event: event,
            onOpenUrl: (url) async {
              openedUrl = url;
            },
          ),
        ),
      ),
    );

    // No file chip is rendered
    expect(find.byType(UserMessageFileChip), findsNothing);

    // The link stays inline: it merges into the paragraph text instead of
    // becoming a separately wrapped widget.
    expect(find.text('Visit Sanad Website', findRichText: true), findsOneWidget);

    // Tapping the link span triggers external open
    await tester.tapOnText(find.textRange.ofSubstring('Sanad Website'));
    await tester.pump();

    expect(openedUrl, 'https://sanad.ai');
  });

  testWidgets('Read more line-count logic behaves with multi-line Shift+Enter messages', (tester) async {
    final sixLineText = List.generate(6, (index) => 'Shift Enter line ${index + 1}').join('\n');
    final event = CanonicalEvent(
      id: 'msg-six-lines',
      kind: EventKind.userMessage,
      text: sixLineText,
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UserMessageTile(event: event),
          ),
        ),
      ),
    );

    expect(find.text('Read more'), findsOneWidget);
    expect(find.text('See less'), findsNothing);

    await tester.tap(find.text('Read more'));
    await tester.pumpAndSettle();

    expect(find.text('Read more'), findsNothing);
    expect(find.text('See less'), findsOneWidget);

    await tester.tap(find.text('See less'));
    await tester.pumpAndSettle();

    expect(find.text('Read more'), findsOneWidget);
    expect(find.text('See less'), findsNothing);
  });

  testWidgets('CopyButton copies stored message text with file reference and newlines', (tester) async {
    const rawText = 'Notes:\n[config.json](file:///etc/config.json)';
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text']?.toString();
        }
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final event = CanonicalEvent(
      id: 'msg-copy-raw',
      kind: EventKind.userMessage,
      text: rawText,
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(event: event),
        ),
      ),
    );

    final copyButton = tester.widget<CopyButton>(find.byType(CopyButton));
    expect(copyButton.text, rawText);

    await tester.tap(find.byType(CopyButton));
    await tester.pump();

    expect(copiedText, rawText);
    await tester.pump(ToastUtils.defaultDuration);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('Shift+Enter newline renders as a real line break and increases body height', (tester) async {
    Future<double> bodyHeight(String id, String text) async {
      final event = CanonicalEvent(
        id: id,
        kind: EventKind.userMessage,
        text: text,
        timestamp: DateTime.utc(2026, 7, 23),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UserMessageTile(event: event),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byKey(Key('user_message_body:$id'))).height;
    }

    final singleLineHeight = await bodyHeight('msg-height-single', 'First line');
    final twoLineHeight = await bodyHeight('msg-height-double', 'First line\nSecond line');

    expect(twoLineHeight, greaterThan(singleLineHeight));
  });

  testWidgets('fenced code block in a user message keeps its newlines and block rendering', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-code-block',
      kind: EventKind.userMessage,
      text: 'Steps:\n```dart\nfinal a = 1;\nfinal b = 2;\n```',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UserMessageTile(event: event),
          ),
        ),
      ),
    );

    final codeBlock = tester.widget<AppCodeBlock>(find.byType(AppCodeBlock));
    expect(codeBlock.codeText, 'final a = 1;\nfinal b = 2;');
    expect(codeBlock.language, 'dart');
    expect(tester.takeException(), isNull);
  });

  testWidgets('file chip decodes percent-encoded name and exposes decoded full path in tooltip', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-file-encoded',
      kind: EventKind.userMessage,
      text: '[My Report.pdf](file:///Users/ahmed/My%20Documents/My%20Report.pdf)',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(event: event),
        ),
      ),
    );

    expect(find.byType(UserMessageFileChip), findsOneWidget);
    expect(find.text('My Report.pdf'), findsOneWidget);
    expect(find.textContaining('%20'), findsNothing);

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const Key('user_message_file_chip')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, '/Users/ahmed/My Documents/My Report.pdf');
  });

  testWidgets('multiple file references render as separate chips and https links still open', (tester) async {
    String? openedUrl;
    final event = CanonicalEvent(
      id: 'msg-multi-chips',
      kind: EventKind.userMessage,
      text:
          'Compare [a.dart](file:///workspace/a.dart) and [b.dart](file:///workspace/b.dart), then see [docs](https://sanad.ai/docs)',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    Widget host() => MaterialApp(
      home: Scaffold(
        body: UserMessageTile(
          event: event,
          onOpenUrl: (url) async {
            openedUrl = url;
          },
        ),
      ),
    );

    await tester.pumpWidget(host());
    // A second pump forces an element update for the inline chip children.
    await tester.pumpWidget(host());

    expect(find.byType(UserMessageFileChip), findsNWidgets(2));
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('b.dart'), findsOneWidget);

    await tester.tap(find.text('b.dart'));
    await tester.pump();
    expect(openedUrl, isNull);

    await tester.tapOnText(find.textRange.ofSubstring('docs'));
    await tester.pump();
    expect(openedUrl, 'https://sanad.ai/docs');
  });

  testWidgets('file chips and links stay inline with the surrounding paragraph text', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-inline-flow',
      kind: EventKind.userMessage,
      text: 'Before [a.dart](file:///workspace/a.dart) middle [docs](https://sanad.ai/docs) after',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UserMessageTile(event: event)),
      ),
    );

    final body = find.byKey(const Key('user_message_body:msg-inline-flow'));
    // One paragraph: the chip is a WidgetSpan and the link a TextSpan of a
    // single merged rich text, so no Wrap splits the line around them.
    final paragraphs = tester.widgetList<Wrap>(find.descendant(of: body, matching: find.byType(Wrap)));
    expect(paragraphs, hasLength(1));
    expect(paragraphs.single.children, hasLength(1));
    expect(find.text('Before \uFFFC middle docs after', findRichText: true), findsOneWidget);
    expect(find.byType(UserMessageFileChip), findsOneWidget);
  });

  testWidgets('long file reference URIs do not trigger Read more for a short message', (tester) async {
    final longDir = List.generate(12, (index) => 'very-long-directory-segment-$index').join('/');
    final text = List.generate(
      3,
      (index) => '[file$index.md](${Uri.file('/$longDir/file$index.md')})',
    ).join(' ');
    final event = CanonicalEvent(
      id: 'msg-long-uris',
      kind: EventKind.userMessage,
      text: 'See $text',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UserMessageTile(event: event)),
      ),
    );

    expect(find.byType(UserMessageFileChip), findsNWidgets(3));
    expect(find.text('Read more'), findsNothing);
  });

  test('measurableText collapses file links to their names and keeps other links', () {
    expect(
      UserMessageLinkBuilder.measurableText('a [x.md](file:///tmp/My%20(1)/x.md) b [y](https://e.com) c'),
      'a \u2003x.md b [y](https://e.com) c',
    );
  });

  testWidgets('file chip renders inside RTL Arabic message and keeps RTL direction', (tester) async {
    final event = CanonicalEvent(
      id: 'msg-file-rtl',
      kind: EventKind.userMessage,
      text: 'راجع هذا الملف [spec.dart](file:///workspace/spec.dart) قبل الإرسال',
      timestamp: DateTime.utc(2026, 7, 23),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(event: event),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(UserMessageFileChip), findsOneWidget);
    expect(find.text('spec.dart'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(UserMessageFileChip))),
      TextDirection.rtl,
    );
  });

  testWidgets(
    'renders ordered image and file attachments with unavailable and lightbox states',
    (tester) async {
      final loader = _FakeAttachmentLoader();
      final event = CanonicalEvent(
        id: 'msg-attachments',
        kind: EventKind.userMessage,
        text: 'Attachments',
        timestamp: DateTime.utc(2026, 9, 16),
        sessionId: 'session-1',
        metadata: {
          'attachments': [
            _attachmentJson(id: 'image-1', kind: 'image'),
            _attachmentJson(
              id: 'file-1',
              kind: 'file',
              mimeType: 'text/plain',
              name: 'report.txt',
            ),
            _attachmentJson(
              id: 'image-2',
              kind: 'image',
              status: 'unavailable',
            ),
          ],
        },
      );

      expect(event.userAttachments.map((item) => item.id), [
        'image-1',
        'file-1',
        'image-2',
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: UserMessageTile(
                event: event,
                attachmentMediaLoader: loader,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('user_attachment_grid')), findsOneWidget);
      expect(find.byKey(const ValueKey('user_attachment_image-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('user_attachment_file-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('user_attachment_image-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('user_file_attachment_file-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('user_attachment_unavailable_image-2')),
        findsOneWidget,
      );
      expect(loader.loadedIds, ['image-1']);

      await tester.tap(
        find.byKey(const ValueKey('open_user_attachment_image-1')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('user_attachment_lightbox')), findsOneWidget);
      await tester.tap(find.byKey(const Key('user_attachment_lightbox_close')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('user_file_attachment_file-1')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('user_attachment_text_preview')),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(loader.loadedIds, ['image-1', 'file-1']);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(loader.cancelCount, 2);
    },
  );

  test('attachment parser accepts canonical history shape and rejects private fields', () {
    final event = CanonicalEvent(
      id: 'history-message',
      kind: EventKind.userMessage,
      timestamp: DateTime.utc(2026, 9, 16),
      metadata: {
        'attachments': [_attachmentJson(id: 'history-1', kind: 'image')],
      },
    );
    final privateEvent = CanonicalEvent(
      id: 'private-message',
      kind: EventKind.userMessage,
      timestamp: DateTime.utc(2026, 9, 16),
      metadata: {
        'attachments': [
          {
            ..._attachmentJson(id: 'private', kind: 'file'),
            'agentLocalReference': '/private/path',
          },
        ],
      },
    );

    expect(event.userAttachments, hasLength(1));
    expect(event.userAttachments.single.id, 'history-1');
    expect(privateEvent.userAttachments, isEmpty);
  });

  test('live and history mappers preserve identical typed attachment projection', () {
    final mapper = UnifiedDeviceMapper();
    final attachments = [_attachmentJson(id: 'image-1', kind: 'image')];
    final live = mapper.mapLiveEvent({
      'type': 'user_message',
      'event_id': 'live-1',
      'session_id': 'session-1',
      'text': 'Attached',
      'timestamp': '2026-09-16T00:00:00Z',
      'attachments': attachments,
    });
    final history = mapper.mapHistory([
      {
        'id': 'history-1',
        'type': 'user_message',
        'session_id': 'session-1',
        'content': 'Attached',
        'created_at': '2026-09-16T00:00:00Z',
        'attachments': attachments,
      },
    ]).single;

    expect(live, isNotNull);
    expect(live!.userAttachments.map((item) => item.id), ['image-1']);
    expect(history.userAttachments.map((item) => item.id), ['image-1']);
  });

  test('attachment repository uses authenticated scoped route and metadata-only cache key', () async {
    var requests = 0;
    late http.Request captured;
    final client = MockClient((request) async {
      requests += 1;
      captured = request;
      return http.Response.bytes(
        const [1, 2, 3],
        200,
        headers: {
          'content-type': 'image/png',
          'content-length': '3',
        },
      );
    });
    final repository = ViewImageMediaRepository(
      baseUrl: 'http://127.0.0.1:1234',
      hardwareId: 'hardware-1',
      headerProvider: () async => {'x-sanad-local-token': 'credential'},
      clientFactory: () => client,
    );
    final attachment = UserMessageAttachment.fromJson(
      _attachmentJson(id: 'image-1', kind: 'image'),
    )!;

    final first = repository.loadAttachment(
      attachment: attachment,
      sessionId: 'session-1',
    );
    await first.bytes;
    final second = repository.loadAttachment(
      attachment: attachment,
      sessionId: 'session-1',
    );
    await second.bytes;

    expect(requests, 1);
    expect(captured.url.path, '/media/attachment/media-image-1');
    expect(captured.url.queryParameters, {
      'session_id': 'session-1',
      'device_id': 'hardware-1',
    });
    expect(captured.headers['x-sanad-local-token'], 'credential');
    expect(captured.url.toString(), isNot(contains('credential')));
  });

  testWidgets('file attachments show their type icon while images keep a preview', (tester) async {
    final loader = _FakeAttachmentLoader();
    final event = CanonicalEvent(
      id: 'msg-file-icons',
      kind: EventKind.userMessage,
      text: 'Files',
      timestamp: DateTime.utc(2026, 10, 21),
      sessionId: 'session-1',
      metadata: {
        'attachments': [
          _attachmentJson(id: 'image-1', kind: 'image'),
          _attachmentJson(id: 'file-1', kind: 'file', mimeType: 'application/pdf', name: 'report.pdf'),
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 600, child: UserMessageTile(event: event, attachmentMediaLoader: loader)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fileCard = find.byKey(const ValueKey('user_file_attachment_file-1'));
    final icon = find.descendant(of: fileCard, matching: find.byType(FileExtensionIcon));
    expect(icon, findsOneWidget);
    expect(tester.widget<FileExtensionIcon>(icon).fileName, 'report.pdf');
    expect(tester.widget<FileExtensionIcon>(icon).size, 28);
    expect(find.descendant(of: fileCard, matching: find.byIcon(Icons.insert_drive_file_outlined)), findsNothing);

    final imageCard = find.byKey(const ValueKey('open_user_attachment_image-1'));
    expect(find.descendant(of: imageCard, matching: find.byType(Image)), findsOneWidget);
    expect(find.descendant(of: imageCard, matching: find.byType(FileExtensionIcon)), findsNothing);
  });

  testWidgets('inline edit file chips show their type icon while images keep a preview', (tester) async {
    final controller = TextEditingController(text: 'edit');
    addTearDown(controller.dispose);
    final event = CanonicalEvent(
      id: 'msg-inline-icons',
      kind: EventKind.userMessage,
      text: 'edit',
      timestamp: DateTime.utc(2026, 10, 21),
      sessionId: 'session-1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            editAttachments: [
              const InlineEditAttachment(id: 'new-file', name: 'main.dart', sizeBytes: 12, isImage: false, isExisting: false),
              InlineEditAttachment(
                id: 'new-image',
                name: 'shot.png',
                sizeBytes: _FakeAttachmentLoader._png.length,
                isImage: true,
                isExisting: false,
                bytes: _FakeAttachmentLoader._png,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final fileChip = find.byKey(const ValueKey('inline_edit_attachment_thumbnail_new-file'));
    final icon = find.descendant(of: fileChip, matching: find.byType(FileExtensionIcon));
    expect(icon, findsOneWidget);
    expect(tester.widget<FileExtensionIcon>(icon).fileName, 'main.dart');
    expect(tester.widget<FileExtensionIcon>(icon).size, 22);

    final imageChip = find.byKey(const ValueKey('inline_edit_attachment_thumbnail_new-image'));
    expect(find.descendant(of: imageChip, matching: find.byType(Image)), findsOneWidget);
    expect(find.descendant(of: imageChip, matching: find.byType(FileExtensionIcon)), findsNothing);
  });
}

Map<String, dynamic> _attachmentJson({
  required String id,
  required String kind,
  String mimeType = 'image/png',
  String name = 'photo.png',
  String status = 'available',
}) => {
  'schemaVersion': 1,
  'id': id,
  'safeName': name,
  'mimeType': mimeType,
  'sizeBytes': 68,
  'sha256': 'a' * 64,
  'kind': kind,
  'mediaId': 'media-$id',
  'status': status,
};

class _FakeAttachmentLoader implements UserAttachmentMediaLoader {
  static final Uint8List _png = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );

  final List<String> loadedIds = [];
  int cancelCount = 0;

  @override
  ViewImageMediaLoad loadAttachment({
    required UserMessageAttachment attachment,
    required String sessionId,
  }) {
    loadedIds.add(attachment.id);
    return ViewImageMediaLoad(
      bytes: Future.value(_png),
      cancel: () => cancelCount += 1,
    );
  }
}
