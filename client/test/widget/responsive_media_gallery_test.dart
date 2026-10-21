import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/responsive_media_gallery.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/tool_group_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  group('ResponsiveMediaGallery unit formula', () {
    test('calculateColumns clamps between 1 and 4 according to pinned formula', () {
      expect(ResponsiveMediaGallery.calculateColumns(0), 1);
      expect(ResponsiveMediaGallery.calculateColumns(-50), 1);
      // minItem = 160, spacing = 8 => minItem + spacing = 168
      // width 320: (320 + 8) / 168 = 1.95 -> 1
      expect(ResponsiveMediaGallery.calculateColumns(320), 1);
      // width 400: (400 + 8) / 168 = 2.42 -> 2
      expect(ResponsiveMediaGallery.calculateColumns(400), 2);
      // width 600: (600 + 8) / 168 = 3.61 -> 3
      expect(ResponsiveMediaGallery.calculateColumns(600), 3);
      // width 1200: (1200 + 8) / 168 = 7.19 -> clamped to 4
      expect(ResponsiveMediaGallery.calculateColumns(1200), 4);
      // very wide: clamped to 4
      expect(ResponsiveMediaGallery.calculateColumns(2560), 4);
    });

    test('calculateItemWidth computes exact item width for columns', () {
      expect(ResponsiveMediaGallery.calculateItemWidth(320, 1), 320.0);
      expect(
        ResponsiveMediaGallery.calculateItemWidth(600, 3),
        closeTo((600 - 16) / 3, 0.001),
      );
      expect(
        ResponsiveMediaGallery.calculateItemWidth(1200, 4),
        closeTo((1200 - 24) / 4, 0.001),
      );
    });

    test('isMediaToolEvent predicate detects media-bearing tools accurately', () {
      final viewImage = _viewImageEvent('img-1');
      expect(ResponsiveMediaGallery.isMediaToolEvent(viewImage), isTrue);

      final screenshotWithMedia = CanonicalEvent(
        id: 'ss-1',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        tool: {
          'name': 'system_screenshot',
          'media': _mediaJson('b'),
        },
        timestamp: DateTime.utc(2026, 9, 1),
      );
      expect(ResponsiveMediaGallery.isMediaToolEvent(screenshotWithMedia), isTrue);

      final screenshotWithoutMedia = CanonicalEvent(
        id: 'ss-text',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        tool: {
          'name': 'system_screenshot',
          'output': 'Saved screenshot to /tmp/shot.png',
        },
        timestamp: DateTime.utc(2026, 9, 1),
      );
      expect(ResponsiveMediaGallery.isMediaToolEvent(screenshotWithoutMedia), isFalse);

      final shell = CanonicalEvent(
        id: 'sh-1',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        tool: {'name': 'shell_execute', 'output': 'ok'},
        timestamp: DateTime.utc(2026, 9, 1),
      );
      expect(ResponsiveMediaGallery.isMediaToolEvent(shell), isFalse);
    });
  });

  group('ResponsiveMediaGallery layout at widths 320 / 600 / 1200', () {
    testWidgets('at width 320: single media inside tool group keeps current presentation', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _nonMediaTool('sh-1', 'shell_execute'),
        _viewImageEvent('img-1'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 320, loader: loader),
      );
      await tester.pumpAndSettle();

      // ToolGroupTile starts expanded with harness
      // Single media event is rendered as EventTile with its title header
      expect(find.byType(ResponsiveMediaGallery), findsNothing);
      expect(find.byType(EventTile), findsNWidgets(2));
      expect(find.textContaining('View Image', findRichText: true), findsOneWidget);
      expect(find.byKey(const Key('view_image_thumbnail')), findsOneWidget);
    });

    testWidgets('at width 320: 2 consecutive media events wrap to 1 column (2 rows)', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _viewImageEvent('img-1'),
        _viewImageEvent('img-2'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 320, loader: loader),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ResponsiveMediaGallery), findsOneWidget);
      final thumbnails = find.byKey(const Key('view_image_thumbnail'));
      expect(thumbnails, findsNWidgets(2));

      // At width 320, columns == 1, so the two items are on separate rows (stacked vertically)
      final pos0 = tester.getTopLeft(thumbnails.at(0));
      final pos1 = tester.getTopLeft(thumbnails.at(1));
      expect(pos1.dy, greaterThan(pos0.dy));
    });

    testWidgets('at width 600: 2 consecutive media events render on one row (no one-image-per-row)', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _viewImageEvent('img-1'),
        _viewImageEvent('img-2'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 600, loader: loader),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ResponsiveMediaGallery), findsOneWidget);
      final thumbnails = find.byKey(const Key('view_image_thumbnail'));
      expect(thumbnails, findsNWidgets(2));

      // At width 600, columns == 3. Two images share the exact same vertical offset (same row)
      final pos0 = tester.getTopLeft(thumbnails.at(0));
      final pos1 = tester.getTopLeft(thumbnails.at(1));
      expect(pos0.dy, equals(pos1.dy));
      expect(pos1.dx, greaterThan(pos0.dx));
    });

    testWidgets('at width 600: 3 consecutive media events render on one row (no one-image-per-row)', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _viewImageEvent('img-1'),
        _viewImageEvent('img-2'),
        _viewImageEvent('img-3'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 600, loader: loader),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ResponsiveMediaGallery), findsOneWidget);
      final thumbnails = find.byKey(const Key('view_image_thumbnail'));
      expect(thumbnails, findsNWidgets(3));

      // All 3 images share the same vertical position (single row)
      final pos0 = tester.getTopLeft(thumbnails.at(0));
      final pos1 = tester.getTopLeft(thumbnails.at(1));
      final pos2 = tester.getTopLeft(thumbnails.at(2));
      expect(pos0.dy, equals(pos1.dy));
      expect(pos1.dy, equals(pos2.dy));
      expect(pos1.dx, greaterThan(pos0.dx));
      expect(pos2.dx, greaterThan(pos1.dx));
    });

    testWidgets('at width 600: 4 consecutive media events wrap after 3 columns', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _viewImageEvent('img-1'),
        _viewImageEvent('img-2'),
        _viewImageEvent('img-3'),
        _viewImageEvent('img-4'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 600, loader: loader),
      );
      await tester.pumpAndSettle();

      final thumbnails = find.byKey(const Key('view_image_thumbnail'));
      expect(thumbnails, findsNWidgets(4));

      final pos0 = tester.getTopLeft(thumbnails.at(0));
      final pos1 = tester.getTopLeft(thumbnails.at(1));
      final pos2 = tester.getTopLeft(thumbnails.at(2));
      final pos3 = tester.getTopLeft(thumbnails.at(3));

      // First 3 on row 0
      expect(pos0.dy, equals(pos1.dy));
      expect(pos1.dy, equals(pos2.dy));
      // 4th on row 1
      expect(pos3.dy, greaterThan(pos0.dy));
    });

    testWidgets('at width 1200: 4 consecutive media events render on one row', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _viewImageEvent('img-1'),
        _viewImageEvent('img-2'),
        _viewImageEvent('img-3'),
        _viewImageEvent('img-4'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 1200, loader: loader),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ResponsiveMediaGallery), findsOneWidget);
      final thumbnails = find.byKey(const Key('view_image_thumbnail'));
      expect(thumbnails, findsNWidgets(4));

      // At width 1200, columns == 4. All 4 fit on the first row
      final pos0 = tester.getTopLeft(thumbnails.at(0));
      final pos1 = tester.getTopLeft(thumbnails.at(1));
      final pos2 = tester.getTopLeft(thumbnails.at(2));
      final pos3 = tester.getTopLeft(thumbnails.at(3));
      expect(pos0.dy, equals(pos1.dy));
      expect(pos1.dy, equals(pos2.dy));
      expect(pos2.dy, equals(pos3.dy));
    });
  });

  group('Lightbox per tile in gallery', () {
    testWidgets('lightbox opens and closes independently per gallery tile', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _viewImageEvent('img-1'),
        _viewImageEvent('img-2'),
        _viewImageEvent('img-3'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 800, loader: loader),
      );
      await tester.pumpAndSettle();

      final thumbnails = find.byKey(const Key('view_image_thumbnail'));
      expect(thumbnails, findsNWidgets(3));

      // Open lightbox for tile 0
      await tester.tap(thumbnails.at(0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view_image_lightbox')), findsOneWidget);
      expect(find.byKey(const Key('view_image_lightbox_close')), findsOneWidget);

      // Close it
      await tester.tap(find.byKey(const Key('view_image_lightbox_close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view_image_lightbox')), findsNothing);

      // Open lightbox for tile 1
      await tester.tap(thumbnails.at(1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view_image_lightbox')), findsOneWidget);

      await tester.tap(find.byKey(const Key('view_image_lightbox_close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view_image_lightbox')), findsNothing);

      // Open lightbox for tile 2
      await tester.tap(thumbnails.at(2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view_image_lightbox')), findsOneWidget);

      await tester.tap(find.byKey(const Key('view_image_lightbox_close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view_image_lightbox')), findsNothing);
    });
  });

  group('Tile states in gallery: loading, error, unavailable', () {
    testWidgets('handles independent loading, error, unavailable, and loaded states', (tester) async {
      final pendingCompleter = Completer<Uint8List>();
      final completedCompleter = Completer<Uint8List>()..complete(onePixelPng);

      final loader = _KeyedLoader({
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa': completedCompleter,
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb': pendingCompleter,
      });

      final item = projectConversationTimeline([
        _viewImageEvent('img-loaded', mediaChar: 'a'),
        _viewImageEvent('img-loading', mediaChar: 'b'),
        _errorViewImageEvent('img-error'),
        _viewImageEvent('img-unavail', mediaChar: 'c', availability: 'unavailable'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 800, loader: loader),
      );
      await tester.pump();

      // Tile 1 is loaded
      expect(find.byKey(const Key('view_image_thumbnail')), findsOneWidget);
      // Tile 2 is loading
      expect(find.byKey(const Key('view_image_loading')), findsOneWidget);
      // Tile 3 is error
      expect(find.byKey(const Key('view_image_error')), findsOneWidget);
      expect(find.byKey(const Key('view_image_error_message')), findsOneWidget);
      // Tile 4 is unavailable
      expect(find.byKey(const Key('view_image_unavailable')), findsOneWidget);

      // Complete the pending load
      pendingCompleter.complete(onePixelPng);
      await tester.pumpAndSettle();

      // Now both tile 1 and tile 2 are loaded thumbnails
      expect(find.byKey(const Key('view_image_thumbnail')), findsNWidgets(2));
      expect(find.byKey(const Key('view_image_loading')), findsNothing);
    });
  });

  group('Interleaved tools and media runs inside ToolGroupTile', () {
    testWidgets('groups only consecutive media events and preserves non-media tools', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final item = projectConversationTimeline([
        _nonMediaTool('sh-1', 'shell_execute', output: 'command 1 output'),
        _viewImageEvent('img-1', mediaChar: 'a'),
        _viewImageEvent('img-2', mediaChar: 'b'),
        _nonMediaTool('sh-2', 'shell_execute', output: 'command 2 output'),
        _viewImageEvent('img-3', mediaChar: 'c'),
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 800, loader: loader),
      );
      await tester.pumpAndSettle();

      // One gallery for the consecutive pair [img-1, img-2]
      expect(find.byType(ResponsiveMediaGallery), findsOneWidget);
      expect(find.byKey(const Key('view_image_thumbnail')), findsNWidgets(3));

      // sh-1 and sh-2 are separate EventTiles
      // img-3 is an isolated single media event, so it is rendered as an EventTile
      // Total EventTiles = 3 (sh-1, sh-2, img-3)
      expect(find.byType(EventTile), findsNWidgets(3));
    });

    testWidgets('consecutive media-bearing system_screenshot and view_image enter the same gallery', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final screenshotWithMedia = CanonicalEvent(
        id: 'ss-1',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        sessionId: 'session-1',
        tool: {
          'name': 'system_screenshot',
          'media': _mediaJson('s'),
        },
        timestamp: DateTime.utc(2026, 9, 1),
      );
      final viewImage = _viewImageEvent('img-1', mediaChar: 'v');

      final item = projectConversationTimeline([
        screenshotWithMedia,
        viewImage,
      ]).single;

      await tester.pumpWidget(
        _appWithHarness(item, width: 800, loader: loader),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ResponsiveMediaGallery), findsOneWidget);
      expect(find.byKey(const Key('view_image_thumbnail')), findsNWidgets(2));
    });

    testWidgets('a completed text-only system_screenshot breaks a gallery run and keeps its summary', (tester) async {
      final loader = _FakeLoader.completed(onePixelPng);
      final textOnlyScreenshot = CanonicalEvent(
        id: 'ss-text',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        sessionId: 'session-1',
        tool: {
          'name': 'system_screenshot',
          'output': 'Screenshot taken successfully from monitor 1',
        },
        timestamp: DateTime.utc(2026, 9, 1),
      );
      final item = projectConversationTimeline([
        _viewImageEvent('img-1', mediaChar: 'a'),
        textOnlyScreenshot,
        _viewImageEvent('img-2', mediaChar: 'b'),
      ]).single;

      await tester.pumpWidget(_appWithHarness(item, width: 800, loader: loader));
      await tester.pumpAndSettle();

      expect(ResponsiveMediaGallery.isMediaToolEvent(textOnlyScreenshot), isFalse);
      expect(find.byType(ResponsiveMediaGallery), findsNothing);
      expect(find.byType(EventTile), findsNWidgets(3));
      expect(find.byKey(const Key('view_image_thumbnail')), findsNWidgets(2));
    });

    testWidgets('rebuilding a gallery with a new loader instance does not refetch', (tester) async {
      final first = _CountingLoader(onePixelPng);
      final second = _CountingLoader(onePixelPng);
      final item = projectConversationTimeline([
        _viewImageEvent('img-1', mediaChar: 'a'),
        _viewImageEvent('img-2', mediaChar: 'b'),
      ]).single;

      await tester.pumpWidget(_appWithHarness(item, width: 800, loader: first));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_appWithHarness(item, width: 800, loader: second));
      await tester.pumpAndSettle();

      expect(first.loads, 2);
      expect(second.loads, 0);
    });
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────────

Widget _appWithHarness(
  ConversationTimelineItem item, {
  required double width,
  required ViewImageMediaLoader loader,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: width,
      height: 700,
      child: _Harness(item: item, loader: loader),
    ),
  ),
);

class _Harness extends StatefulWidget {
  const _Harness({required this.item, required this.loader});

  final ConversationTimelineItem item;
  final ViewImageMediaLoader loader;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool _isExpanded = true;
  late final Set<String> _expandedChildren;

  @override
  void initState() {
    super.initState();
    _expandedChildren = {for (final e in widget.item.events) e.id};
  }

  @override
  Widget build(BuildContext context) {
    return ToolGroupTile(
      item: widget.item,
      isExpanded: _isExpanded,
      onToggleExpanded: (expanded) => setState(() => _isExpanded = expanded),
      expandedChildEventIds: _expandedChildren,
      viewImageMediaLoader: widget.loader,
      onChildToggleExpanded: (eventId, expanded) {
        if (expanded) {
          _expandedChildren.add(eventId);
        } else {
          _expandedChildren.remove(eventId);
        }
      },
    );
  }
}

Map<String, dynamic> _mediaJson(String character, {String availability = 'available'}) => {
  'media_id': List.filled(64, character).join(),
  'name': 'view-image.png',
  'mime_type': 'image/png',
  'width': 1,
  'height': 1,
  'availability': availability,
};

CanonicalEvent _viewImageEvent(
  String id, {
  String mediaChar = 'a',
  String availability = 'available',
}) => CanonicalEvent(
  id: id,
  kind: EventKind.toolCall,
  status: EventStatus.done,
  sessionId: 'session-1',
  tool: {
    'name': 'view_image',
    'output': 'Image Size: 1x1.',
    'media': _mediaJson(mediaChar, availability: availability),
  },
  timestamp: DateTime.utc(2026, 9, 15),
);

CanonicalEvent _errorViewImageEvent(String id) => CanonicalEvent(
  id: id,
  kind: EventKind.toolCall,
  status: EventStatus.error,
  sessionId: 'session-1',
  text: 'Image inspection failed: file not found.',
  tool: {
    'name': 'view_image',
    'isError': true,
  },
  timestamp: DateTime.utc(2026, 9, 15),
);

CanonicalEvent _nonMediaTool(String id, String name, {String output = 'done'}) => CanonicalEvent(
  id: id,
  kind: EventKind.toolCall,
  status: EventStatus.done,
  tool: {
    'name': name,
    'output': output,
  },
  timestamp: DateTime.utc(2026, 8, 14),
);

class _FakeLoader implements ViewImageMediaLoader {
  _FakeLoader.completed(Uint8List bytes) : _completer = Completer<Uint8List>()..complete(bytes);

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

class _KeyedLoader implements ViewImageMediaLoader {
  _KeyedLoader(this._completers);

  final Map<String, Completer<Uint8List>> _completers;

  @override
  ViewImageMediaLoad load({
    required ViewImageMedia media,
    required String sessionId,
  }) {
    final completer = _completers[media.mediaId] ?? (Completer<Uint8List>()..completeError('Not found'));
    return ViewImageMediaLoad(
      bytes: completer.future,
      cancel: () {},
    );
  }
}

class _CountingLoader implements ViewImageMediaLoader {
  _CountingLoader(this._bytes);

  final Uint8List _bytes;
  int loads = 0;

  @override
  ViewImageMediaLoad load({
    required ViewImageMedia media,
    required String sessionId,
  }) {
    loads++;
    return ViewImageMediaLoad(bytes: Future.value(_bytes), cancel: () {});
  }
}
