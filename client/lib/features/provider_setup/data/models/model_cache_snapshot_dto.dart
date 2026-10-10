import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';

class ModelCacheInstanceDto {
  final String id;
  final String displayName;
  final String? defaultModel;
  final String status;
  final bool isDefault;
  final String cacheStatus;
  final String? fetchedAt;
  final String? warning;
  final List<ModelCacheModelDto> models;

  const ModelCacheInstanceDto({
    required this.id,
    required this.displayName,
    this.defaultModel,
    required this.status,
    required this.isDefault,
    required this.cacheStatus,
    this.fetchedAt,
    this.warning,
    required this.models,
  });

  factory ModelCacheInstanceDto.fromJson(Map<String, dynamic> json) {
    final models =
        (json['models'] as List?)
            ?.map(
              (e) => ModelCacheModelDto.fromJson(
                e is Map<String, dynamic> ? e : {'id': e.toString()},
              ),
            )
            .toList() ??
        const <ModelCacheModelDto>[];
    return ModelCacheInstanceDto(
      id: (json['id'] ?? '').toString(),
      displayName: (json['display_name'] ?? '').toString(),
      defaultModel: json['default_model']?.toString(),
      status: (json['status'] ?? 'draft').toString(),
      isDefault: (json['is_default'] as bool?) ?? false,
      cacheStatus: (json['cache_status'] ?? 'empty').toString(),
      fetchedAt: json['fetched_at']?.toString(),
      warning: json['warning']?.toString(),
      models: models,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'display_name': displayName,
    if (defaultModel != null) 'default_model': defaultModel,
    'status': status,
    'is_default': isDefault,
    'cache_status': cacheStatus,
    if (fetchedAt != null) 'fetched_at': fetchedAt,
    if (warning != null) 'warning': warning,
    'models': models.map((e) => e.toJson()).toList(),
  };
}

class ModelCacheModelDto {
  final String id;
  final String? name;
  final String? ownedBy;
  final bool supportsReasoningOutput;
  final ThinkingControlDescriptorDto? thinkingControl;

  const ModelCacheModelDto({
    required this.id,
    this.name,
    this.ownedBy,
    this.supportsReasoningOutput = false,
    this.thinkingControl,
  });

  factory ModelCacheModelDto.fromJson(Map<String, dynamic> json) {
    final thinkingRaw = json['thinking_control'];
    return ModelCacheModelDto(
      id: (json['id'] ?? json['value'] ?? '').toString(),
      name: json['name']?.toString() ?? json['label']?.toString(),
      ownedBy: json['owned_by']?.toString(),
      supportsReasoningOutput:
          json['supports_reasoning_output'] as bool? ??
          json['supports_reasoning'] as bool? ??
          false,
      thinkingControl: thinkingRaw is Map<String, dynamic>
          ? ThinkingControlDescriptorDto.fromJson(thinkingRaw)
          : thinkingRaw is Map
          ? ThinkingControlDescriptorDto.fromJson(
              Map<String, dynamic>.from(thinkingRaw),
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    if (name != null) 'name': name,
    if (ownedBy != null) 'owned_by': ownedBy,
    'supports_reasoning_output': supportsReasoningOutput,
    if (thinkingControl != null) 'thinking_control': thinkingControl!.toJson(),
  };

  @override
  String toString() => id;
}

class RecentModelDto {
  final String instanceId;
  final String? instanceDisplayName;
  final String modelId;
  final String? selectedAt;

  const RecentModelDto({
    required this.instanceId,
    this.instanceDisplayName,
    required this.modelId,
    this.selectedAt,
  });

  factory RecentModelDto.fromJson(Map<String, dynamic> json) {
    return RecentModelDto(
      instanceId: (json['instance_id'] ?? '').toString(),
      instanceDisplayName: json['instance_display_name']?.toString(),
      modelId: (json['model_id'] ?? '').toString(),
      selectedAt: json['selected_at']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'instance_id': instanceId,
    if (instanceDisplayName != null) 'instance_display_name': instanceDisplayName,
    'model_id': modelId,
    if (selectedAt != null) 'selected_at': selectedAt,
  };

  String get label => instanceDisplayName != null ? '$instanceDisplayName / $modelId' : modelId;
}

class ModelCacheSnapshotDto {
  final List<ModelCacheInstanceDto> instances;
  final List<RecentModelDto> recent;
  final String? defaultInstanceId;

  const ModelCacheSnapshotDto({
    required this.instances,
    required this.recent,
    this.defaultInstanceId,
  });

  factory ModelCacheSnapshotDto.fromJson(Map<String, dynamic> json) {
    final instances =
        (json['instances'] as List?)
            ?.map(
              (e) => ModelCacheInstanceDto.fromJson(e as Map<String, dynamic>),
            )
            .toList() ??
        const <ModelCacheInstanceDto>[];
    final recent =
        (json['recent'] as List?)
            ?.map((e) => RecentModelDto.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <RecentModelDto>[];
    return ModelCacheSnapshotDto(
      instances: instances,
      recent: recent,
      defaultInstanceId: json['default_instance_id']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'instances': instances.map((e) => e.toJson()).toList(),
    'recent': recent.map((e) => e.toJson()).toList(),
    if (defaultInstanceId != null) 'default_instance_id': defaultInstanceId,
  };
}
