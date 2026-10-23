import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:sanad_client/driver/driver_widget_filters.dart';
import 'package:sanad_client/driver/ui_inspection_state.dart';
import 'package:sanad_client/driver/ui_inspection_text.dart';
import 'package:sanad_client/driver/ui_type_census.dart';

/// Registers the custom interactive UI inspection extension (`ext.sanad_client.inspect_ui`).
void registerInspectUiExtension() {
  developer.registerExtension('ext.sanad_client.inspect_ui', (
    method,
    parameters,
  ) async {
    final widgets = <Map<String, dynamic>>[];
    final includeBounds = parameters['includeBounds'] != 'false';
    final onlyWithKeys = parameters['onlyWithKeys'] == 'true';
    final interactiveOnly = parameters['interactive'] == 'true' || parameters['interactiveOnly'] == 'true';
    final filterQuery = parameters['filter']?.trim().toLowerCase();
    final withinTarget = parameters['within']?.trim();
    final typeCensus = parameters['typeCensus'] == 'true';

    // A type census enumerates rendered widget runtime types instead of the
    // inspected element subset, so a caller can prove that a type is genuinely
    // absent rather than merely uninspected. It is bounded by the walk and
    // reports truncation explicitly.
    if (typeCensus) {
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
        final census = boundedRenderedTypeCensus<Element>(
          root: startElement,
          label: (element) => element.widget.runtimeType.toString(),
          children: (element) {
            final childElements = <Element>[];
            element.visitChildren(childElements.add);
            return childElements;
          },
        );
        return developer.ServiceExtensionResponse.result(
          json.encode({
            'status': 'ok',
            'types': census.types,
            'type_count': census.types.length,
            'truncated': census.truncated,
            'visited_elements': census.visitedElements,
          }),
        );
      } catch (e) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          json.encode({'error': e.toString()}),
        );
      }
    }

    void walk(
      Element element, {
      Element? parentElement,
      bool insideConsolidatedRow = false,
      String? inheritedTooltip,
    }) {
      final widget = element.widget;
      final widgetType = widget.runtimeType.toString();

      // Skip layout noise widgets unless explicitly keyed
      if (ignoredNoiseTypes.contains(widgetType)) {
        final key = widget.key;
        final rawKey = key is ValueKey ? key.value.toString() : key?.toString();
        if (rawKey == null || isIgnoredKey(rawKey)) {
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

      String? textValue = inspectableWidgetText(widget);

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
        bool acceptsPrimaryText(String candidateText) =>
            !isIconGlyph(candidateText) && !RegExp(r'^\d+[smhdwmo]$').hasMatch(candidateText.trim());
        final isMessageBody =
            keyString.startsWith('user_message_body:') || keyString.startsWith('assistant_message_body:');
        final primaryText = isMessageBody
            ? allInspectableDescendantText(element, accept: acceptsPrimaryText)
            : firstInspectableDescendantText(
                element,
                accept: acceptsPrimaryText,
              );

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
          final enabled = inspectableElementEnabled(element);
          if (enabled != null) data['enabled'] = enabled;

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
          final Map<String, dynamic> data = {'type': widgetType};
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
          final enabled = inspectableWidgetEnabled(widget);
          if (enabled != null) data['enabled'] = enabled;

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
}
