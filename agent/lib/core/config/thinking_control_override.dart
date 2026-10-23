// The canonical `thinking_control` declaration schema extracted from
// core/config.dart. User settings, provider endpoint declarations, and shipped
// defaults all validate through this single parser.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../provider_thinking/thinking_control_models.dart';
import '../provider_thinking/thinking_wire_vocabulary.dart';
import 'model_aware_runtime_policy.dart';

class ThinkingControlOverride {
  final ThinkingCapabilityStatus status;
  final String? wire;
  final Map<String, dynamic> options;
  final String? defaultOption;

  const ThinkingControlOverride({
    required this.status,
    this.wire,
    this.options = const {},
    this.defaultOption,
  });

  String get fingerprint {
    if (status != ThinkingCapabilityStatus.supported) {
      return status.name;
    }
    final sortedKeys = options.keys.toList()..sort();
    final canonicalOptions = <String, dynamic>{
      for (final k in sortedKeys) k: options[k],
    };
    final canonicalPayload = jsonEncode({
      'status': status.name,
      'wire': wire,
      'default_option': defaultOption,
      'options': canonicalOptions,
    });
    return sha256.convert(utf8.encode(canonicalPayload)).toString();
  }

  static ThinkingControlOverride? tryParse(Object? raw) {
    if (raw == null) return null;
    if (raw is ThinkingControlOverride) return raw;
    if (raw is! Map) return null;
    try {
      final map = Map<String, dynamic>.from(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
      return parse(map);
    } catch (_) {
      return null;
    }
  }

  static ThinkingControlOverride parse(
    Map<String, dynamic> tcMap, {
    String context = 'thinking_control',
  }) {
    ModelAwareRuntimePolicy.rejectUnknownKeys(tcMap, const {
      'status',
      'wire',
      'options',
      'default_option',
      'default_option_id',
    }, context);

    final rawStatus = tcMap['status'];
    if (rawStatus is! String) {
      throw FormatException('$context.status is required and must be a string');
    }
    final status = ThinkingCapabilityStatus.tryParse(rawStatus.trim());
    if (status == null) {
      throw FormatException(
        'Invalid thinking_control status: $rawStatus (expected supported, unsupported, or unknown)',
      );
    }

    if (status != ThinkingCapabilityStatus.supported) {
      if (tcMap.containsKey('wire')) {
        throw FormatException(
          'thinking_control with status "${status.name}" cannot declare wire',
        );
      }
      if (tcMap.containsKey('options')) {
        final opts = tcMap['options'];
        if (opts is Map && opts.isNotEmpty) {
          throw FormatException(
            'thinking_control with status "${status.name}" cannot declare options',
          );
        }
      }
      return ThinkingControlOverride(status: status);
    }

    final wire = tcMap['wire'];
    if (wire is! String || wire.trim().isEmpty) {
      throw FormatException(
        '$context.wire is required when status is supported',
      );
    }
    const knownWires = {
      'openai_chat_effort',
      'codex_responses_effort',
      'anthropic_adaptive',
      'anthropic_budget',
      'toggle_effort',
      'google_thinking',
      'nim_kimi_thinking',
      'nim_qwen_thinking',
      'native_toggle_effort',
    };
    if (!knownWires.contains(wire.trim())) {
      throw FormatException('Unknown wire policy: $wire');
    }

    final rawOptions = tcMap['options'];
    if (rawOptions is! Map || rawOptions.isEmpty) {
      throw FormatException(
        '$context.options must be a non-empty map when status is supported',
      );
    }
    final options = <String, dynamic>{};
    for (final optEntry in rawOptions.entries) {
      if (optEntry.key is! String) {
        throw FormatException('thinking_control option keys must be strings');
      }
      final optKey = (optEntry.key as String).trim();
      if (optKey.isEmpty) {
        throw FormatException('thinking_control option key cannot be empty');
      }
      final optVal = optEntry.value;
      if (wire == 'anthropic_budget') {
        final optKeyLower = optKey.toLowerCase();
        // The documented Messages disable is `thinking: {type: disabled}`,
        // declared as an exact Boolean `false` on an off/none key. A numeric
        // value can never disable thinking.
        if ((optKeyLower == 'off' || optKeyLower == 'none') && optVal == false) {
          options[optKey] = false;
          continue;
        }
        if (optKeyLower == 'off' || optKeyLower == 'none') {
          throw FormatException(
            'anthropic_budget wire does not support disabling thinking (off/none option prohibited).',
          );
        }
        if (optVal is! num ||
            optVal.toInt() < 1024 ||
            optVal != optVal.toInt()) {
          throw FormatException(
            'anthropic_budget option "$optKey" value must be an integer of at least 1024',
          );
        }
        options[optKey] = optVal.toInt();
      } else if (wire == 'native_toggle_effort') {
        // A native Chat envelope: `thinking: {type: enabled|disabled}` for the
        // Boolean toggle, plus `reasoning_effort` with thinking enabled for an
        // effort. Off/on carry exact Booleans; an effort id carries its own
        // canonical effort value (never a Boolean and never a remap).
        final optKeyLower = optKey.toLowerCase();
        if (optVal is bool) {
          if ((optKeyLower == 'off' || optKeyLower == 'none') && optVal) {
            throw FormatException(
              'Option "$optKey" cannot map to active toggle value "$optVal". Off/none must disable thinking.',
            );
          }
          if (optKeyLower == 'on' && !optVal) {
            throw FormatException(
              'Option "$optKey" cannot map to disabled toggle value "$optVal".',
            );
          }
          if (ThinkingWireVocabulary.isAdmittedEffortTier(optKeyLower)) {
            throw FormatException(
              'Option "$optKey" cannot map to Boolean "$optVal": a canonical '
              'effort id must carry its own canonical effort value.',
            );
          }
          options[optKey] = optVal;
          continue;
        }
        if (optVal is! String ||
            !ThinkingWireVocabulary.effortTierIds.contains(
              optVal.trim().toLowerCase(),
            )) {
          throw FormatException(
            'native_toggle_effort option "$optKey" value "$optVal" must be a boolean or a positive effort (allowed: ${ThinkingWireVocabulary.effortTierIds.join(', ')})',
          );
        }
        final trimmedVal = optVal.trim().toLowerCase();
        if (optKeyLower == 'off' || optKeyLower == 'none' || optKeyLower == 'on') {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal"; toggle ids carry Booleans.',
          );
        }
        if (!ThinkingWireVocabulary.canonicalEffortMatches(
          optionId: optKey,
          value: trimmedVal,
        )) {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal": a canonical '
            'effort id must carry its own canonical value.',
          );
        }
        options[optKey] = trimmedVal;
      } else if (wire == 'toggle_effort') {
        final optKeyLower = optKey.toLowerCase();
        final bool isEnabled;
        if (optVal is bool) {
          isEnabled = optVal;
        } else if (optVal is String) {
          final strLower = optVal.trim().toLowerCase();
          if (strLower == 'true' || strLower == 'on') {
            isEnabled = true;
          } else if (strLower == 'false' || strLower == 'off') {
            isEnabled = false;
          } else {
            throw FormatException(
              'toggle_effort option "$optKey" value "$optVal" must be a boolean or on/off',
            );
          }
        } else {
          throw FormatException(
            'toggle_effort option "$optKey" value must be a boolean or on/off',
          );
        }
        if ((optKeyLower == 'off' || optKeyLower == 'none') && isEnabled) {
          throw FormatException(
            'Option "$optKey" cannot map to active toggle value "$optVal". Off/none must disable thinking.',
          );
        }
        if (optKeyLower == 'on' && !isEnabled) {
          throw FormatException(
            'Option "$optKey" cannot map to disabled toggle value "$optVal".',
          );
        }
        if (ThinkingWireVocabulary.isAdmittedEffortTier(optKeyLower)) {
          throw FormatException(
            'Option "$optKey" cannot map to Boolean "$optVal": a canonical '
            'effort id must carry its own canonical effort value, not a '
            'Boolean toggle.',
          );
        }
        options[optKey] = isEnabled;
      } else if (wire == 'nim_kimi_thinking' || wire == 'nim_qwen_thinking') {
        // NVIDIA NIM documents thinking as a finite chat_template_kwargs
        // Boolean; the self-hosted Qwen container documents the Boolean disable
        // plus an effort ladder. Boolean fields stay genuine validated Booleans
        // and a key named after a disable or an effort tier must not lie.
        final optKeyLower = optKey.toLowerCase();
        final bool? toggleValue;
        if (optVal is bool) {
          toggleValue = optVal;
        } else if (optVal is String) {
          final strLower = optVal.trim().toLowerCase();
          if (strLower == 'true' || strLower == 'on') {
            toggleValue = true;
          } else if (strLower == 'false' || strLower == 'off') {
            toggleValue = false;
          } else {
            toggleValue = null;
          }
        } else {
          toggleValue = null;
        }

        if (toggleValue == null) {
          // Effort values are only admissible on the Qwen wire, and only as an
          // exact canonical value on a key named after that same value.
          final isEffortValue =
              wire == 'nim_qwen_thinking' &&
              optVal is String &&
              ThinkingWireVocabulary.nimQwenEffortIds.contains(
                optVal.trim().toLowerCase(),
              );
          if (!isEffortValue) {
            throw FormatException(
              '$wire option "$optKey" value "$optVal" must be a boolean/on/off'
              '${wire == 'nim_qwen_thinking' ? ' or one of ${ThinkingWireVocabulary.nimQwenEffortIds.join(', ')}' : ''}',
            );
          }
          if (optKeyLower != optVal.trim().toLowerCase()) {
            throw FormatException(
              'Option "$optKey" cannot map to effort "$optVal": the option id '
              'must name the canonical effort value it sends.',
            );
          }
          if (optKeyLower == 'off' ||
              optKeyLower == 'none' ||
              optKeyLower == 'on') {
            throw FormatException(
              'Option "$optKey" cannot map to active effort "$optVal".',
            );
          }
          options[optKey] = optVal.trim().toLowerCase();
          continue;
        }

        if ((optKeyLower == 'off' || optKeyLower == 'none') && toggleValue) {
          throw FormatException(
            'Option "$optKey" cannot map to active toggle value "$optVal". '
            'Off/none must disable thinking.',
          );
        }
        if (optKeyLower == 'on' && !toggleValue) {
          throw FormatException(
            'Option "$optKey" cannot map to disabled toggle value "$optVal".',
          );
        }
        // A canonical effort-tier id must not lie in either direction: it may
        // neither hide a disable (false) nor advertise an effort while
        // dispatching an unspecified enabled/default Boolean (true).
        if (ThinkingWireVocabulary.isAdmittedEffortTier(optKeyLower)) {
          throw FormatException(
            'Option "$optKey" cannot map to Boolean "$optVal": a canonical '
            'effort id must carry its own canonical effort value, not a '
            'Boolean toggle.',
          );
        }
        options[optKey] = toggleValue;
      } else if (wire == 'openai_chat_effort' ||
          wire == 'codex_responses_effort') {
        // The documented effort vocabulary is centralized so declarations and
        // the typed serializers admit exactly the same finite values; canonical
        // `minimal` and `max` are part of it.
        const allowedEfforts = ThinkingWireVocabulary.effortIds;
        if (optVal is! String ||
            !allowedEfforts.contains(optVal.trim().toLowerCase())) {
          throw FormatException(
            '$wire option "$optKey" value "$optVal" is not a valid effort (allowed: ${allowedEfforts.join(', ')})',
          );
        }
        final trimmedVal = optVal.trim().toLowerCase();
        final optKeyLower = optKey.toLowerCase();
        if ((optKeyLower == 'off' || optKeyLower == 'none') &&
            trimmedVal != 'none') {
          throw FormatException(
            'Option "$optKey" cannot map to active effort "$optVal". Off/none must disable thinking.',
          );
        }
        if (trimmedVal == 'none' &&
            optKeyLower != 'off' &&
            optKeyLower != 'none') {
          throw FormatException(
            'Option "$optKey" cannot map to disabling effort "$optVal" unless named off/none.',
          );
        }
        // Shared no-remap invariant: any canonical effort id must carry its own
        // canonical value, not just `low`.
        if (!ThinkingWireVocabulary.canonicalEffortMatches(
          optionId: optKey,
          value: trimmedVal,
        )) {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal": a canonical '
            'effort id must carry its own canonical value.',
          );
        }
        options[optKey] = trimmedVal;
      } else if (wire == 'anthropic_adaptive') {
        final optKeyLower = optKey.toLowerCase();
        final String trimmedVal;
        if (optVal is bool) {
          if (optVal == false) {
            trimmedVal = 'off';
          } else {
            throw FormatException(
              'anthropic_adaptive option "$optKey" cannot be boolean true; specify effort tier (low, medium, high, max)',
            );
          }
        } else if (optVal is String) {
          trimmedVal = optVal.trim().toLowerCase();
        } else {
          throw FormatException(
            'anthropic_adaptive option "$optKey" value must be an effort string or false',
          );
        }
        const allowedAdaptive = {'none', 'off', 'low', 'medium', 'high', 'max'};
        if (!allowedAdaptive.contains(trimmedVal)) {
          throw FormatException(
            'anthropic_adaptive option "$optKey" value "$optVal" is not a valid effort (allowed: ${allowedAdaptive.join(', ')})',
          );
        }
        final isDisable = trimmedVal == 'none' || trimmedVal == 'off';
        if ((optKeyLower == 'off' || optKeyLower == 'none') && !isDisable) {
          throw FormatException(
            'Option "$optKey" cannot map to active effort "$optVal". Off/none must disable thinking.',
          );
        }
        if (isDisable && optKeyLower != 'off' && optKeyLower != 'none') {
          throw FormatException(
            'Option "$optKey" cannot map to disabling value "$optVal" unless named off/none.',
          );
        }
        if (!ThinkingWireVocabulary.canonicalEffortMatches(
          optionId: optKey,
          value: trimmedVal,
        )) {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal": a canonical '
            'effort id must carry its own canonical value.',
          );
        }
        options[optKey] = trimmedVal;
      } else if (wire == 'google_thinking') {
        final optKeyLower = optKey.toLowerCase();
        if (optVal is num) {
          final b = optVal.toInt();
          if (b < 0 || optVal != b) {
            throw FormatException(
              'google_thinking option "$optKey" budget must be a non-negative integer',
            );
          }
          if ((optKeyLower == 'off' || optKeyLower == 'none') && b != 0) {
            throw FormatException(
              'Option "$optKey" cannot map to active budget "$optVal". Off/none must disable thinking.',
            );
          }
          if (b == 0 && optKeyLower != 'off' && optKeyLower != 'none') {
            throw FormatException(
              'Option "$optKey" cannot map to 0 budget unless named off/none.',
            );
          }
          options[optKey] = b;
        } else if (optVal is String) {
          final trimmedVal = optVal.trim().toLowerCase();
          const allowedGoogleLevels = {
            ...ThinkingWireVocabulary.googleLevelIds,
            'none',
            'off',
          };
          if (!allowedGoogleLevels.contains(trimmedVal)) {
            throw FormatException(
              'google_thinking option "$optKey" value "$optVal" is not a valid level (allowed: ${allowedGoogleLevels.join(', ')})',
            );
          }
          final isDisable = trimmedVal == 'none' || trimmedVal == 'off';
          if ((optKeyLower == 'off' || optKeyLower == 'none') && !isDisable) {
            throw FormatException(
              'Option "$optKey" cannot map to active level "$optVal". Off/none must disable thinking.',
            );
          }
          if (isDisable && optKeyLower != 'off' && optKeyLower != 'none') {
            throw FormatException(
              'Option "$optKey" cannot map to disabling level "$optVal" unless named off/none.',
            );
          }
          // Shared no-remap invariant for the documented level ids.
          if (!ThinkingWireVocabulary.canonicalLevelMatches(
            optionId: optKey,
            value: trimmedVal,
          )) {
            throw FormatException(
              'Option "$optKey" cannot map to level "$optVal": a canonical '
              'level id must carry its own canonical value.',
            );
          }
          options[optKey] = trimmedVal;
        } else {
          throw FormatException(
            'google_thinking option "$optKey" value must be an integer budget or level string',
          );
        }
      }
    }

    final defaultOption =
        (tcMap['default_option'] ?? tcMap['default_option_id'])
            ?.toString()
            .trim();
    if (defaultOption != null && defaultOption.isNotEmpty) {
      if (!options.containsKey(defaultOption)) {
        throw FormatException(
          'default_option "$defaultOption" must be one of declared options: ${options.keys.toList()}',
        );
      }
    }

    return ThinkingControlOverride(
      status: status,
      wire: wire.trim(),
      options: Map.unmodifiable(options),
      defaultOption: (defaultOption != null && defaultOption.isNotEmpty)
          ? defaultOption
          : null,
    );
  }
}
