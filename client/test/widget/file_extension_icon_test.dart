import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';

void main() {
  Future<String> assetFor(WidgetTester tester, String fileName) async {
    await tester.pumpWidget(MaterialApp(home: Center(child: FileExtensionIcon(fileName: fileName))));
    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    return (picture.bytesLoader as SvgAssetLoader).assetName;
  }

  testWidgets('HEIC, HEIF, TIFF, and AVIF images use the image icon (114 minor)', (tester) async {
    for (final name in ['photo114.heic', 'shot.HEIF', 'scan.tiff', 'scan.tif', 'still.avif']) {
      expect(await assetFor(tester, name), 'assets/file_icons/image.svg', reason: name);
    }
    expect(await assetFor(tester, 'img114_red.png'), 'assets/file_icons/image.svg');
  });
}
