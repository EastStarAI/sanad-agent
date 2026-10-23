// Task 139 C3 — the schedule form reuses the new-conversation widgets instead
// of forking them.
//
// The form must reach the provider/model picker through the shared
// `ComposerModelChip`, which owns `ModelPickerDialog`. A second picker
// implementation under `features/schedules/` would silently split the two
// surfaces (different keys, different recent-model handling, different
// provider catalogs), so this guard fails as soon as one appears.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _schedulesRoot = 'lib/features/schedules';
const String _composerChipPath =
    'lib/features/conversations/presentation/widgets/conversation_input/composer_model_chip.dart';
const String _workspaceChipPath =
    'lib/features/conversations/presentation/widgets/conversation_input/composer_workspace_chip.dart';
const String _pickerPath =
    'lib/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';

void main() {
  test('no second model or workspace picker is declared under features/schedules', () {
    final declarations = <String>[];
    for (final file in _dartFiles(Directory(_schedulesRoot))) {
      final source = file.readAsStringSync();
      for (final match in RegExp(r'^\s*class\s+(\w*(?:Picker|ModelSelector|WorkspaceSelector)\w*)', multiLine: true).allMatches(
        source,
      )) {
        declarations.add('${file.path} declares ${match.group(1)}');
      }
    }

    expect(
      declarations,
      isEmpty,
      reason:
          'The schedule form reuses ComposerModelChip, ComposerWorkspaceChip and '
          'ModelPickerDialog; it must not declare a selector or picker of its own '
          '(Task 139 C3). Found:\n${declarations.join('\n')}',
    );
  });

  test('the schedules feature opens the model picker only through the shared chip', () {
    final directUses = <String>[];
    for (final file in _dartFiles(Directory(_schedulesRoot))) {
      final source = file.readAsStringSync();
      if (!source.contains('model_picker_dialog.dart')) continue;
      directUses.add(file.path);
    }

    expect(
      directUses,
      isEmpty,
      reason:
          'Only ComposerModelChip owns the picker dialog, so a schedules file must '
          'not import it directly (Task 139 C3). Found:\n${directUses.join('\n')}',
    );
  });

  test('the shared chips are the single picker hosts', () {
    final chip = File(_composerChipPath);
    final workspaceChip = File(_workspaceChipPath);
    final picker = File(_pickerPath);

    expect(chip.existsSync(), isTrue, reason: 'Missing shared model chip: $_composerChipPath');
    expect(workspaceChip.existsSync(), isTrue, reason: 'Missing shared workspace chip: $_workspaceChipPath');
    expect(picker.existsSync(), isTrue, reason: 'Missing model picker: $_pickerPath');
    expect(
      chip.readAsStringSync().contains('ModelPickerDialog('),
      isTrue,
      reason: 'ComposerModelChip must be the surface that opens ModelPickerDialog',
    );
    expect(
      _lineCount(chip),
      lessThanOrEqualTo(1000),
      reason: 'The shared model chip stays inside the Client size ratchet',
    );
  });
}

int _lineCount(File file) => file.readAsLinesSync().length;

Iterable<File> _dartFiles(Directory root) {
  if (!root.existsSync()) return const <File>[];
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));
}
