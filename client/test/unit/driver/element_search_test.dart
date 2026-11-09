import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/driver_widget_filters.dart';

/// The dictation driver seam finds a keyed widget in a real tree.
///
/// `ext.sanad_client.dictation_control` answered `composer_not_mounted` on every
/// Home with conversation history because its key search stopped after 4000
/// visited elements, while `inspect_ui` — an unbounded walk over the same tree —
/// found the composer instantly. This pins the shared traversal to the real
/// shape: the target sits *after* far more than 4000 elements.
void main() {
  /// A tall tree: [cells] keyed leaves, then the target at the very end.
  ///
  /// Every cell is a Padding wrapping a Text, so the walk visits several
  /// elements per cell and the target sits well past the old 4000 bound.
  Widget tallTree({required String targetKey, int cells = 2400}) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              for (var cell = 0; cell < cells; cell++)
                Padding(
                  padding: const EdgeInsets.all(1),
                  child: Text(
                    'cell $cell',
                    key: ValueKey('cell_$cell'),
                  ),
                ),
              SizedBox(
                key: ValueKey(targetKey),
                width: 32,
                height: 32,
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('a key past 4000 elements is still found', (tester) async {
    const targetKey = 'dictation_mic_btn';
    await tester.pumpWidget(tallTree(targetKey: targetKey));

    final root = tester.binding.rootElement!;
    final found = findElementByKey(root, targetKey);

    expect(found, isNotNull);
    expect(found!.widget.key, const ValueKey(targetKey));
    // The tree really is larger than the old bound, so this test would have
    // failed against the bounded walk instead of passing for the wrong reason.
    expect(find.byKey(const ValueKey('cell_2399')), findsOneWidget);
  });

  testWidgets('an absent key answers null instead of guessing', (tester) async {
    await tester.pumpWidget(tallTree(targetKey: 'present_key'));

    expect(
      findElementByKey(tester.binding.rootElement!, 'missing_key'),
      isNull,
    );
  });
}
