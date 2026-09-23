import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop settings expose an explicit update check', () {
    final source = File(
      'lib/features/settings/presentation/widgets/settings_pages.dart',
    ).readAsStringSync();

    // Localization pass (Task 95) moved visible copy into AppLocalizations;
    // the contract now asserts the localized accessors plus desktop gating.
    expect(source, contains('if (AppPlatform.isDesktop)'));
    expect(
      source,
      contains('AppLocalizations.of(context)!.checkForUpdates'),
    );
    expect(source, contains('AppLocalizations.of(context)!.updatesAutoNote'));
    expect(source, contains('AppLocalizations.of(context)!.updatesLinuxNote'));
    expect(source, contains('AppLocalizations.of(context)!.currentVersion('));
  });
}
