// The send control draws a Flutter-authored icon, not an Apple SF Symbol.
//
// `flutter_sficon` embedded Apple's SF Pro font (`sficons.ttf`), which fails
// App Store validation as ITMS-91182. The arrow is now `CupertinoIcons.arrow_up`
// from `cupertino_icons` with the same size and color, so this test pins the
// icon identity, the disabled/send behavior, and the rendered glyph size.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/message_bar.dart';

void main() {
  Future<Icon> renderButton(
    WidgetTester tester, {
    bool isEnabled = true,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: Scaffold(
          body: Center(
            child: MessageBarButton(isEnabled: isEnabled, onTap: onTap),
          ),
        ),
      ),
    );
    return tester.widget<Icon>(find.byType(Icon));
  }

  testWidgets('the send arrow is CupertinoIcons.arrow_up at the original size', (tester) async {
    final icon = await renderButton(tester);

    expect(icon.icon, CupertinoIcons.arrow_up);
    expect(icon.size, 16);
    expect(
      icon.color,
      Theme.of(tester.element(find.byType(MessageBarButton))).colorScheme.onPrimary,
    );
  });

  testWidgets('an enabled button forwards the tap', (tester) async {
    var taps = 0;
    await renderButton(tester, onTap: () => taps++);

    await tester.tap(find.byType(MessageBarButton));
    expect(taps, 1);
  });

  testWidgets('a disabled button swaps the surface and drops the tap', (tester) async {
    var taps = 0;
    await renderButton(tester, isEnabled: false, onTap: () => taps++);

    await tester.tap(find.byType(MessageBarButton));
    expect(taps, 0);

    final material = tester.widget<Material>(
      find.descendant(of: find.byType(MessageBarButton), matching: find.byType(Material)).first,
    );
    expect(
      material.color,
      Theme.of(tester.element(find.byType(MessageBarButton))).colorScheme.surfaceContainerHighest,
    );
  });

  testWidgets('the composer renders one send arrow inside the message bar', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBar(),
        ),
      ),
    );

    expect(find.byType(MessageBar), findsOneWidget);
    expect(find.byType(MessageBarButton), findsOneWidget);
    expect(tester.widget<Icon>(find.byType(Icon)).icon, CupertinoIcons.arrow_up);
  });
}
