// ignore: depend_on_referenced_packages
import 'package:flutter_driver/driver_extension.dart';
import 'package:sanad_client/main.dart' as app;
import 'dart:developer' as developer;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

void main() {
  // Enable integration testing with the Flutter Driver extension.
  enableFlutterDriverExtension(enableTextEntryEmulation: false);

  const Set<String> ignoredNoiseTypes = {
    'SizedBox',
    'Padding',
    '_InkFeatures',
    'MetaData',
    'LayoutId',
    'Transform',
    'ClipRRect',
    'DecoratedBox',
    'ColoredBox',
    'RepaintBoundary',
    'Semantics',
    'RawTooltip',
    'FocusScope',
    'Focus',
    '_FocusMarker',
    'AnimatedSize',
    'AnimatedBuilder',
    'Builder',
    'Align',
    'Center',
    'Opacity',
    'CustomPaint',
    'ConstrainedBox',
    'UnconstrainedBox',
    'FractionallySizedBox',
    'Flex',
    'Column',
    'Row',
    'Wrap',
    'Stack',
    'Positioned',
    'Expanded',
    'Spacer',
    'Material',
    'DefaultTextStyle',
    'IconTheme',
    '_ScaffoldSlot',
    'PhysicalModel',
    'PhysicalShape',
  };

  bool isIgnoredStateOrBuilderType(String typeName) {
    if (typeName.startsWith('BlocBuilder') ||
        typeName.startsWith('BlocListener') ||
        typeName.startsWith('BlocConsumer') ||
        typeName.startsWith('StreamBuilder') ||
        typeName.startsWith('FutureBuilder') ||
        typeName.startsWith('StatefulBuilder') ||
        typeName.startsWith('AnimatedBuilder') ||
        typeName.startsWith('Builder') ||
        typeName.startsWith('Consumer') ||
        typeName.startsWith('Provider')) {
      return true;
    }
    return false;
  }

  bool isIconGlyph(String? text) {
    if (text == null || text.trim().isEmpty) return false;
    final trimmed = text.trim();
    if (trimmed.runes.length <= 2) {
      for (final rune in trimmed.runes) {
        if ((rune >= 0xE000 && rune <= 0xF8FF) || (rune >= 0xF0000 && rune <= 0xFFFFD)) {
          return true;
        }
      }
    }
    return false;
  }

  bool isIgnoredKey(String? key) {
    if (key == null) return false;
    final trimmed = key.trim();
    if (trimmed.startsWith('[GlobalKey#') ||
        trimmed.startsWith('[LabeledGlobalKey') ||
        trimmed.startsWith('[_') ||
        trimmed.startsWith('[LocalKey#') ||
        trimmed.startsWith('sidebar-row-state:')) {
      return true;
    }
    return false;
  }

  Element? findScopeRoot(Element root, String? withinTarget) {
    if (withinTarget == null || withinTarget.trim().isEmpty) {
      return root;
    }
    final target = withinTarget.trim().toLowerCase();
    Element? matched;

    void search(Element element) {
      if (matched != null) return;
      final widget = element.widget;
      final key = widget.key;
      String? keyString;
      if (key != null) {
        keyString = key is ValueKey ? key.value.toString() : key.toString();
      }

      String? textValue;
      if (widget is Text) {
        textValue = widget.data;
      } else if (widget is RichText) {
        textValue = widget.text.toPlainText();
      }

      if ((keyString != null && keyString.toLowerCase().contains(target)) ||
          (textValue != null && textValue.toLowerCase().contains(target)) ||
          widget.runtimeType.toString().toLowerCase().contains(target)) {
        matched = element;
        return;
      }

      element.visitChildren(search);
    }

    search(root);

    return matched;
  }

  // Register our custom interactive UI inspection extension
  developer.registerExtension('ext.sanad_client.inspect_ui', (method, parameters) async {
    final widgets = <Map<String, dynamic>>[];
    final includeBounds = parameters['includeBounds'] != 'false';
    final onlyWithKeys = parameters['onlyWithKeys'] == 'true';
    final interactiveOnly = parameters['interactive'] == 'true' || parameters['interactiveOnly'] == 'true';
    final filterQuery = parameters['filter']?.trim().toLowerCase();
    final withinTarget = parameters['within']?.trim();

    void walk(
      Element element, {
      Element? parentElement,
      bool insideConsolidatedRow = false,
      String? inheritedTooltip,
    }) {
      final widget = element.widget;
      final widgetType = widget.runtimeType.toString();

      // Skip layout noise widgets
      if (ignoredNoiseTypes.contains(widgetType)) {
        element.visitChildren(
          (child) => walk(
            child,
            parentElement: element,
            insideConsolidatedRow: insideConsolidatedRow,
            inheritedTooltip: inheritedTooltip,
          ),
        );
        return;
      }

      // Skip internal state management wrappers
      if (isIgnoredStateOrBuilderType(widgetType)) {
        element.visitChildren(
          (child) => walk(
            child,
            parentElement: element,
            insideConsolidatedRow: insideConsolidatedRow,
            inheritedTooltip: inheritedTooltip,
          ),
        );
        return;
      }

      // Skip anonymous InkWell
      if (widget is InkWell && widget.key == null) {
        element.visitChildren(
          (child) => walk(
            child,
            parentElement: element,
            insideConsolidatedRow: insideConsolidatedRow,
            inheritedTooltip: inheritedTooltip,
          ),
        );
        return;
      }

      // Skip RichText if parent is already a Text widget
      if (widget is RichText && parentElement?.widget is Text) {
        element.visitChildren(
          (child) => walk(
            child,
            parentElement: element,
            insideConsolidatedRow: insideConsolidatedRow,
            inheritedTooltip: inheritedTooltip,
          ),
        );
        return;
      }

      final key = widget.key;
      String? keyString;
      if (key != null) {
        final rawKey = key is ValueKey ? key.value.toString() : key.toString();
        if (!isIgnoredKey(rawKey)) {
          keyString = rawKey;
        }
      }

      String? textValue;
      if (widget is Text) {
        textValue = widget.data;
      } else if (widget is RichText) {
        textValue = widget.text.toPlainText();
      } else if (widget is SelectableText) {
        textValue = widget.data;
      }

      // Skip icon font glyphs
      if (isIconGlyph(textValue)) {
        element.visitChildren(
          (child) => walk(
            child,
            parentElement: element,
            insideConsolidatedRow: insideConsolidatedRow,
            inheritedTooltip: inheritedTooltip,
          ),
        );
        return;
      }

      String? hintValue;
      if (widget is TextField) {
        hintValue = widget.decoration?.hintText;
        if (!widget.obscureText) {
          textValue ??= widget.controller?.text;
        }
        if (!widget.obscureText && textValue == null) {
          void findEditableText(Element child) {
            if (textValue != null) return;
            final childWidget = child.widget;
            if (childWidget is EditableText) {
              textValue = childWidget.controller.text;
              return;
            }
            child.visitChildren(findEditableText);
          }

          element.visitChildren(findEditableText);
        }
      }

      var tooltipValue = inheritedTooltip;
      if (widget is Tooltip && (widget.message?.trim().isNotEmpty ?? false)) {
        tooltipValue = widget.message;
      }

      final effectiveText = textValue;
      final isTextField = widget is TextField;
      final hasKey = keyString != null;
      final isText = effectiveText?.trim().isNotEmpty ?? false;
      final hasTooltip = tooltipValue != null && tooltipValue.trim().isNotEmpty;
      final isButton =
          widget is ElevatedButton ||
          widget is FilledButton ||
          widget is OutlinedButton ||
          widget is TextButton ||
          widget is IconButton ||
          widget is PopupMenuButton;

      final isStandaloneTooltip = widget is Tooltip && !hasKey;
      if (isStandaloneTooltip) {
        element.visitChildren(
          (child) => walk(
            child,
            parentElement: element,
            insideConsolidatedRow: insideConsolidatedRow,
            inheritedTooltip: tooltipValue,
          ),
        );
        return;
      }

      // Generic consolidation for any keyed or interactive container widget
      if (hasKey && !isText && !isTextField) {
        String? primaryText;
        void findPrimaryText(Element el) {
          if (primaryText != null) return;
          final w = el.widget;
          if (w is Text &&
              w.data != null &&
              w.data!.trim().isNotEmpty &&
              !isIconGlyph(w.data) &&
              !RegExp(r'^\d+[smhdwmo]$').hasMatch(w.data!.trim())) {
            primaryText = w.data;
            return;
          }
          el.visitChildren(findPrimaryText);
        }

        element.visitChildren(findPrimaryText);

        String? semanticsLabel;
        bool? semanticsSelected;
        bool? semanticsButton;
        void findSemantics(Element el) {
          final candidate = el.widget;
          if (candidate is Semantics) {
            semanticsLabel ??= candidate.properties.label;
            semanticsSelected ??= candidate.properties.selected;
            if (candidate.properties.button == true) semanticsButton = true;
          }
          el.visitChildren(findSemantics);
        }

        element.visitChildren(findSemantics);

        final matchesFilter =
            filterQuery == null ||
            filterQuery.isEmpty ||
            keyString.toLowerCase().contains(filterQuery) ||
            (primaryText?.toLowerCase().contains(filterQuery) ?? false) ||
            (tooltipValue?.toLowerCase().contains(filterQuery) ?? false) ||
            (semanticsLabel?.toLowerCase().contains(filterQuery) ?? false) ||
            widgetType.toLowerCase().contains(filterQuery);

        if (matchesFilter) {
          final Map<String, dynamic> data = {
            'type': widgetType,
            'key': keyString,
          };
          if (primaryText != null) data['text'] = primaryText;
          if (tooltipValue != null && tooltipValue.trim().isNotEmpty) {
            data['tooltip'] = tooltipValue;
          }
          if (semanticsLabel?.trim().isNotEmpty ?? false) {
            data['semantics_label'] = semanticsLabel;
          }
          if (semanticsSelected != null) {
            data['selected'] = semanticsSelected;
          }
          if (semanticsButton == true) {
            data['button'] = true;
          }

          if (includeBounds) {
            final renderObject = element.renderObject;
            if (renderObject is RenderBox && renderObject.hasSize && renderObject.attached) {
              try {
                final translation = renderObject.getTransformTo(null).getTranslation();
                final size = renderObject.size;
                data['bounds'] = {
                  'x': translation.x.round(),
                  'y': translation.y.round(),
                  'width': size.width.round(),
                  'height': size.height.round(),
                };
              } catch (_) {}
            }
          }

          widgets.add(data);
        }

        // If keyed container has children with other keys, walk them; otherwise don't emit raw un-keyed text duplicates
        void walkKeyedChildren(Element childEl) {
          final childWidget = childEl.widget;
          final childKey = childWidget.key;
          final childKeyStr = childKey is ValueKey ? childKey.value.toString() : childKey?.toString();
          if (childKeyStr != null && !isIgnoredKey(childKeyStr)) {
            walk(
              childEl,
              parentElement: element,
              insideConsolidatedRow: true,
              inheritedTooltip: tooltipValue,
            );
          } else {
            childEl.visitChildren(walkKeyedChildren);
          }
        }

        element.visitChildren(walkKeyedChildren);
        return;
      }

      final isInteractive = isButton || isTextField || hasTooltip || (hasKey && !isText);

      if (interactiveOnly && !isInteractive) {
        element.visitChildren(
          (child) => walk(
            child,
            parentElement: element,
            insideConsolidatedRow: insideConsolidatedRow,
            inheritedTooltip: inheritedTooltip,
          ),
        );
        return;
      }

      if ((hasKey || isTextField || isText || hasTooltip || isButton) && (!onlyWithKeys || hasKey)) {
        final matchesFilter =
            filterQuery == null ||
            filterQuery.isEmpty ||
            (keyString != null && keyString.toLowerCase().contains(filterQuery)) ||
            (effectiveText != null && effectiveText.toLowerCase().contains(filterQuery)) ||
            (hintValue != null && hintValue.toLowerCase().contains(filterQuery)) ||
            (tooltipValue != null && tooltipValue.toLowerCase().contains(filterQuery)) ||
            widgetType.toLowerCase().contains(filterQuery);

        if (matchesFilter) {
          final Map<String, dynamic> data = {
            'type': widgetType,
          };
          if (keyString != null) data['key'] = keyString;
          if (effectiveText?.trim().isNotEmpty ?? false) {
            data['text'] = effectiveText;
          }
          if (hintValue != null && hintValue.trim().isNotEmpty) {
            data['hint'] = hintValue;
          }
          if (tooltipValue != null && tooltipValue.trim().isNotEmpty) {
            data['tooltip'] = tooltipValue;
          }

          if (includeBounds) {
            final renderObject = element.renderObject;
            if (renderObject is RenderBox && renderObject.hasSize && renderObject.attached) {
              try {
                final translation = renderObject.getTransformTo(null).getTranslation();
                final size = renderObject.size;
                data['bounds'] = {
                  'x': translation.x.round(),
                  'y': translation.y.round(),
                  'width': size.width.round(),
                  'height': size.height.round(),
                };
              } catch (_) {}
            }
          }

          widgets.add(data);
        }
      }

      element.visitChildren(
        (child) => walk(
          child,
          parentElement: element,
          insideConsolidatedRow: insideConsolidatedRow,
          inheritedTooltip: inheritedTooltip,
        ),
      );
    }

    try {
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'Root element not found'}),
        );
      }
      final startElement = findScopeRoot(root, withinTarget);
      if (startElement == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': 'UI scope not found: $withinTarget'}),
        );
      }
      walk(startElement);
      return developer.ServiceExtensionResponse.result(
        json.encode({
          'status': 'ok',
          'count': widgets.length,
          'elements': widgets,
        }),
      );
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({'error': e.toString()}),
      );
    }
  });

  // Register text entry without replacing the operating system text channel.
  developer.registerExtension('ext.sanad_client.enter_text', (method, parameters) async {
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

  // Register scroll extension
  developer.registerExtension('ext.sanad_client.scroll', (method, parameters) async {
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
            json.encode({'error': 'Scrollable target key not found: $targetKey'}),
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

      await position.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );

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

  // Register gesture / tap extension
  developer.registerExtension('ext.sanad_client.tap', (method, parameters) async {
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

          // Check if this is a SidebarConversationRow that contains the targetText
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

        final startElement = findScopeRoot(root, withinTarget);
        if (startElement != null) {
          walk(startElement);
        }

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

  app.main();
}
