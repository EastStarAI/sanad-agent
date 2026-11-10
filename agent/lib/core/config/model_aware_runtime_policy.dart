// The model-aware runtime policy owner extracted from core/config.dart: the
// parsed `config.yaml` policy (context limits, compaction, model capabilities),
// its exact-model capability override, and its strict YAML loader.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import 'builtin_policy_defaults.dart';
import 'compaction_policy.dart';
import 'context_window_policy.dart';
import 'request_dump_retention_policy.dart';
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

  /// User `context.maxLimit`: the global window cap. `null` means the user set
  /// nothing, so `ContextWindowPolicy.builtInMaxLimit` applies; `0` disables
  /// the cap.
  final int? maxLimit;

  /// Project built-in per-model window defaults. They merge key by key with
  /// [contextModelLimits] (a user entry wins for its own key) and are always
  /// subject to the cap, unlike user entries.
  final BuiltinModelPolicyDefaults<int> builtinContextModelLimits;

  final ModelAwareCompactionPolicy compaction;
  final Map<String, ModelCapabilityOverride> modelCapabilities;

  /// Diagnostic request-dump retention (`diagnostics` in `config.yaml`).
  final RequestDumpRetentionPolicy requestDumpRetention;

  const ModelAwareRuntimePolicy({
    required this.contextModelLimits,
    this.maxLimit,
    this.builtinContextModelLimits = ContextWindowPolicy.builtinModelLimits,
    required this.compaction,
    this.modelCapabilities = const {},
    this.requestDumpRetention = const RequestDumpRetentionPolicy(),
  });

  ModelCapabilityOverride? capabilityOverrideFor(String modelId) {
    return modelCapabilities[modelId];
  }

  /// The global window cap in force: the user's `context.maxLimit`, else the
  /// project built-in. `0` means no cap.
  int get effectiveContextMaxLimit =>
      maxLimit ?? ContextWindowPolicy.builtInMaxLimit;

  /// The effective per-model windows: project built-in defaults merged key by
  /// key with the user's `context.modelLimits` (user wins for its own key).
  Map<String, int> get mergedContextModelLimits =>
      builtinContextModelLimits.mergedOver(contextModelLimits);

  /// The one place a model's effective context window is decided.
  ///
  /// [providerEvidence] is what the route's provider reported (catalog cache,
  /// live probe, models.dev, known static metadata) or `null` when nothing is
  /// known. [unknownCloudFallback] is the caller's conservative value for a
  /// cloud route with no evidence while the cap is disabled; it never applies
  /// while a cap is in force.
  ContextWindowResolution resolveContextWindow({
    required String modelId,
    ProviderContextWindow? providerEvidence,
    required int unknownCloudFallback,
    bool localProvider = false,
  }) {
    return ContextWindowPolicy.resolveForNormalizedId(
      normalizedModelId: normalizeModelId(modelId),
      userModelLimits: contextModelLimits,
      builtinModelLimits: builtinContextModelLimits,
      maxLimit: maxLimit,
      providerEvidence: providerEvidence,
      unknownCloudFallback: unknownCloudFallback,
      localProvider: localProvider,
    );
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
    rejectUnknownKeys(context, const {'modelLimits', 'maxLimit'}, 'context');
    final maxLimit = _contextMaxLimit(context['maxLimit']);
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
      maxLimit: maxLimit,
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
      requestDumpRetention: _requestDumpRetention(root),
    );
  }

  /// Parses `context.maxLimit`: `0` disables the cap, a value below
  /// `ContextWindowPolicy.minimumMaxLimit` is a configuration error rather than
  /// a very aggressive pressure dial, and an absent key keeps the built-in cap.
  static int? _contextMaxLimit(dynamic value) {
    if (value == null) return null;
    if (value is! num || value < 0 || value != value.toInt()) {
      throw const FormatException(
        'context.maxLimit must be a non-negative integer',
      );
    }
    final limit = value.toInt();
    if (limit == 0) return 0;
    if (limit < ContextWindowPolicy.minimumMaxLimit) {
      throw FormatException(
        'context.maxLimit must be 0 (no cap) or at least '
        '${ContextWindowPolicy.minimumMaxLimit}',
      );
    }
    return limit;
  }

  /// Parses the diagnostic-retention block.
  ///
  /// `diagnostics.requestDumpRetentionDays` is a positive whole number of days;
  /// an invalid value fails the strict loader instead of silently falling back,
  /// so an owner-edited policy is never half-applied.
  static RequestDumpRetentionPolicy _requestDumpRetention(
    Map<String, dynamic> root,
  ) {
    final diagnostics = _optionalMap(root['diagnostics'], 'diagnostics');
    rejectUnknownKeys(diagnostics, const {
      'requestDumpRetentionDays',
    }, 'diagnostics');
    final days = diagnostics['requestDumpRetentionDays'];
    if (days == null) return const RequestDumpRetentionPolicy();
    if (days is! num || days <= 0 || days != days.toInt()) {
      throw const FormatException(
        'diagnostics.requestDumpRetentionDays must be a positive integer',
      );
    }
    return RequestDumpRetentionPolicy(retention: Duration(days: days.toInt()));
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
