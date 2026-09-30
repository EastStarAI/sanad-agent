import 'package:flutter/material.dart';

/// Returns the rendered plain text owned directly by supported text widgets.
///
/// Markdown commonly produces `Text.rich`, where [Text.data] is null and the
/// visible content lives in [Text.textSpan]. Keeping this extraction in one
/// place ensures scope matching, snapshots, and keyed-container consolidation
/// agree without traversing and duplicating wrapper rows.
String? inspectableWidgetText(Widget widget) {
  if (widget is Text) {
    return widget.data ?? widget.textSpan?.toPlainText();
  }
  if (widget is RichText) {
    return widget.text.toPlainText();
  }
  if (widget is SelectableText) {
    return widget.data ?? widget.textSpan?.toPlainText();
  }
  return null;
}

/// Finds the first non-empty rendered text in [root]'s subtree.
String? firstInspectableDescendantText(
  Element root, {
  bool Function(String text)? accept,
}) {
  String? result;

  void visit(Element element) {
    if (result != null) return;
    final text = inspectableWidgetText(element.widget);
    if (text != null &&
        text.trim().isNotEmpty &&
        (accept?.call(text) ?? true)) {
      result = text;
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return result;
}

/// Collects rendered text leaves without duplicating a Text widget's RichText.
String? allInspectableDescendantText(
  Element root, {
  bool Function(String text)? accept,
}) {
  final parts = <String>[];

  void visit(Element element) {
    final text = inspectableWidgetText(element.widget);
    if (text != null) {
      final trimmed = text.trim();
      if (trimmed.isNotEmpty && (accept?.call(text) ?? true)) {
        parts.add(trimmed);
      }
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return parts.isEmpty ? null : parts.join('\n');
}
