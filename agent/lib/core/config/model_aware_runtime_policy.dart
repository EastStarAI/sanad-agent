// The model-aware runtime policy owner extracted from core/config.dart: the
// parsed `config.yaml` policy (context limits, compaction, model capabilities),
// its exact-model capability override, and its strict YAML loader.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import 'compaction_policy.dart';
import 'thinking_control_override.dart';

class ModelCapabilityOverride {
  final bool? supportsImageInput;
  final ThinkingControlOverride? thinkingControl;

  const ModelCapabilityOverride({
    this.supportsImageInput,
    this.thinkingControl,
  });

  String get fingerprint {
    final canonicalPayload = jsonEncode({
      'supports_image_input': supportsImageInput,
      'thinking_control': thinkingControl?.fingerprint,
    });
    return sha256.convert(utf8.encode(canonicalPayload)).toString();
  }
}

class ModelAwareRuntimePolicy {
  static const defaults = ModelAwareRuntimePolicy(
    contextModelLimits: {},
    compaction: ModelAwareCompactionPolicy(
      threshold: 0.90,
      targetRatio: 0.10,
      models: {},
    ),
    modelCapabilities: {},
  );

  final Map<String, int> contextModelLimits;
  final ModelAwareCompactionPolicy compaction;
  final Map<String, ModelCapabilityOverride> modelCapabilities;

  const ModelAwareRuntimePolicy({
    required this.contextModelLimits,
    required this.compaction,
    this.modelCapabilities = const {},
  });

  ModelCapabilityOverride? capabilityOverrideFor(String modelId) {
    return modelCapabilities[modelId];
  }

  /// Normalizes a model id to the exact-key form this policy is keyed by.
  ///
  /// `contextModelLimits` and `compaction.models` are both keyed by it, and
  /// `Config` lookups resolve through the same normalization. Internal to the
  /// `core/config` owners; not part of the public Agent API.
  static String normalizeModelId(String modelId) =>
      modelId.trim().toLowerCase();

  /// The compaction pass timeout the runtime of [sanadHome] uses
  /// (`config.yaml` `compaction.passTimeoutSeconds`). A client of that
  /// runtime, such as `sanad session compact`, bounds its wait for a
  /// compaction result with it. An unreadable or invalid file yields the
  /// default, because the client must still wait for the real outcome.
  static Duration compactionPassTimeoutForHome(String sanadHome) {
    try {
      return ModelAwareRuntimePolicy.load(
        File('$sanadHome/config.yaml'),
      ).compaction.passTimeout;
    } on FormatException {
      return ModelAwareCompactionPolicy.defaultPassTimeout;
    } on FileSystemException {
      return ModelAwareCompactionPolicy.defaultPassTimeout;
    }
  }

