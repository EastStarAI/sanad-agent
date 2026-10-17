import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/file_tool_tile.dart';

void main() {
  testWidgets(
    'multi-chunk edit diff anchors each hunk at its reported start line',
    (tester) async {
      await _pumpEditTile(
        tester,
        output: _multiChunkOutput(editStartLines: const [5, 20]),
      );

      // Hunk 1 (startLine 5) renders 5/5, hunk 2 is re-anchored to 20/20
      // instead of continuing the sequential counter.
      expect(find.text('5'), findsNWidgets(2));
      expect(find.text('20'), findsNWidgets(2));
      expect(find.text('6'), findsNothing);
      expect(find.text('21'), findsNothing);
    },
  );

  testWidgets(
    'diff falls back to sequential numbering when editStartLines is absent',
    (tester) async {
      await _pumpEditTile(tester, output: _multiChunkOutput());

      // Without per-chunk anchors the counter keeps running after hunk 1.
      expect(find.text('6'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'diff block is selectable while the gutter stays excluded',
    (tester) async {
      await _pumpEditTile(
        tester,
        output: _multiChunkOutput(editStartLines: const [5, 20]),
      );

      expect(find.byType(SelectionArea), findsOneWidget);

      final disabledGutters = tester
          .widgetList<SelectionContainer>(find.byType(SelectionContainer))
          .where((container) => container.registrar == null);
      expect(disabledGutters.length, greaterThanOrEqualTo(8));
    },
  );

  testWidgets('rendering a file_edit tile emits no diagnostic log', (
    tester,
  ) async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    try {
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      await _pumpEditTile(
        tester,
        output: _multiChunkOutput(editStartLines: const [5, 20]),
      );
    } finally {
      // Foundation debug hooks must be restored before the test body returns.
      debugPrint = originalDebugPrint;
    }

    expect(
      logs.where((log) => log.contains('FileToolTile Debug Log')),
      isEmpty,
    );
  });
}

Future<void> _pumpEditTile(
  WidgetTester tester, {
  required Map<String, dynamic> output,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          child: FileToolTile(event: _editEvent(output)),
        ),
      ),
    ),
  );
  await tester.pump();
}

Map<String, dynamic> _multiChunkOutput({List<int>? editStartLines}) {
  return {
    'filePath': 'lib/example.dart',
    'oldString': 'Line 5: initial',
    'newString': 'Line 5: updated',
    'patch':
        '- Line 5: initial\n'
        '+ Line 5: updated\n'
        '---\n'
        '- Line 20: second initial\n'
        '+ Line 20: second updated',
    'replaceAll': false,
    'numReplacements': 2,
    'startLine': 5,
    'numEdits': 2,
    if (editStartLines != null) 'editStartLines': editStartLines,
  };
}

CanonicalEvent _editEvent(Map<String, dynamic> output) {
  return CanonicalEvent(
    id: 'file-edit-multi-chunk',
    kind: EventKind.toolCall,
    timestamp: DateTime.utc(2026, 10, 17),
    tool: {
      'name': 'file_edit',
      'input': {
        'path': 'lib/example.dart',
        'edits': [
          {'old_string': 'Line 5: initial', 'new_string': 'Line 5: updated'},
          {
            'old_string': 'Line 20: second initial',
            'new_string': 'Line 20: second updated',
          },
        ],
      },
      'output': jsonEncode(output),
    },
  );
}
