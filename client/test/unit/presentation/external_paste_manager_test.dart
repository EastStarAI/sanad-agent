import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/utils/external_paste_manager.dart';

void main() {
  /// Builds one text field, focuses it, and returns its controller so a test
  /// can name the exact caret the captured text must land on.
  Future<TextEditingController> pumpFocusedField(
    WidgetTester tester, {
    String initialText = '',
    TextSelection? selection,
  }) async {
    final controller = TextEditingController(text: initialText)
      ..selection = selection ?? TextSelection.collapsed(offset: initialText.length);
    addTearDown(controller.dispose);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TextField(controller: controller, focusNode: focusNode))),
    );
    focusNode.requestFocus();
    await tester.pump();
    return controller;
  }

  testWidgets('inserts captured text at the caret of the focused field', (tester) async {
    final controller = await pumpFocusedField(
      tester,
      initialText: 'hello world',
      selection: const TextSelection.collapsed(offset: 5),
    );

    ExternalPasteManager.handlePaste(' dictated');
    await tester.pump();

    expect(controller.text, 'hello dictated world');
    expect(controller.selection, const TextSelection.collapsed(offset: 14));
  });

  testWidgets('replaces the focused selection with the captured text', (tester) async {
    final controller = await pumpFocusedField(
      tester,
      initialText: 'hello world',
      selection: const TextSelection(baseOffset: 6, extentOffset: 11),
    );

    ExternalPasteManager.handlePaste('there');
    await tester.pump();

    expect(controller.text, 'hello there');
    expect(controller.selection, const TextSelection.collapsed(offset: 11));
  });

  testWidgets('inserts captured text into a field that is not the composer', (tester) async {
    final controller = await pumpFocusedField(tester, initialText: 'search');

    ExternalPasteManager.handlePaste(' term');
    await tester.pump();

    expect(controller.text, 'search term');
  });

  testWidgets('drops the text when no text field is focused', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));

    ExternalPasteManager.handlePaste('nowhere to land');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores empty text', (tester) async {
    final controller = await pumpFocusedField(tester, initialText: 'unchanged');

    ExternalPasteManager.handlePaste('');
    await tester.pump();

    expect(controller.text, 'unchanged');
  });
}
