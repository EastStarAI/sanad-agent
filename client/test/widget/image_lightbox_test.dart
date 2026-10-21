import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/media/image_download_saver.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/media/image_lightbox.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/responsive_media_gallery.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/view_image_tool_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/app_platform.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const prev = ImageLightbox.previousKey;
  const next = ImageLightbox.nextKey;
  const download = ImageLightbox.downloadKey;
  const counter = ImageLightbox.counterKey;
  const message = ImageLightbox.messageKey;
  const lightbox = Key('view_image_lightbox');

  String counterText(WidgetTester tester) => tester.widget<Text>(find.byKey(counter)).data!;
  bool enabled(WidgetTester tester, Key key) => tester.widget<IconButton>(find.byKey(key)).onPressed != null;
  Uint8List shownBytes(WidgetTester tester) {
    final image = tester.widget<Image>(
      find.descendant(of: find.byKey(lightbox), matching: find.byType(Image)),
    );
    return (image.image as MemoryImage).bytes;
  }

  Future<_GalleryLoader> pumpGallery(
    WidgetTester tester, {
    int count = 3,
    TextDirection direction = TextDirection.ltr,
    ImageDownloadSaver? saver,
    bool provideSaver = true,
  }) async {
    final loader = _GalleryLoader();
    final events = [for (var i = 0; i < count; i++) _viewImageEvent('img-$i', String.fromCharCode(0x61 + i))];
    await tester.pumpWidget(
      _app(
        direction: direction,
        saver: saver,
        provideSaver: provideSaver,
        child: ResponsiveMediaGallery(events: events, viewImageMediaLoader: loader),
      ),
    );
    await tester.pumpAndSettle();
    return loader;
  }

  Future<void> openThumbnail(WidgetTester tester, int index) async {
    await tester.tap(find.byKey(const Key('view_image_thumbnail')).at(index));
    await tester.pumpAndSettle();
    expect(find.byKey(lightbox), findsOneWidget);
  }

  group('lightbox group navigation', () {
    testWidgets('arrows move through the gallery and stop at the ends', (tester) async {
      final loader = await pumpGallery(tester);
      await openThumbnail(tester, 1);

      expect(counterText(tester), '2 / 3');
      expect(shownBytes(tester), same(loader.bytesFor('b')));

      await tester.tap(find.byKey(next));
      await tester.pumpAndSettle();
      expect(counterText(tester), '3 / 3');
      expect(shownBytes(tester), same(loader.bytesFor('c')));
      expect(enabled(tester, next), isFalse, reason: 'stops at the last image (no wrap)');

      await tester.tap(find.byKey(prev));
      await tester.tap(find.byKey(prev));
      await tester.pumpAndSettle();
      expect(counterText(tester), '1 / 3');
      expect(shownBytes(tester), same(loader.bytesFor('a')));
      expect(enabled(tester, prev), isFalse, reason: 'stops at the first image (no wrap)');

      // Navigation reuses the cards' own loads: one load per image.
      expect(loader.loads, {'a': 1, 'b': 1, 'c': 1});
    });

    testWidgets('a single image shows no arrows and no counter', (tester) async {
      await tester.pumpWidget(
        _app(
          saver: _FakeSaver(),
          child: ViewImageToolCard(event: _viewImageEvent('only', 'a'), loader: _GalleryLoader()),
        ),
      );
      await tester.pumpAndSettle();
      await openThumbnail(tester, 0);

      expect(find.byKey(prev), findsNothing);
      expect(find.byKey(next), findsNothing);
      expect(find.byKey(counter), findsNothing);
      expect(find.byKey(download), findsOneWidget);
      expect(find.byKey(const Key('view_image_lightbox_close')), findsOneWidget);
    });

    testWidgets('a one-image gallery also hides the arrows', (tester) async {
      await pumpGallery(tester, count: 1);
      await openThumbnail(tester, 0);
      expect(find.byKey(prev), findsNothing);
      expect(find.byKey(next), findsNothing);
    });

    testWidgets('keyboard arrows navigate in LTR', (tester) async {
      await pumpGallery(tester);
      await openThumbnail(tester, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(counterText(tester), '2 / 3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(counterText(tester), '3 / 3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(counterText(tester), '2 / 3');
    });

    testWidgets('RTL places next on the left and maps keys to reading direction', (tester) async {
      await pumpGallery(tester, direction: TextDirection.rtl);
      await openThumbnail(tester, 0);

      expect(
        tester.getCenter(find.byKey(next)).dx,
        lessThan(tester.getCenter(find.byKey(prev)).dx),
        reason: 'next is on the left in Arabic',
      );
      final nextIcon = tester.widget<Icon>(find.descendant(of: find.byKey(next), matching: find.byType(Icon)));
      expect(nextIcon.icon, Icons.chevron_left);

      await tester.tap(find.byKey(next));
      await tester.pumpAndSettle();
      expect(counterText(tester), '2 / 3');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(counterText(tester), '3 / 3', reason: 'ArrowLeft is next in RTL');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(counterText(tester), '2 / 3', reason: 'ArrowRight is previous in RTL');
    });

    testWidgets('user attachment images form one group in message order', (tester) async {
      final loader = _AttachmentLoader();
      final event = CanonicalEvent(
        id: 'msg',
        kind: EventKind.userMessage,
        text: '',
        timestamp: DateTime.utc(2026, 10, 21),
        sessionId: 'session-1',
        metadata: {
          'attachments': [
            _attachmentJson(id: 'image-1', kind: 'image', name: 'first.png'),
            _attachmentJson(id: 'file-1', kind: 'file', mimeType: 'text/plain', name: 'notes.txt'),
            _attachmentJson(id: 'image-2', kind: 'image', name: 'second.png'),
          ],
        },
      );
      await tester.pumpWidget(
        _app(
          saver: _FakeSaver(),
          child: SizedBox(
            width: 600,
            child: UserMessageTile(event: event, attachmentMediaLoader: loader),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open_user_attachment_image-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('user_attachment_lightbox')), findsOneWidget);
      expect(counterText(tester), '2 / 2', reason: 'the file attachment is not part of the image group');
      await tester.tap(find.byKey(prev));
      await tester.pumpAndSettle();
      expect(counterText(tester), '1 / 2');
      expect(loader.loads, {'image-1': 1, 'image-2': 1});
    });
  });

  group('lightbox download', () {
    late Directory downloads;

    setUp(() async {
      downloads = await Directory.systemTemp.createTemp('sanad_lightbox_downloads_');
    });

    tearDown(() async {
      if (await downloads.exists()) await downloads.delete(recursive: true);
    });

    testWidgets('writes the shown image to the injected Downloads directory with a clash suffix '
        'and no refetch', (tester) async {
      const base = 'image-20261021-090507';
      await tester.runAsync(() => File('${downloads.path}/$base.png').writeAsBytes(const [1]));
      final loader = await pumpGallery(
        tester,
        saver: DownloadsDirectoryImageSaver(
          downloadsDirectory: () async => downloads,
          clock: () => DateTime(2026, 10, 21, 9, 5, 7),
        ),
      );
      await openThumbnail(tester, 1);

      await tester.tap(find.byKey(download));
      final target = File('${downloads.path}/$base (1).png');
      // Real file I/O completes outside fake time; alternate real waits with
      // pumps until the lightbox reports the outcome.
      for (var i = 0; i < 200 && find.byKey(message).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }

      expect(await tester.runAsync(target.readAsBytes), _png);
      final original = await tester.runAsync(() => File('${downloads.path}/$base.png').readAsBytes());
      expect(original, [1], reason: 'an existing file is never overwritten');
      final names = await tester.runAsync(
        () => downloads.list().map((entity) => entity.uri.pathSegments.last).toList(),
      );
      expect(names!..sort(), ['$base (1).png', '$base.png']);
      expect(tester.widget<Text>(find.byKey(message)).data, 'Saved $base (1).png to Downloads');
      expect(loader.loads, {'a': 1, 'b': 1, 'c': 1}, reason: 'download reuses the lightbox bytes');
    });

    testWidgets('an attachment downloads under its safe name hint', (tester) async {
      final saver = _FakeSaver();
      final event = CanonicalEvent(
        id: 'msg',
        kind: EventKind.userMessage,
        text: '',
        timestamp: DateTime.utc(2026, 10, 21),
        sessionId: 'session-1',
        metadata: {
          'attachments': [_attachmentJson(id: 'image-1', kind: 'image', name: 'holiday.png')],
        },
      );
      await tester.pumpWidget(
        _app(
          saver: saver,
          child: SizedBox(width: 600, child: UserMessageTile(event: event, attachmentMediaLoader: _AttachmentLoader())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open_user_attachment_image-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(download));
      await tester.pumpAndSettle();

      expect(saver.preferredNames, ['holiday.png']);
      expect(saver.savedBytes.single, _png);
      expect(tester.widget<Text>(find.byKey(message)).data, 'Saved image.png to Downloads');
    });

    testWidgets('shows the localized failure message in English and Arabic', (tester) async {
      for (final locale in const [Locale('en'), Locale('ar')]) {
        await tester.pumpWidget(
          _app(
            locale: locale,
            saver: _FakeSaver(error: const ImageDownloadException('disk_full')),
            child: ResponsiveMediaGallery(
              events: [_viewImageEvent('img-0', 'a'), _viewImageEvent('img-1', 'b')],
              viewImageMediaLoader: _GalleryLoader(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openThumbnail(tester, 0);
        await tester.tap(find.byKey(download));
        await tester.pumpAndSettle();

        final expected = lookupAppLocalizations(locale).lightboxDownloadFailed;
        expect(tester.widget<Text>(find.byKey(message)).data, expected);
        if (locale.languageCode == 'ar') {
          expect(expected, isNot(lookupAppLocalizations(const Locale('en')).lightboxDownloadFailed));
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Web saver hands the bytes to a browser download and reports the started name', (tester) async {
      String? triggeredName;
      String? triggeredMime;
      final saver = BrowserImageDownloadSaver(
        trigger: (bytes, name, mimeType) async {
          triggeredName = name;
          triggeredMime = mimeType;
        },
        clock: () => DateTime(2026, 10, 21, 9, 5, 7),
      );
      await pumpGallery(tester, saver: saver);
      await openThumbnail(tester, 0);
      await tester.tap(find.byKey(download));
      await tester.pumpAndSettle();

      expect(triggeredName, 'image-20261021-090507.png');
      expect(triggeredMime, 'image/png');
      expect(tester.widget<Text>(find.byKey(message)).data, 'Downloading image-20261021-090507.png');
    });

    testWidgets('mobile has no saver, so the Download control is hidden', (tester) async {
      await pumpGallery(tester, saver: null, provideSaver: true);
      await openThumbnail(tester, 0);
      expect(find.byKey(download), findsNothing);
      expect(find.byKey(next), findsOneWidget, reason: 'navigation is independent of download');
    });

    test('platform saver: Downloads on desktop, none on mobile', () {
      addTearDown(() {
        AppPlatform.overrideIsDesktop = null;
        AppPlatform.overrideIsMobile = null;
      });
      AppPlatform.overrideIsDesktop = true;
      expect(ImageDownloadSaver.forPlatform(), isA<DownloadsDirectoryImageSaver>());
      AppPlatform.overrideIsDesktop = false;
      AppPlatform.overrideIsMobile = true;
      expect(ImageDownloadSaver.forPlatform(), isNull);
    });
  });
}

Widget _app({
  required Widget child,
  TextDirection direction = TextDirection.ltr,
  Locale? locale,
  ImageDownloadSaver? saver,
  bool provideSaver = true,
}) {
  final body = provideSaver ? ImageDownloadSaverScope(saver: saver, child: child) : child;
  return MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: locale == null ? (context, app) => Directionality(textDirection: direction, child: app!) : null,
    home: Scaffold(body: SingleChildScrollView(child: SizedBox(width: 800, child: body))),
  );
}

CanonicalEvent _viewImageEvent(String id, String mediaChar) => CanonicalEvent(
  id: id,
  kind: EventKind.toolCall,
  status: EventStatus.done,
  sessionId: 'session-1',
  tool: {
    'name': 'view_image',
    'output': 'Image Size: 1x1.',
    'media': {
      'media_id': List.filled(64, mediaChar).join(),
      'name': 'view-image.png',
      'mime_type': 'image/png',
      'width': 1,
      'height': 1,
      'availability': 'available',
    },
  },
  timestamp: DateTime.utc(2026, 10, 21),
);

Map<String, dynamic> _attachmentJson({
  required String id,
  required String kind,
  String mimeType = 'image/png',
  String name = 'photo.png',
}) => {
  'schemaVersion': 1,
  'id': id,
  'safeName': name,
  'mimeType': mimeType,
  'sizeBytes': 68,
  'sha256': 'a' * 64,
  'kind': kind,
  'mediaId': 'media-$id',
  'status': 'available',
};

/// Distinct byte instances per media so the shown image is identifiable.
class _GalleryLoader implements ViewImageMediaLoader {
  final Map<String, Uint8List> _bytes = {};
  final Map<String, int> loads = {};

  Uint8List bytesFor(String mediaChar) => _bytes.putIfAbsent(mediaChar, () => Uint8List.fromList(_png));

  @override
  ViewImageMediaLoad load({required ViewImageMedia media, required String sessionId}) {
    final key = media.mediaId[0];
    loads[key] = (loads[key] ?? 0) + 1;
    return ViewImageMediaLoad(bytes: Future.value(bytesFor(key)), cancel: () {});
  }
}

class _AttachmentLoader implements UserAttachmentMediaLoader {
  final Map<String, int> loads = {};

  @override
  ViewImageMediaLoad loadAttachment({required UserMessageAttachment attachment, required String sessionId}) {
    loads[attachment.id] = (loads[attachment.id] ?? 0) + 1;
    return ViewImageMediaLoad(bytes: Future.value(Uint8List.fromList(_png)), cancel: () {});
  }
}

class _FakeSaver implements ImageDownloadSaver {
  _FakeSaver({this.error});

  final Object? error;
  final List<String?> preferredNames = [];
  final List<Uint8List> savedBytes = [];

  @override
  Future<ImageDownloadResult> save({required Uint8List bytes, String? preferredName}) async {
    preferredNames.add(preferredName);
    savedBytes.add(bytes);
    if (error != null) throw error!;
    return const ImageDownloadResult(fileName: 'image.png', outcome: ImageDownloadOutcome.saved);
  }
}
