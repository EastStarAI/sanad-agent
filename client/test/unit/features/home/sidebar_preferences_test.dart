import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/home/data/sidebar_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores and restores the sidebar width', () async {
    final preferences = await SharedPreferences.getInstance();
    final sidebarPreferences = SidebarPreferences(preferences);

    await sidebarPreferences.setSidebarWidth(360);

    expect(sidebarPreferences.sidebarWidth, 360);
    expect(preferences.getDouble(SidebarPreferences.sidebarWidthKey), 360);
  });

  test('ignores unrelated preference keys', () async {
    SharedPreferences.setMockInitialValues({'unrelated_width': 360});
    final sidebarPreferences = SidebarPreferences(
      await SharedPreferences.getInstance(),
    );

    expect(sidebarPreferences.sidebarWidth, isNull);
  });
}
