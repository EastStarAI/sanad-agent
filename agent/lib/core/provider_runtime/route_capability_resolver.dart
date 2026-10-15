import '../../engine/adapters/models_dev_service.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import '../config.dart';
import '../provider_thinking/native_thinking_directive.dart';
import '../provider_thinking/thinking_control_models.dart';
import '../provider_thinking/thinking_selection_resolver.dart';
import 'provider_instance_repository.dart';
import 'provider_model_id.dart';

enum RouteImageSupport { supported, unsupported, unknown }

/// Identifiable local image capability rejection thrown before lossy dispatch
/// when image input is unsupported or unknown for the active model route.
final class LocalImageCapabilityException extends UnsupportedError {
  final String modelId;
  final RouteImageSupport imageSupport;

  LocalImageCapabilityException({
    required this.modelId,
    required this.imageSupport,
  }) : super(switch (imageSupport) {
         RouteImageSupport.unsupported =>
           'The selected model "$modelId" does not support image input.',
         RouteImageSupport.unknown =>
           'Image input capability is unknown for model "$modelId". Specify supports_image_input in config.yaml under model_capabilities.',
         RouteImageSupport.supported =>
           'Image input is supported for model "$modelId".',
       });

  String get userMessage => message ?? 'Image input is not supported.';
}

/// Coherent authoritative resolved capability snapshot for a specific provider/model route.
final class RouteCapabilityProfile {
  final String providerInstanceId;
  final String modelId;
  final RouteImageSupport imageSupport;
  final ThinkingControlDescriptor? thinkingDescriptor;
  final NativeThinkingDirective? thinkingDirective;
  final String? thinkingSelectionId;
  final String evidenceSource;
  final ModelCapabilityOverride? rawOverride;

  const RouteCapabilityProfile({
    required this.providerInstanceId,
    required this.modelId,
    required this.imageSupport,
    this.thinkingDescriptor,
    this.thinkingDirective,
    this.thinkingSelectionId,
    required this.evidenceSource,
    this.rawOverride,
  });

  bool get supportsImageInput => imageSupport == RouteImageSupport.supported;
}

/// Resolves exact-route capabilities following the 4-tier product precedence:
/// 1. Explicit config override (highest precedence)
/// 2. Recognized endpoint per-model modality metadata
/// 3. Trusted exact intrinsic model catalog evidence, independent of the route
/// 4. Fail-closed unknown when no model evidence is established
class RouteCapabilityResolver {
  final ProviderInstanceRepository? _instances;
  final Config? _config;
  final ModelsDevService? _modelsDevService;
  final ThinkingSelectionResolver? _thinkingResolver;

  const RouteCapabilityResolver({
    ProviderInstanceRepository? instances,
    Config? config,
    ModelsDevService? modelsDevService,
    ThinkingSelectionResolver? thinkingResolver,
  }) : _instances = instances,
       _config = config,
       _modelsDevService = modelsDevService,
       _thinkingResolver = thinkingResolver;

  /// Parses recognized image support declarations from raw endpoint model metadata.
  /// Returns `true` if declared supported, `false` if declared unsupported/text-only,
  /// or `null` if unestablished/missing.
  static bool? parseDeclaredImageSupport(Map<String, Object?> metadata) {
    if (metadata.isEmpty) return null;

    if (metadata.containsKey('supports_image_input')) {
      final val = metadata['supports_image_input'];
      if (val is bool) return val;
    }
    if (metadata.containsKey('image_input')) {
      final val = metadata['image_input'];
      if (val is bool) return val;
    }

    final capabilities = metadata['capabilities'];
    if (capabilities is Map) {
      if (capabilities.containsKey('vision') &&
          capabilities['vision'] is bool) {
        return capabilities['vision'] as bool;
      }
      if (capabilities.containsKey('image_input') &&
          capabilities['image_input'] is bool) {
        return capabilities['image_input'] as bool;
      }
      if (capabilities.containsKey('supports_image_input') &&
          capabilities['supports_image_input'] is bool) {
        return capabilities['supports_image_input'] as bool;
      }
    } else {
      final declared = _validatedCapabilityNames(capabilities);
      if (declared != null &&
          (declared.contains('vision') || declared.contains('image'))) {
        return true;
      }
      // Generic features such as ['tools'] are not complete modality evidence.
    }

    final rawOllamaCaps = metadata['ollama_capabilities'];
    if (rawOllamaCaps is List && rawOllamaCaps.isNotEmpty) {
      final declared = _validatedCapabilityNames(rawOllamaCaps);
      // A malformed complete-list declaration establishes neither state.
      if (declared == null) return null;
      return declared.contains('vision') || declared.contains('image');
    }

    final inputModalities = _validatedCapabilityNames(
      metadata['input_modalities'],
    );
    if (inputModalities != null) return inputModalities.contains('image');

    final modalities = metadata['modalities'];
    final declaredModalities = _validatedCapabilityNames(
      modalities is Map ? modalities['input'] : modalities,
    );
    if (declaredModalities != null) return declaredModalities.contains('image');

    final architecture = metadata['architecture'];
    if (architecture is Map) {
      final modality = architecture['modality']?.toString().toLowerCase();
      if (modality != null && modality.isNotEmpty) {
        if (modality.contains('image')) return true;
        if (modality.contains('text->text')) return false;
      }
    }

    if (metadata.containsKey('supports_vision') &&
        metadata['supports_vision'] is bool) {
      return metadata['supports_vision'] as bool;
    }
    if (metadata.containsKey('vision') && metadata['vision'] is bool) {
      return metadata['vision'] as bool;
    }

    return null;
  }

