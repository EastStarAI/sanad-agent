import 'package:flutter/services.dart';

TextEditingValue insertDroppedPathsAtSelection(
  TextEditingValue value,
  Iterable<String> paths,
) {
  final droppedPaths = paths.where((path) => path.isNotEmpty).join(' ');
  if (droppedPaths.isEmpty) return value;

  final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
  final start = selection.start;
  final end = selection.end;
  final before = value.text.substring(0, start);
  final after = value.text.substring(end);
  final leadingSpace = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before) ? ' ' : '';
  final trailingSpace = after.isEmpty || !RegExp(r'^\s').hasMatch(after) ? ' ' : '';
  final insertion = '$leadingSpace$droppedPaths$trailingSpace';

  return value.copyWith(
    text: value.text.replaceRange(start, end, insertion),
    selection: TextSelection.collapsed(offset: start + insertion.length),
    composing: TextRange.empty,
  );
}
