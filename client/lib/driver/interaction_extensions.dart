import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding, ScrollDirection;
import 'package:sanad_client/driver/driver_widget_filters.dart';
import 'package:sanad_client/driver/ui_bounds.dart';

/// Press duration that keeps a dispatched tap a tap, in milliseconds.
const int tapPressDelayMs = 60;

/// Longest hold a `hold_ms` request may ask for, in milliseconds.
///
/// The bound keeps one driver call from pinning the Client's event loop or
/// turning a mistyped duration into an unbounded press. The driver CLI rejects
/// the same range before it connects, so this is the authoritative check rather
/// than the only one.
const int maxTapHoldMs = 5000;

/// Deepest render-object ancestor chain walked when matching a hit to a target.
const int maxHitTestAncestorDepth = 256;

/// Most elements probed when naming the widget that covers a tap target.
const int maxObstructionProbeElements = 4000;

/// A resolved `hold_ms` request: the duration to hold and, when the request was
/// invalid, the message that rejects it.
typedef TapHoldRequest = ({int holdMs, String? error});

/// Resolves a `hold_ms` parameter into a bounded press duration.
///
/// A long press is the same pointer sequence as a tap with a longer delay
/// between `PointerDown` and `PointerUp`, so the caller expresses it as data
/// instead of the driver hard-coding one press duration for every target.
TapHoldRequest parseTapHoldMs(
  String? raw, {
  int defaultHoldMs = tapPressDelayMs,
}) {
  if (raw == null || raw.trim().isEmpty) {
    return (holdMs: defaultHoldMs, error: null);
  }
  final parsed = int.tryParse(raw.trim());
  if (parsed == null) {
    return (
      holdMs: defaultHoldMs,
      error: 'hold_ms must be an integer number of milliseconds',
    );
  }
  if (parsed < 0 || parsed > maxTapHoldMs) {
    return (
      holdMs: defaultHoldMs,
      error: 'hold_ms must be between 0 and $maxTapHoldMs',
    );
  }
  return (holdMs: parsed, error: null);
}

/// Whether [candidate] is [root] or one of its render descendants.
bool _renderSubtreeContains(RenderObject? candidate, RenderObject root) {
  var node = candidate;
  for (var depth = 0; node != null && depth <= maxHitTestAncestorDepth; depth++) {
    if (identical(node, root)) return true;
    node = node.parent;
  }
  return false;
}

/// Hit-tests [position] inside the view that owns [element].
///
/// Returns null when the owning view cannot be resolved, so a caller can skip
/// the obstruction check instead of reporting a false obstruction for every
/// tap in an unusual embedding.
HitTestResult? hitTestElementAt(Element element, Offset position) {
  final view = View.maybeOf(element);
  if (view == null) return null;
  final result = HitTestResult();
  RendererBinding.instance.hitTestInView(result, position, view.viewId);
  return result;
}

/// Whether a hit-test path reaches [root] or something inside it.
bool hitPathIncludesRenderSubtree(HitTestResult hitPath, RenderObject? root) {
  if (root == null) return false;
  for (final entry in hitPath.path) {
    final target = entry.target;
    if (target is RenderObject && _renderSubtreeContains(target, root)) {
      return true;
    }
  }
  return false;
}

/// The render object that would receive a pointer event instead of the target.
///
/// Only meaningful when [hitPathIncludesRenderSubtree] is false: the first path
/// entry is then whatever is painted above the target at that point. Returns
/// null when the path already reaches the target or is empty.
RenderObject? topmostHitObstruction(
  HitTestResult hitPath,
  RenderObject? root,
) {
  if (root == null || hitPathIncludesRenderSubtree(hitPath, root)) {
    return null;
  }
  for (final entry in hitPath.path) {
    final target = entry.target;
    if (target is RenderObject) return target;
  }
  return null;
}

/// Bounded element lookup by the render object it owns.
typedef RenderObjectElementProbe = ({Element? element, bool truncated});