  /// Nonempty, well-typed declaration only; coercion cannot establish support.
  static Set<String>? _validatedCapabilityNames(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final names = <String>{};
    for (final entry in raw) {
      if (entry is! String || entry.trim().isEmpty) return null;
      names.add(entry.trim().toLowerCase());
    }
    return names;
  }

  /// Authoritatively and synchronously resolves capabilities from memory cache and overrides.
  RouteCapabilityProfile resolveSync({
    required String providerInstanceId,
    required String modelId,
    String? thinkingMode,
    String? baseUrl,
  }) {
    // 1. Explicit override
    final override = _config?.modelAwarePolicy.capabilityOverrideFor(modelId);
    RouteImageSupport imageSupport = RouteImageSupport.unknown;
    String evidenceSource = 'unknown';

    if (override?.supportsImageInput != null) {
      imageSupport = override!.supportsImageInput!
          ? RouteImageSupport.supported
          : RouteImageSupport.unsupported;
      evidenceSource = 'override';
    } else {
      // 2. Recognized actual-endpoint per-model metadata
      final cachedOption = _lookupCachedModelOption(
        providerInstanceId,
        modelId,
      );
      final declared = cachedOption != null
          ? parseDeclaredImageSupport(cachedOption.modelMetadata)
          : null;

      if (declared != null) {
        imageSupport = declared
            ? RouteImageSupport.supported
            : RouteImageSupport.unsupported;
        evidenceSource = 'endpoint_metadata';
      } else {
        // 3. Trusted catalog mapping (models.dev)
        // Intrinsic model knowledge resolved purely by model identity across catalog namespaces.
        // Provider instance UUID, template, and endpoint must not select or hint intrinsic metadata.
        final syncSupported = _modelsDevService?.supportsImageInputSync(
          modelId,
        );
        if (syncSupported != null) {
          imageSupport = syncSupported
              ? RouteImageSupport.supported
              : RouteImageSupport.unsupported;
          evidenceSource = 'catalog';
        }
      }
      // 4. Custom routes without declared metadata or catalog match remain unknown (no name guessing)
    }

    // Thinking capability resolution
    ThinkingControlDescriptor? thinkingDescriptor;
    NativeThinkingDirective? thinkingDirective;
    String? resolvedThinkingSelectionId;

    if (_thinkingResolver != null) {
      final trimmedMode = thinkingMode?.trim();
      if (trimmedMode != null && trimmedMode.isNotEmpty) {
        // Explicit selection requested: do NOT catch ThinkingSelectionException!
        // Invalid explicit choice must halt turn admission actionably.
        final resolution = _thinkingResolver.resolve(
          providerInstanceId: providerInstanceId,
          modelId: modelId,
          selectionId: trimmedMode,
        );
        thinkingDescriptor = resolution.descriptor;
        thinkingDirective = resolution.directive;
        resolvedThinkingSelectionId = resolution.selectionId;
      } else {
        try {
          final resolution = _thinkingResolver.resolve(
            providerInstanceId: providerInstanceId,
            modelId: modelId,
            selectionId: null,
          );
          thinkingDescriptor = resolution.descriptor;
          thinkingDirective = resolution.directive;
          resolvedThinkingSelectionId = resolution.selectionId;
        } catch (_) {
          // Provider default / unconfigured falls back gracefully
        }
      }
    }

    return RouteCapabilityProfile(
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      imageSupport: imageSupport,
      thinkingDescriptor: thinkingDescriptor,
      thinkingDirective: thinkingDirective,
      thinkingSelectionId: resolvedThinkingSelectionId,
      evidenceSource: evidenceSource,
      rawOverride: override,
    );
  }

  /// Authoritatively resolves capabilities for a route at turn admission.
  /// Uses synchronous prepared/cached state without hot-path network I/O.
  Future<RouteCapabilityProfile> resolve({
    required String providerInstanceId,
    required String modelId,
    String? thinkingMode,
    String? baseUrl,
  }) async {
    return resolveSync(
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      thinkingMode: thinkingMode,
      baseUrl: baseUrl,
    );
  }

  ModelOption? _lookupCachedModelOption(String instanceId, String modelId) {
    if (_instances == null) return null;
    final instance = _instances.findById(instanceId);
    if (instance == null) return null;

    final cached = _instances.readModelCache(instanceId, 'models');
    if (cached == null) return null;

    if (cached['config_revision'] != instance.configRevision ||
        cached['credential_revision'] != instance.credentialRevision) {
      return null;
    }

    final modelsList = cached['models'] as List<dynamic>?;
    if (modelsList == null) return null;

    final target = ProviderModelId.normalize(
      templateId: instance.templateId,
      protocol: instance.protocol,
      rawModelId: modelId,
    );
    for (final raw in modelsList) {
      if (raw is Map) {
        try {
          final rawMap = Map<String, dynamic>.from(raw);
          if (!rawMap.containsKey('value') && rawMap.containsKey('id')) {
            rawMap['value'] = rawMap['id'];
          }
          final option = ModelOption.fromJson(rawMap);
          final opt = ProviderModelId.normalize(
            templateId: instance.templateId,
            protocol: instance.protocol,
            rawModelId: option.value,
          );
          if (opt.isNotEmpty && opt == target) {
            return option;
          }
        } catch (_) {
          // Gracefully skip malformed entries
          continue;
        }
      }
    }
    return null;
  }
}
