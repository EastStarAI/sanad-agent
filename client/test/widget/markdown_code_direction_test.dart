import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';

void main() {
  const codeColor = Colors.green;

  Widget host(String code) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 120,
          child: AppCodeBlock(
            codeText: code,
            codeColor: codeColor,
          ),
        ),
      ),
    );
  }

  testWidgets('Arabic code uses RTL text with an LTR scroll viewport', (tester) async {
    const code = 'اطبع هذا النص ثم استخدم هذا السطر الطويل جدًا';
    await tester.pumpWidget(host(code));

    expect(
      tester.widgetList<Directionality>(find.byType(Directionality)).map((widget) => widget.textDirection),
      containsAll(<TextDirection>[TextDirection.ltr, TextDirection.rtl]),
    );
    expect(tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels, 0);
  });

  testWidgets('English code uses LTR text and starts at the left edge', (tester) async {
    const code = 'const veryLongVariableName = calculateSomethingUsefulForTheUser();';
    await tester.pumpWidget(host(code));

    final directions = tester
        .widgetList<Directionality>(find.byType(Directionality))
        .map((widget) => widget.textDirection);
    expect(directions, everyElement(TextDirection.ltr));
    expect(tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels, 0);
  });
}
