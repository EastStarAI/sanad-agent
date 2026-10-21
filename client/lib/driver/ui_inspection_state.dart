import 'package:flutter/material.dart';

/// Returns whether a supported interactive widget currently accepts input.
///
/// Enabled state is derived from the same callbacks Flutter uses to decide
/// interactivity, so driver snapshots report what a user could actually
/// activate. Returns null for widgets that carry no enabled state.
bool? inspectableWidgetEnabled(Widget widget) {
  if (widget is ButtonStyleButton) return widget.enabled;
  if (widget is IconButton) return widget.onPressed != null;
  if (widget is PopupMenuButton) return widget.enabled;
  if (widget is ListTile) {
    return widget.enabled && (widget.onTap != null || widget.onLongPress != null);
  }
  if (widget is InkWell) {
    return widget.onTap != null || widget.onLongPress != null || widget.onDoubleTap != null;
  }
  if (widget is TextField) return widget.enabled ?? true;
  return null;
}

/// Resolves the enabled state of a keyed element.
///
/// A key frequently sits on a non-interactive wrapper around the actual
/// control, so the first descendant with an enabled state answers when the
/// keyed widget itself has none.
bool? inspectableElementEnabled(Element root) {
  bool? result;

  void visit(Element element) {
    if (result != null) return;
    result = inspectableWidgetEnabled(element.widget);
    if (result == null) element.visitChildren(visit);
  }

  visit(root);
  return result;
}
