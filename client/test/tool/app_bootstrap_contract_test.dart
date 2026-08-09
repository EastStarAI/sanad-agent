import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bootstrap keeps required initialization stages in order', () {
    final source = File(
      'lib/core/bootstrap/app_bootstrap.dart',
    ).readAsStringSync();
    const orderedStages = [
      'WidgetsFlutterBinding.ensureInitialized()',
      'SharedPreferences.setPrefix(preferencesPrefix)',
      'initClientLogger()',
      'setupInspectorListener()',
      'ThemeCubit.getSavedTheme()',
      'WindowManagerService.initialize()',
      'registerWindowsScheme()',
      'configureDependencies(startupTrace: _trace)',
      'getIt<AppState>().ready',
      'getIt<ConversationCachePersistor>().hydrate()',
    ];

    var previousIndex = -1;
    for (final stage in orderedStages) {
      final index = source.indexOf(stage);
      expect(index, greaterThan(previousIndex), reason: 'Missing or reordered $stage');
      previousIndex = index;
    }
    expect(source, isNot(contains('FlutterError.onError')));
    expect(source, isNot(contains('PlatformDispatcher.instance.onError')));
  });
}
