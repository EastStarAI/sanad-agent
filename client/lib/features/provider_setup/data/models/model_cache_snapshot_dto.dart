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
          json['supports_reasoning_output'] as bool? ?? json['supports_reasoning'] as bool? ?? false,
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
        (json['recent'] as List?)?.map((e) => RecentModelDto.fromJson(e as Map<String, dynamic>)).toList() ??
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

class ModelCacheUpdateEvent {
  static const Set<String> validStatuses = {'started', 'updated', 'failed'};

  final String providerInstanceId;
  final String status;
  final String? deviceId;

  const ModelCacheUpdateEvent({
    required this.providerInstanceId,
    required this.status,
    this.deviceId,
  });

  bool get isTerminal => status == 'updated' || status == 'failed';
  bool get isUpdated => status == 'updated';
  bool get isFailed => status == 'failed';

  factory ModelCacheUpdateEvent.fromJson(Map<String, dynamic> json, {String? deviceId}) {
    final rawPayload = json['payload'];
    final payload = rawPayload is Map<String, dynamic>
        ? rawPayload
        : rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : json;

    final rawProvider = payload['provider_instance_id'];
    if (rawProvider is! String || rawProvider.trim().isEmpty) {
      throw const FormatException('Missing or invalid provider_instance_id');
    }

    final rawStatus = payload['status'];
    if (rawStatus is! String || !validStatuses.contains(rawStatus.trim())) {
      throw FormatException('Invalid or unknown status: $rawStatus');
    }

    final String? resolvedDeviceId;
    if (deviceId != null && deviceId.trim().isNotEmpty) {
      resolvedDeviceId = deviceId.trim();
    } else if (json['device_id'] is String && (json['device_id'] as String).trim().isNotEmpty) {
      resolvedDeviceId = (json['device_id'] as String).trim();
    } else if (json['hardware_id'] is String && (json['hardware_id'] as String).trim().isNotEmpty) {
      resolvedDeviceId = (json['hardware_id'] as String).trim();
    } else {
      resolvedDeviceId = null;
    }

    return ModelCacheUpdateEvent(
      providerInstanceId: rawProvider.trim(),
      status: rawStatus.trim(),
      deviceId: resolvedDeviceId,
    );
  }

  static ModelCacheUpdateEvent? tryParse(Map<String, dynamic> json, {String? deviceId}) {
    try {
      return ModelCacheUpdateEvent.fromJson(json, deviceId: deviceId);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'provider_instance_id': providerInstanceId,
    'status': status,
    if (deviceId != null) 'device_id': deviceId,
  };
}
