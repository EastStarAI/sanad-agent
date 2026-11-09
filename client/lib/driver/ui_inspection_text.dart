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

/// Longest tooltip message the inspection projection emits.
///
/// A tooltip is occasionally a paragraph, and a snapshot is read by an agent
/// with a bounded context. The projection therefore cuts the message and says
/// so with `tooltip_truncated` rather than silently inflating the tree.
const int maxTooltipMessageLength = 200;

/// Most elements probed when looking for a tooltip inside one element.
///
/// The probe exists for widgets such as `IconButton(tooltip: ...)`, which build
/// the `Tooltip` as their own child, so ancestor propagation alone never sees
/// the message. The bound keeps one row's probe from walking a whole screen.
const int maxTooltipProbeElements = 200;

/// A tooltip message prepared for projection, with its truncation state.
typedef BoundedTooltip = ({String text, bool truncated});

/// Bounds [message] for projection, or null when there is nothing to show.
BoundedTooltip? boundTooltipMessage(
  String? message, {
  int maxLength = maxTooltipMessageLength,
}) {
  if (message == null || message.trim().isEmpty) return null;
  if (message.length <= maxLength) return (text: message, truncated: false);
  return (text: message.substring(0, maxLength), truncated: true);
}

/// Finds the first non-empty `Tooltip` message below [root].
///
/// The walk stops at [maxVisited] elements and returns null when it gives up,
/// because a row without a discovered tooltip is not a claim that the widget
/// has none.
String? firstDescendantTooltipMessage(
  Element root, {
  int maxVisited = maxTooltipProbeElements,
}) {
  String? message;
  var visited = 0;

  void visit(Element element) {
    if (message != null || visited >= maxVisited) return;
    visited++;
    final widget = element.widget;
    if (widget is Tooltip && (widget.message?.trim().isNotEmpty ?? false)) {
      message = widget.message;
      return;
    }
    element.visitChildren(visit);
  }

  // `root`'s own message is not a descendant; the caller projects it directly.
  root.visitChildren(visit);
  return message;
}

/// Tooltip message projected for [element].
///
/// Prefers the message inherited from an enclosing `Tooltip` (which the walk
/// already carries down) and otherwise looks inside the element's own subtree.
/// A message ancestor above a keyed control and a message the control builds
/// itself must both reach the keyed row, or a documented user affordance such
/// as "long-press for settings" stays invisible to an inspecting agent.
BoundedTooltip? inspectableTooltip(Element element, {String? inherited}) {
  final declared = inherited ?? _declaredTooltipMessage(element.widget);
  final boundedDeclared = boundTooltipMessage(declared);
  if (boundedDeclared != null) return boundedDeclared;

  // A text leaf cannot contain a tooltip, so those rows never pay for a probe.
  if (inspectableWidgetText(element.widget) != null) return null;
  return boundTooltipMessage(firstDescendantTooltipMessage(element));
}

String? _declaredTooltipMessage(Widget widget) {
  if (widget is Tooltip && (widget.message?.trim().isNotEmpty ?? false)) {
    return widget.message;
  }
  return null;
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
