import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/media/image_download_saver.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
final Uint8List _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]);
final Uint8List _webp = Uint8List.fromList([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBP')]);
final DateTime _now = DateTime(2026, 10, 21, 9, 5, 7);

void main() {
  group('ImageDownloadFileName', () {
    String build(Uint8List bytes, String? name) =>
        ImageDownloadFileName.build(bytes: bytes, preferredName: name, now: _now);

    test('falls back to image-<timestamp> with the real extension', () {
      expect(build(_png, null), 'image-20261021-090507.png');
      expect(build(_jpeg, ''), 'image-20261021-090507.jpg');
      expect(build(_webp, '...'), 'image-20261021-090507.webp');
    });

    test('keeps a safe name but corrects the extension to the magic bytes', () {
      expect(build(_png, 'holiday.png'), 'holiday.png');
      expect(build(_png, 'holiday.JPEG'), 'holiday.png');
      expect(build(_jpeg, 'holiday.jpeg'), 'holiday.jpeg');
      expect(build(_png, 'holiday'), 'holiday.png');
      expect(build(Uint8List.fromList([1, 2, 3]), 'notes.raw'), 'notes.raw');
    });

    test('strips separators, controls, reserved punctuation, and bidi overrides', () {
      expect(build(_png, '../../etc/passwd'), 'etcpasswd.png');
      expect(build(_png, r'C:\Users\me\shot.png'), 'CUsersmeshot.png');
      expect(build(_png, 'a\u0000b\u0007c<>:"|?*.png'), 'abc.png');
      expect(build(_png, 'evil\u202Egnp.exe'), 'evilgnp.png');
      expect(build(_png, '  .hidden.png  '), 'hidden.png');
      expect(build(_png, 'CON.png'), '_CON.png');
      expect(build(_png, '${'x' * 300}.png').length, ImageDownloadFileName.maximumStemLength + 4);
    });

    test('numbers clashes before the extension', () {
      expect(ImageDownloadFileName.withClashSuffix('a.png', 0), 'a.png');
      expect(ImageDownloadFileName.withClashSuffix('a.png', 2), 'a (2).png');
      expect(ImageDownloadFileName.withClashSuffix('a', 1), 'a (1)');
    });
  });

  group('DownloadsDirectoryImageSaver', () {
    late Directory downloads;

    setUp(() async => downloads = await Directory.systemTemp.createTemp('sanad_downloads_'));
    tearDown(() async => downloads.delete(recursive: true));

    DownloadsDirectoryImageSaver saver() =>
        DownloadsDirectoryImageSaver(downloadsDirectory: () async => downloads, clock: () => _now);

    test('writes into Downloads and never overwrites on a clash', () async {
      final first = await saver().save(bytes: _png, preferredName: 'shot.png');
      final second = await saver().save(bytes: _png, preferredName: 'shot.png');
      final third = await saver().save(bytes: _png, preferredName: '../shot.png');

      expect([first.fileName, second.fileName, third.fileName], ['shot.png', 'shot (1).png', 'shot (2).png']);
      expect(first.outcome, ImageDownloadOutcome.saved);
      final names = await downloads.list().map((e) => e.uri.pathSegments.last).toList();
      expect(names..sort(), ['shot (1).png', 'shot (2).png', 'shot.png']);
      expect(await File('${downloads.path}/shot (2).png').readAsBytes(), _png);
      expect(await downloads.parent.list().where((e) => e.path.endsWith('shot.png')).isEmpty, isTrue);
    });

    test('fails when the platform has no Downloads directory', () async {
      final missing = DownloadsDirectoryImageSaver(downloadsDirectory: () async => null);
      await expectLater(missing.save(bytes: _png), throwsA(isA<ImageDownloadException>()));
      final gone = DownloadsDirectoryImageSaver(
        downloadsDirectory: () async => Directory('${downloads.path}/missing'),
      );
      await expectLater(gone.save(bytes: _png), throwsA(isA<ImageDownloadException>()));
    });
  });
}
