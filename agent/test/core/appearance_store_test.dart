import 'package:sanad_agent/core/appearance/appearance_store.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();

  group('AppearanceStore', () {
    test('returns default appearance when appearance.json does not exist', () async {
      const store = AppearanceStore();
      final appearance = await store.readAppearance();

      expect(appearance, AppearanceStore.defaultAppearance);
      expect(appearance['theme_style'], 'dark');
      expect(appearance['primary_color'], 'blue');
      expect(appearance['font_family'], 'system');
      expect(appearance['font_size'], 'normal');
      expect(appearance['background_option'], 'defaultTheme');
    });

    test('persists and reads updated appearance correctly', () async {
      const store = AppearanceStore();
      final saved = await store.saveAppearance({
        'theme_style': 'midnight',
        'primary_color': 'purple',
        'font_family': 'cairo',
        'font_size': 'large',
        'background_option': 'natureMountain',
      });

      expect(saved['theme_style'], 'midnight');
      expect(saved['primary_color'], 'purple');
      expect(saved['font_family'], 'cairo');
      expect(saved['font_size'], 'large');
      expect(saved['background_option'], 'natureMountain');

      final read = await store.readAppearance();
      expect(read, saved);
    });

    test('supports camelCase keys from client and preserves unchanged fields', () async {
      const store = AppearanceStore();
      await store.saveAppearance({
        'theme_style': 'sepia',
        'primary_color': 'teal',
      });

      final partialUpdate = await store.saveAppearance({
        'primaryColor': 'rose',
        'fontSize': 'extraLarge',
      });

      expect(partialUpdate['theme_style'], 'sepia');
      expect(partialUpdate['primary_color'], 'rose');
      expect(partialUpdate['font_size'], 'extraLarge');
      expect(partialUpdate['font_family'], 'system');
    });
  });
}
