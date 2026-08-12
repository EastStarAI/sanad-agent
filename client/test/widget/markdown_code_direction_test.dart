import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/app_markdown_renderer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';

void main() {
  const codeColor = Colors.green;

  Widget host(String code, {String? language}) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 120,
          child: AppCodeBlock(
            codeText: code,
            codeColor: codeColor,
            language: language,
          ),
        ),
      ),
    );
  }

  testWidgets('programming code starts at the left edge', (tester) async {
    const code = 'const veryLongVariableName = calculateSomethingUsefulForTheUser();';
    await tester.pumpWidget(host(code, language: 'javascript'));

    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.axisDirection, AxisDirection.right);
    expect(position.pixels, position.minScrollExtent);
    expect(tester.widget<Text>(find.text(code)).textDirection, TextDirection.ltr);
  });

  testWidgets('untyped Code starts at the left edge even with Arabic content', (tester) async {
    const code = 'اطبع هذا النص ثم استخدم هذا السطر الطويل جدًا';
    await tester.pumpWidget(host(code));

    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.axisDirection, AxisDirection.right);
    expect(tester.widget<Text>(find.text(code)).textDirection, TextDirection.ltr);
  });

  testWidgets('Arabic text starts at the right edge', (tester) async {
    const code = 'هذا نص عربي طويل جدًا لاختبار اتجاه التمرير الأفقي من الحافة اليمنى';
    await tester.pumpWidget(host(code, language: 'text'));

    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.axisDirection, AxisDirection.left);
    expect(position.pixels, position.minScrollExtent);
    expect(tester.widget<Text>(find.text(code)).textDirection, TextDirection.rtl);
  });

  testWidgets('English text starts at the left edge', (tester) async {
    const code = 'This is a very long English text block used to verify the horizontal scroll origin.';
    await tester.pumpWidget(host(code, language: 'text'));

    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.axisDirection, AxisDirection.right);
    expect(position.pixels, position.minScrollExtent);
    expect(tester.widget<Text>(find.text(code)).textDirection, TextDirection.ltr);
  });

  testWidgets('compact header keeps language left and copy right without stretching', (tester) async {
    const code = 'print(1);';
    await tester.binding.setSurfaceSize(const Size(800, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(code, language: 'dart'));

    final blockRect = tester.getRect(find.byType(AppCodeBlock));
    final languageRect = tester.getRect(find.text('dart'));
    final copyRect = tester.getRect(find.byType(CopyButton));

    expect(blockRect.width, lessThan(400));
    expect(languageRect.left, lessThan(copyRect.left));
    // The one-pixel block border wraps the 12px/8px header insets.
    expect(languageRect.left, closeTo(blockRect.left + 13, 0.1));
    expect(copyRect.right, closeTo(blockRect.right - 9, 0.1));
  });

  testWidgets('Markdown header extracts language and copies only block content', (tester) async {
    const code = 'const answer = 42;';
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text']?.toString();
        }
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppMarkdownRenderer(
            data: '```javascript\n$code\n```',
            isFinal: true,
          ),
        ),
      ),
    );

    expect(find.text('javascript'), findsOneWidget);
    await tester.tap(find.byType(CopyButton));
    await tester.pump();

    expect(copiedText, code);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
