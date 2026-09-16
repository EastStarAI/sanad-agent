import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';

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
