import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test('canonical vector sources use the approved Sanad primary color', () {
    const canonicalVectors = <String>[
      '../docs/assets/brand/sanad-mark.svg',
      '../docs/assets/brand/sanad-wordmark-horizontal.svg',
      '../docs/assets/brand/sanad-wordmark-stacked.svg',
      'assets/brand/sanad-wordmark-horizontal.svg',
      'assets/brand/sanad-wordmark-horizontal-dark.svg',
    ];

    for (final path in canonicalVectors) {
      final vector = File(path).readAsStringSync().toLowerCase();
      expect(vector, contains('#60a5fa'), reason: path);
      expect(vector, isNot(contains('#5745f9')), reason: path);
    }
  });

  test('canonical in-app assets use the approved identity', () {
    final appIcon = _readPng('assets/app-logo.png');
    expect((appIcon.width, appIcon.height), (1024, 1024));
    final corner = appIcon.getPixel(0, 0);
    expect(
      (corner.r.toInt(), corner.g.toInt(), corner.b.toInt(), corner.a.toInt()),
      (10, 10, 10, 255),
    );

    final mark = _readPng('assets/sanad_mark.png');
    expect((mark.width, mark.height), (1024, 1024));
    expect(mark.getPixel(0, 0).a.toInt(), 0);
    final brandedPixel = mark.firstWhere((pixel) => pixel.a.toInt() == 255);
    expect(
      (
        brandedPixel.r.toInt(),
        brandedPixel.g.toInt(),
        brandedPixel.b.toInt(),
      ),
      (96, 165, 250),
    );
  });

  test('generated platform icon matrices are complete', () {
    const androidIcons = <String, int>{
      'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': 48,
      'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': 72,
      'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': 96,
      'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 144,
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': 192,
    };
    for (final entry in androidIcons.entries) {
      final icon = _readPng(entry.key);
      expect((icon.width, icon.height), (entry.value, entry.value));
    }

    final adaptiveXml = File(
      'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    ).readAsStringSync();
    expect(adaptiveXml, contains('@color/ic_launcher_background'));
    expect(adaptiveXml, contains('<monochrome'));
    expect(
      File('android/app/src/main/res/values/colors.xml').readAsStringSync(),
      contains('#0A0A0A'),
    );

    final iosStoreIcon = _readPng(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/'
      'Icon-App-1024x1024@1x.png',
    );
    expect((iosStoreIcon.width, iosStoreIcon.height), (1024, 1024));
    expect(iosStoreIcon.every((pixel) => pixel.a.toInt() == 255), isTrue);

    final macOSSmallIcon = _readPng(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png',
    );
    final macOSStoreIcon = _readPng(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
    );
    expect((macOSSmallIcon.width, macOSStoreIcon.width), (16, 1024));
    expect(macOSStoreIcon.every((pixel) => pixel.a.toInt() == 255), isTrue);
    expect(_rgbaBytes(macOSStoreIcon), _rgbaBytes(iosStoreIcon));
    expect(Directory('macos/Runner/AppIcon.icon').existsSync(), isFalse);
    final macOSProject = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(macOSProject, isNot(contains('folder.iconcomposer.icon')));
    expect(macOSProject, isNot(contains('AppIcon.icon in Resources')));

    final ico = File('windows/runner/resources/app_icon.ico').readAsBytesSync();
    final icoData = ByteData.sublistView(Uint8List.fromList(ico));
    expect(icoData.getUint16(4, Endian.little), 7);
    final sizes = <int>{};
    for (var index = 0; index < 7; index++) {
      final rawSize = ico[6 + index * 16];
      sizes.add(rawSize == 0 ? 256 : rawSize);
    }
    expect(sizes, {16, 24, 32, 48, 64, 128, 256});

    for (final size in <int>[16, 24, 32, 48, 64, 128, 256, 512]) {
      final icon = _readPng(
        'linux/assets/icons/hicolor/${size}x$size/apps/'
        'com.eaststarai.sanad.png',
      );
      expect((icon.width, icon.height), (size, size));
    }
  });

  test('web standard and maskable icons use intentional brand colors', () {
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync()) as Map<String, dynamic>;
    expect(manifest['background_color'], '#0A0A0A');
    expect(manifest['theme_color'], '#60A5FA');

    expect((_readPng('web/icons/Icon-192.png').width, _readPng('web/icons/Icon-512.png').width), (192, 512));
    expect(
      (_readPng('web/icons/Icon-maskable-192.png').width, _readPng('web/icons/Icon-maskable-512.png').width),
      (192, 512),
    );
    expect(_readPng('web/icons/Icon-maskable-512.png').getPixel(0, 0).r.toInt(), 10);

    final index = File('web/index.html').readAsStringSync();
    final favicon = File('web/favicon.svg').readAsStringSync().toLowerCase();
    expect(
      index,
      contains(
        '<link rel="icon" type="image/svg+xml" '
        'href="favicon.svg?v=438686e5e0b0">',
      ),
    );
    expect(favicon, contains('viewbox="0 0 256.15 166.43"'));
    expect(favicon, contains('fill: #60a5fa'));
    expect(index, isNot(contains('href="favicon-16.png"')));
    expect(index, isNot(contains('href="favicon-32.png"')));
    expect(index, isNot(contains('href="favicon.ico"')));
  });

  test('legacy splash asset name is absent from active client source', () {
    final roots = <FileSystemEntity>[
      Directory('lib'),
      Directory('test'),
      File('pubspec.yaml'),
    ];
    for (final root in roots) {
      final files = root is Directory ? root.listSync(recursive: true).whereType<File>() : <File>[root as File];
      for (final file in files) {
        if (!file.path.endsWith('.dart') && !file.path.endsWith('.yaml')) {
          continue;
        }
        expect(
          file.readAsStringSync(),
          isNot(
            contains(
              'utra_'
              'sanad_logo',
            ),
          ),
          reason: file.path,
        );
      }
    }
  });
}

image.Image _readPng(String path) {
  final decoded = image.decodePng(File(path).readAsBytesSync());
  expect(decoded, isNotNull, reason: path);
  return decoded!;
}

Uint8List _rgbaBytes(image.Image source) {
  final bytes = Uint8List(source.length * 4);
  var offset = 0;
  for (final pixel in source) {
    bytes[offset++] = pixel.r.toInt();
    bytes[offset++] = pixel.g.toInt();
    bytes[offset++] = pixel.b.toInt();
    bytes[offset++] = pixel.a.toInt();
  }
  return bytes;
}