  factory ModelAwareRuntimePolicy.load(File file) {
    if (!file.existsSync() || file.readAsStringSync().trim().isEmpty) {
      return defaults;
    }
    dynamic decoded;
    try {
      decoded = loadYaml(file.readAsStringSync());
    } catch (error) {
      throw FormatException('Invalid Sanad config.yaml: ${error.runtimeType}');
    }
    if (decoded is! YamlMap) {
      throw const FormatException(
        'Invalid Sanad config.yaml: root must be a map',
      );
    }
    final root = _stringMap(decoded, 'root');
    final context = _optionalMap(root['context'], 'context');
    rejectUnknownKeys(context, const {'modelLimits'}, 'context');
    final rawLimits = _optionalMap(
      context['modelLimits'],
      'context.modelLimits',
    );
    final limits = <String, int>{};
    for (final entry in rawLimits.entries) {
      final value = entry.value;
      if (value is! num || value.toInt() <= 0 || value != value.toInt()) {
        throw FormatException(
          'context.modelLimits.${entry.key} must be a positive integer',
        );
      }
      limits[normalizeModelId(entry.key)] = value.toInt();
    }

    final rawCompaction = _optionalMap(root['compaction'], 'compaction');
    rejectUnknownKeys(rawCompaction, const {
      'threshold',
      'targetRatio',
      'models',
      'passTimeoutSeconds',
    }, 'compaction');
    final threshold = _ratio(
      rawCompaction['threshold'],
      0.90,
      'compaction.threshold',
    );
    final targetRatio = _ratio(
      rawCompaction['targetRatio'],
      0.10,
      'compaction.targetRatio',
    );
    final rawModels = _optionalMap(
      rawCompaction['models'],
      'compaction.models',
    );
    final models = <String, CompactionPolicy>{};
    for (final entry in rawModels.entries) {
      final model = _optionalMap(entry.value, 'compaction.models.${entry.key}');
      rejectUnknownKeys(model, const {
        'threshold',
        'targetRatio',
      }, 'compaction.models.${entry.key}');
      models[normalizeModelId(entry.key)] = CompactionPolicy(
        threshold: _ratio(
          model['threshold'],
          threshold,
          'compaction.models.${entry.key}.threshold',
        ),
        targetRatio: _ratio(
          model['targetRatio'],
          targetRatio,
          'compaction.models.${entry.key}.targetRatio',
        ),
      );
    }

    final rawCapabilities = _optionalMap(
      root['model_capabilities'],
      'model_capabilities',
    );
    final capabilities = <String, ModelCapabilityOverride>{};
    for (final entry in rawCapabilities.entries) {
      final modelId = entry.key;
      if (modelId.contains('*')) {
        throw FormatException(
          'Wildcard model keys are prohibited in model_capabilities: $modelId',
        );
      }
      final rawConfig = _optionalMap(
        entry.value,
        'model_capabilities.$modelId',
      );

      // Detect and actionably reject retired nested provider schema
      final hasNestedProviderShape = rawConfig.values.any(
        (v) =>
            v is Map &&
            (v.containsKey('supports_image_input') ||
                v.containsKey('thinking_control')),
      );
      if (hasNestedProviderShape) {
        throw FormatException(
          'Nested provider-instance format in model_capabilities is no longer supported. '
          'model_capabilities must be keyed directly by exact model identity '
          '(e.g. model_capabilities."$modelId": {supports_image_input: ...}).',
        );
      }

      rejectUnknownKeys(rawConfig, const {
        'supports_image_input',
        'thinking_control',
      }, 'model_capabilities.$modelId');

      bool? supportsImageInput;
      if (rawConfig.containsKey('supports_image_input')) {
        final val = rawConfig['supports_image_input'];
        if (val != null && val is! bool) {
          throw FormatException(
            'model_capabilities.$modelId.supports_image_input must be a boolean',
          );
        }
        supportsImageInput = val as bool?;
      }

      ThinkingControlOverride? thinkingControl;
      if (rawConfig.containsKey('thinking_control')) {
        final rawTc = rawConfig['thinking_control'];
        if (rawTc != null) {
          final tcMap = _optionalMap(
            rawTc,
            'model_capabilities.$modelId.thinking_control',
          );
          thinkingControl = ThinkingControlOverride.parse(
            tcMap,
            context: 'model_capabilities.$modelId.thinking_control',
          );
        }
      }

      capabilities[modelId] = ModelCapabilityOverride(
        supportsImageInput: supportsImageInput,
        thinkingControl: thinkingControl,
      );
    }

    return ModelAwareRuntimePolicy(
      contextModelLimits: Map.unmodifiable(limits),
      compaction: ModelAwareCompactionPolicy(
        threshold: threshold,
        targetRatio: targetRatio,
        models: Map.unmodifiable(models),
        passTimeout: _positiveSeconds(
          rawCompaction['passTimeoutSeconds'],
          ModelAwareCompactionPolicy.defaultPassTimeout,
          'compaction.passTimeoutSeconds',
        ),
      ),
      modelCapabilities: Map.unmodifiable(capabilities),
    );
  }

  static Map<String, dynamic> _stringMap(dynamic value, String path) {
    if (value is! Map) {
      throw FormatException('$path must be a map');
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$path keys must be strings');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static Map<String, dynamic> _optionalMap(dynamic value, String path) =>
      value == null ? <String, dynamic>{} : _stringMap(value, path);

  /// Rejects unknown keys in one `config.yaml` map against the [known] set.
  ///
  /// Shared with `core/config/thinking_control_override.dart`, which validates
  /// a `thinking_control` declaration against the same schema rule. Internal to
  /// the `core/config` owners; not part of the public Agent API.
  static void rejectUnknownKeys(
    Map<String, dynamic> map,
    Set<String> known,
    String path,
  ) {
    final unknown = map.keys.where((key) => !known.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException('Unknown $path key: ${unknown.first}');
    }
  }

  static Duration _positiveSeconds(
    dynamic value,
    Duration fallback,
    String path,
  ) {
    if (value == null) return fallback;
    if (value is! num || value <= 0 || value != value.toInt()) {
      throw FormatException('$path must be a positive integer');
    }
    return Duration(seconds: value.toInt());
  }

  static double _ratio(dynamic value, double fallback, String path) {
    if (value == null) return fallback;
    if (value is! num || value <= 0 || value >= 1) {
      throw FormatException('$path must be between 0 and 1');
    }
    return value.toDouble();
  }
}