/// Finds the element whose own render object is [renderObject].
///
/// Reaching the probe bound without a match reports truncation, so a caller
/// never presents an unsearched tree as a widget without a blocker.
RenderObjectElementProbe probeElementForRenderObject(
  Element root,
  RenderObject renderObject, {
  int maxVisited = maxObstructionProbeElements,
}) {
  Element? found;
  var visited = 0;

  void visit(Element element) {
    if (found != null || visited >= maxVisited) return;
    visited++;
    if (element is RenderObjectElement &&
        identical(element.renderObject, renderObject)) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return (element: found, truncated: found == null && visited >= maxVisited);
}

/// Nearest key carried by [element] or one of its ancestors.
String? nearestKeyedLabel(Element element) {
  String? labelOf(Widget widget) {
    final key = widget.key;
    if (key == null) return null;
    final value = key is ValueKey ? key.value.toString() : key.toString();
    return value.isEmpty ? null : value;
  }

  final own = labelOf(element.widget);
  if (own != null) return own;

  String? found;
  element.visitAncestorElements((ancestor) {
    final label = labelOf(ancestor.widget);
    if (label == null) return true;
    found = label;
    return false;
  });
  return found;
}

/// Describes what covers [target] at [position].
///
/// Returns null when the hit test reaches the target itself. A non-null result
/// means a pointer event dispatched at that point would land on something else,
/// which is the difference between "the control did nothing" and "the control
/// was never reached" — the failure the live tester could not diagnose.
Map<String, dynamic>? describeObstruction(Element target, Offset position) {
  final renderObject = target.renderObject;
  if (renderObject == null) return null;

  final hitPath = hitTestElementAt(target, position);
  if (hitPath == null) return null;
  if (hitPathIncludesRenderSubtree(hitPath, renderObject)) return null;

  final blocker = topmostHitObstruction(hitPath, renderObject);
  final root = WidgetsBinding.instance.rootElement;
  final probe = blocker == null || root == null
      ? (element: null, truncated: false)
      : probeElementForRenderObject(root, blocker);
  final blockerElement = probe.element;
  final blockerKey = blockerElement == null
      ? null
      : nearestKeyedLabel(blockerElement);

  return {
    'obscured': true,
    'resolved_at': {
      'x': position.dx.round(),
      'y': position.dy.round(),
    },
    if (globalBoundsOf(renderObject) case final bounds?)
      'target_bounds': bounds,
    if (blocker != null)
      'blocker': {
        'type':
            blockerElement?.widget.runtimeType.toString() ??
            blocker.runtimeType.toString(),
        if (globalBoundsOf(blocker) case final blockerBounds?)
          'bounds': blockerBounds,
      },
    if (blockerKey != null) 'blocker_key': blockerKey,
    if (probe.truncated) 'blocker_probe_truncated': true,
  };
}

/// Collects tap targets for a selector in render order.
///
/// Shared by `ext.sanad_client.tap` and `ext.sanad_client.reveal` so the
/// inspected target and the tapped target can never disagree.
List<Element> locateTapTargets(
  Element scopeRoot, {
  required String? targetKey,
  required String? targetText,
  required String? targetType,
}) {
  final matchingElements = <Element>[];

  void walk(Element element) {
    final widget = element.widget;
    final key = widget.key;
    final keyStr = key is ValueKey ? key.value.toString() : key?.toString();

    String? textValue;
    if (widget is Text) {
      textValue = widget.data;
    } else if (widget is RichText) {
      textValue = widget.text.toPlainText();
    }

    bool isMatch = false;
    if (targetKey != null && keyStr == targetKey) {
      isMatch = true;
    } else if (targetText != null && textValue == targetText) {
      isMatch = true;
    } else if (targetType != null && widget.runtimeType.toString() == targetType) {
      isMatch = true;
    }

    if (isMatch) {
      final renderObject = element.renderObject;
      if (renderObject is RenderBox && renderObject.attached) {
        matchingElements.add(element);
      }
    }

    element.visitChildren(walk);
  }

  walk(scopeRoot);
  return matchingElements;
}

/// Registers the text entry extension without replacing the operating system text channel.
void registerEnterTextExtension() {
  developer.registerExtension('ext.sanad_client.enter_text', (
    method,
    parameters,
  ) async {
    try {
      final targetKey = parameters['key']?.trim();
      final targetText = parameters['text'];
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'Root element not found'}),
        );
      }
      if (targetText == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'Text entry requires a text value'}),
        );
      }

      Element? keyedElement;
      if (targetKey != null && targetKey.isNotEmpty) {
        void findKeyedElement(Element element) {
          if (keyedElement != null) return;
          final key = element.widget.key;
          final keyValue = key is ValueKey ? key.value.toString() : key?.toString();
          if (keyValue == targetKey) {
            keyedElement = element;
            return;
          }
          element.visitChildren(findKeyedElement);
        }

        findKeyedElement(root);
        if (keyedElement == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            json.encode({'error': 'Text input key not found: $targetKey'}),
          );
        }
      }

      EditableTextState? editableState;
      void findEditableState(Element element) {
        if (editableState != null) return;
        if (element is StatefulElement && element.state is EditableTextState) {
          final candidate = element.state as EditableTextState;
          if (keyedElement != null || candidate.widget.focusNode.hasFocus) {
            editableState = candidate;
            return;
          }
        }
        element.visitChildren(findEditableState);
      }

      findEditableState(keyedElement ?? root);
      if (editableState == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({
            'error': targetKey == null || targetKey.isEmpty
                ? 'No focused editable text field found'
                : 'No editable text field found for key: $targetKey',
          }),
        );
      }

      editableState!.updateEditingValue(
        TextEditingValue(
          text: targetText,
          selection: TextSelection.collapsed(offset: targetText.length),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      return developer.ServiceExtensionResponse.result(
        json.encode({'status': 'ok'}),
      );
    } catch (error) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({'error': error.toString()}),
      );
    }
  });
}

