import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop settings expose an explicit update check', () {
    final source = File(
      'lib/features/settings/presentation/widgets/settings_pages.dart',
    ).readAsStringSync();

    expect(source, contains('if (AppPlatform.isDesktop)'));
    expect(source, contains("label: const Text('Check for Updates')"));
    expect(
      source,
      contains('Automatic update checks run in the background.'),
    );
    expect(
      source,
      contains('Linux updates are manual.'),
    );
    expect(
      source,
      contains('Current Version:'),
    );
  });
}
