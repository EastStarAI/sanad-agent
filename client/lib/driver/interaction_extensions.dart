import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:sanad_client/driver/driver_widget_filters.dart';

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
      final root = WidgetsBinding.instance.rootElement;

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
        final targetElement = matchingElements[targetIndex];

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

      await Future<void>.delayed(const Duration(milliseconds: 60));

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

      final renderBox = targetElement.renderObject;
      Map<String, dynamic>? bounds;
      if (renderBox is RenderBox && renderBox.attached) {
        final translation = renderBox.getTransformTo(null).getTranslation();
        final size = renderBox.size;
        bounds = {
          'x': translation.x.round(),
          'y': translation.y.round(),
          'width': size.width.round(),
          'height': size.height.round(),
        };
      }
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