/// Registers the scroll extension.
void registerScrollExtension() {
  developer.registerExtension('ext.sanad_client.scroll', (
    method,
    parameters,
  ) async {
    try {
      final targetKey = parameters['key'];
      final dx = double.tryParse(parameters['dx'] ?? '0') ?? 0.0;
      final dy = double.tryParse(parameters['dy'] ?? '-300') ?? -300.0;
      final to = parameters['to']?.toLowerCase();
      final root = WidgetsBinding.instance.rootElement;

      if (root == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'Root element not found'}),
        );
      }

      ScrollableState? scrollableState;
      Element? matchedElement;

      void findElement(Element element) {
        if (matchedElement != null) return;
        final k = element.widget.key;
        final kStr = k is ValueKey ? k.value.toString() : k?.toString();
        if (targetKey != null && kStr == targetKey) {
          matchedElement = element;
          return;
        }
        element.visitChildren(findElement);
      }

      void findScrollable(Element element) {
        if (scrollableState != null) return;
        if (element is StatefulElement && element.state is ScrollableState) {
          scrollableState = element.state as ScrollableState;
          return;
        }
        element.visitChildren(findScrollable);
      }

      if (targetKey != null) {
        findElement(root);
        if (matchedElement == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            json.encode({
              'error': 'Scrollable target key not found: $targetKey',
            }),
          );
        }
        scrollableState = Scrollable.maybeOf(matchedElement!);
        if (scrollableState == null) {
          findScrollable(matchedElement!);
        }
      } else {
        findScrollable(root);
      }

      if (scrollableState == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'No Scrollable found'}),
        );
      }

      final position = scrollableState!.position;
      double targetOffset = position.pixels;

      if (to == 'top') {
        targetOffset = position.minScrollExtent;
      } else if (to == 'bottom') {
        targetOffset = position.maxScrollExtent;
      } else {
        final isHorizontal =
            position.axisDirection == AxisDirection.left || position.axisDirection == AxisDirection.right;
        final delta = isHorizontal ? dx : dy;
        targetOffset = (position.pixels - delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
      }

      final emitsUserIntent = (targetOffset - position.pixels).abs() > 0.5;
      if (emitsUserIntent) {
        UserScrollNotification(
          metrics: position,
          context: scrollableState!.context,
          direction: targetOffset < position.pixels ? ScrollDirection.forward : ScrollDirection.reverse,
        ).dispatch(scrollableState!.context);
      }
      await position.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      if (emitsUserIntent) {
        ScrollEndNotification(
          metrics: position,
          context: scrollableState!.context,
        ).dispatch(scrollableState!.context);
      }

      return developer.ServiceExtensionResponse.result(
        json.encode({
          'status': 'ok',
          'offset': position.pixels,
          'min_extent': position.minScrollExtent,
          'max_extent': position.maxScrollExtent,
        }),
      );
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({'error': e.toString()}),
      );
    }
  });
}

