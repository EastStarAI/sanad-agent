import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android signing guard is scoped to requested release tasks', () {
    final gradle =
        File('android/app/build.gradle').readAsStringSync().replaceAll('\r\n', '\n');

    expect(gradle, contains('gradle.startParameter.taskNames.any'));
    expect(gradle, contains('taskName.toLowerCase().contains("release")'));
    expect(
      gradle,
      contains(
        'if (releaseTaskRequested && !releaseKeyPropertiesFile.exists())',
      ),
    );
    expect(
      gradle,
      contains(
        'if (releaseKeyPropertiesFile.exists()) {\n'
        '                signingConfig = signingConfigs.release',
      ),
    );
  });

  test('repository does not contain local Android signing material', () {
    expect(File('android/key.properties').existsSync(), isFalse);
    expect(File('android/brand-smoke.keystore').existsSync(), isFalse);
  });
}
