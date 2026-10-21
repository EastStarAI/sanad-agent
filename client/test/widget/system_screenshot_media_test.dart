import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';

Widget _app(Widget child, {double width = 800}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: width, height: 700, child: child),
  ),
);

final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _FakeMediaLoader implements ViewImageMediaLoader {
  _FakeMediaLoader.completed(Uint8List bytes)
      : _completer = Completer<Uint8List>()..complete(bytes);

  final Completer<Uint8List> _completer;
  bool cancelled = false;

  @override
  ViewImageMediaLoad load({
    required ViewImageMedia media,
    required String sessionId,
  }) => ViewImageMediaLoad(
    bytes: _completer.future,
    cancel: () => cancelled = true,
  );
}

Map<String, dynamic> _screenshotMediaJson({String availability = 'available'}) => {
  'media_id': List.filled(64, 'e').join(),
  'name': 'view-image.png',
  'mime_type': 'image/png',
  'width': 1920,
  'height': 1080,
  'availability': availability,
};

CanonicalEvent _screenshotEvent({
  EventStatus status = EventStatus.done,
  bool isError = false,
  Map<String, dynamic>? media,
  String output = 'Screenshot taken successfully from monitor 1',
}) => CanonicalEvent(
  id: 'tool_system_screenshot_1',
  kind: EventKind.toolCall,
  status: status,
  sessionId: 'session-screenshot-1',
  tool: {
    'name': 'system_screenshot',
    'input': {'monitor_number': 1},
    'output': output,
    if (media != null) 'media': media,
  },
  timestamp: DateTime.utc(2026, 10, 18),
);

void main() {
  testWidgets(
    'system_screenshot event with media renders thumbnail and opens lightbox',
    (tester) async {
      final loader = _FakeMediaLoader.completed(_onePixelPng);
      final event = _screenshotEvent(media: _screenshotMediaJson());

      await tester.pumpWidget(
        _app(
          EventTile(
            event: event,
            viewImageMediaLoader: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('view_image_thumbnail')), findsOneWidget);

      // Tap thumbnail to open lightbox
      await tester.tap(find.byKey(const Key('view_image_thumbnail')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('view_image_lightbox')), findsOneWidget);
      expect(find.byKey(const Key('view_image_lightbox_close')), findsOneWidget);

      // Close lightbox
      await tester.tap(find.byKey(const Key('view_image_lightbox_close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('view_image_lightbox')), findsNothing);
    },
  );

  testWidgets(
    'system_screenshot in running status renders executing progress indicator',
    (tester) async {
      final runningEvent = _screenshotEvent(
        status: EventStatus.running,
        output: '',
      );

      await tester.pumpWidget(
        _app(
          EventTile(
            event: runningEvent,
            isExpanded: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppProgressIndicator), findsWidgets);
      expect(find.text('Executing tool...'), findsOneWidget);
      expect(find.byKey(const Key('view_image_error')), findsNothing);
      expect(find.byKey(const Key('view_image_thumbnail')), findsNothing);
    },
  );

  testWidgets(
    'system_screenshot with error renders error box and failure message',
    (tester) async {
      final errorEvent = _screenshotEvent(
        status: EventStatus.error,
        isError: true,
        output: 'System.screenshot failed: Missing Accessibility permissions.',
      );

      await tester.pumpWidget(
        _app(
          EventTile(
            event: errorEvent,
            isExpanded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('view_image_error')), findsOneWidget);
      expect(find.byKey(const Key('view_image_error_message')), findsOneWidget);
      expect(
        find.textContaining('Missing Accessibility permissions'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'text-only system_screenshot keeps its summary and saved path visible',
    (tester) async {
      final textOnlyEvent = _screenshotEvent(
        output:
            'Screenshot taken successfully from monitor 1 , imagePaht: /tmp/screenshot_1.jpg ',
      );

      await tester.pumpWidget(
        _app(
          EventTile(
            event: textOnlyEvent,
            isExpanded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Screenshot taken successfully from monitor 1'),
        findsOneWidget,
      );
      expect(
        find.textContaining('/tmp/screenshot_1.jpg'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('view_image_unavailable')), findsNothing);
      expect(find.byKey(const Key('view_image_thumbnail')), findsNothing);
    },
  );

  testWidgets(
    'system_screenshot with rejected media metadata keeps the unavailable surface',
    (tester) async {
      final invalidMediaEvent = _screenshotEvent(
        media: {
          'media_id': 'not-an-opaque-id',
          'name': 'arbitrary.png',
          'mime_type': 'image/png',
          'width': 1920,
          'height': 1080,
          'availability': 'available',
        },
      );

      await tester.pumpWidget(
        _app(
          EventTile(
            event: invalidMediaEvent,
            isExpanded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('view_image_unavailable')), findsOneWidget);
      expect(find.byKey(const Key('view_image_thumbnail')), findsNothing);
    },
  );
}