/// Registers the gesture / tap extension.
void registerTapExtension() {
  developer.registerExtension('ext.sanad_client.tap', (
    method,
    parameters,
  ) async {
    try {
      double? targetX = double.tryParse(parameters['x'] ?? '');
      double? targetY = double.tryParse(parameters['y'] ?? '');
      final targetKey = parameters['key'];
      final targetText = parameters['text']?.trim();
      final targetType = parameters['type']?.trim();
      final withinTarget = parameters['within']?.trim();
      final targetIndex = int.tryParse(parameters['index'] ?? '0') ?? 0;
      final holdRequest = parseTapHoldMs(parameters['hold_ms']);
      final holdError = holdRequest.error;
      if (holdError != null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': holdError}),
        );
      }
      final holdMs = holdRequest.holdMs;
      final root = WidgetsBinding.instance.rootElement;
      Element? targetElement;

      if (targetX == null || targetY == null) {
        if (root == null) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            json.encode({'error': 'Root element not found'}),
          );
        }

        final startElement = findScopeRoot(root, withinTarget);
        final matchingElements = startElement == null
            ? <Element>[]
            : locateTapTargets(
                startElement,
                targetKey: targetKey,
                targetText: targetText,
                targetType: targetType,
              );

        if (matchingElements.isEmpty) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            json.encode({'error': 'No matching element found for tap'}),
          );
        }

        if (targetIndex < 0 || targetIndex >= matchingElements.length) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            json.encode({
              'error': 'Tap index $targetIndex is out of range',
              'match_count': matchingElements.length,
            }),
          );
        }
        targetElement = matchingElements[targetIndex];

        // Auto-scroll the element into view if enclosed in a Scrollable
        try {
          await Scrollable.ensureVisible(
            targetElement,
            alignment: 0.5,
            duration: const Duration(milliseconds: 150),
          );
          await Future<void>.delayed(const Duration(milliseconds: 60));
        } catch (_) {}

        final renderBox = targetElement.renderObject as RenderBox;
        final translation = renderBox.getTransformTo(null).getTranslation();
        final size = renderBox.size;
        targetX = translation.x + size.width / 2;
        targetY = translation.y + size.height / 2;
      }

      final position = Offset(targetX, targetY);

      // A keyed target whose hit test does not include it is behind a route or
      // overlay. Dispatching anyway delivers the press to whatever is painted
      // on top, which is how a tap intended for the composer once landed on an
      // unrelated row. Report the obstruction instead of tapping.
      final keyedTarget = targetElement;
      if (keyedTarget != null) {
        final obstruction = describeObstruction(keyedTarget, position);
        if (obstruction != null) {
          return developer.ServiceExtensionResponse.result(
            json.encode({'status': 'obscured', ...obstruction}),
          );
        }
      }

      final pointer = DateTime.now().millisecondsSinceEpoch;

      GestureBinding.instance.handlePointerEvent(
        PointerAddedEvent(
          pointer: pointer,
          position: position,
          kind: PointerDeviceKind.touch,
        ),
      );

      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: pointer,
          position: position,
          kind: PointerDeviceKind.touch,
        ),
      );

      await Future<void>.delayed(Duration(milliseconds: holdMs));

      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: pointer,
          position: position,
          kind: PointerDeviceKind.touch,
        ),
      );

      GestureBinding.instance.handlePointerEvent(
        PointerRemovedEvent(
          pointer: pointer,
          position: position,
          kind: PointerDeviceKind.touch,
        ),
      );

      return developer.ServiceExtensionResponse.result(
        json.encode({
          'status': 'ok',
          'hold_ms': holdMs,
          'tapped_at': {'x': targetX.round(), 'y': targetY.round()},
        }),
      );
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({'error': e.toString()}),
      );
    }
  });
}

/// Reveals a selector without dispatching any pointer event.
///
/// `ext.sanad_client.tap` scrolls its target into view before tapping, which
/// moves bounds and would otherwise be indistinguishable from the tap's own
/// effect. A caller reveals first, captures the post-scroll tree, and only
/// then taps, so verification observes the tap alone. The extension is
/// separate from `tap` on purpose: a Client that does not register it fails
/// at isolate discovery instead of silently performing an unexpected tap.
void registerRevealExtension() {
  developer.registerExtension('ext.sanad_client.reveal', (
    method,
    parameters,
  ) async {
    try {
      final targetKey = parameters['key'];
      final targetText = parameters['text']?.trim();
      final targetType = parameters['type']?.trim();
      final withinTarget = parameters['within']?.trim();
      final targetIndex = int.tryParse(parameters['index'] ?? '0') ?? 0;
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'Root element not found'}),
        );
      }

      final startElement = findScopeRoot(root, withinTarget);
      final matchingElements = startElement == null
          ? <Element>[]
          : locateTapTargets(
              startElement,
              targetKey: targetKey,
              targetText: targetText,
              targetType: targetType,
            );

      if (matchingElements.isEmpty) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'No matching element found to reveal'}),
        );
      }
      if (targetIndex < 0 || targetIndex >= matchingElements.length) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({
            'error': 'Reveal index $targetIndex is out of range',
            'match_count': matchingElements.length,
          }),
        );
      }

      final targetElement = matchingElements[targetIndex];
      try {
        await Scrollable.ensureVisible(
          targetElement,
          alignment: 0.5,
          duration: Duration.zero,
        );
      } catch (_) {}

      final bounds = globalBoundsOf(targetElement.renderObject);
      return developer.ServiceExtensionResponse.result(
        json.encode({
          'status': 'ok',
          'revealed': true,
          'match_count': matchingElements.length,
          if (bounds != null) 'bounds': bounds,
        }),
      );
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({'error': e.toString()}),
      );
    }
  });
}

/// Convenience function that registers all interaction service extensions:
/// `ext.sanad_client.enter_text`, `ext.sanad_client.scroll`, `ext.sanad_client.tap`, and `ext.sanad_client.reveal`.
void registerInteractionExtensions() {
  registerEnterTextExtension();
  registerScrollExtension();
  registerTapExtension();
  registerRevealExtension();
}
