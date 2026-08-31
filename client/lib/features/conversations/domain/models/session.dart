import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';

class Session {
  final String id; // Session ID or Session Key
  final String title;
  final String? deviceId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastMessageAt;
  final String? model;
  final String? modelDisplay;
  final String? modelProvider;
  final int? routeRevision;
  final String? thinkingMode;
  final ThinkingControlDescriptorDto? thinkingControl;
  final String? reasoningLevel;
  final int? contextTokens;
  final String? workspaceId;
  final String? workspaceName;
  final String? workspacePath;
  final String? workspaceTrustState;
  final Map<String, dynamic>? metadata; // Agent-specific data

  Session({
    required this.id,
    required this.title,
    this.deviceId,
    required this.createdAt,
    required this.updatedAt,
    this.lastMessageAt,
    this.model,
    this.modelDisplay,
    this.modelProvider,
    this.routeRevision,
    this.thinkingMode,
    this.thinkingControl,
    this.reasoningLevel,
    this.contextTokens,
    this.workspaceId,
    this.workspaceName,
    this.workspacePath,
    this.workspaceTrustState,
    this.metadata,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      id: (json['id'] ?? json['session_id'])?.toString() ?? '',
      title: json['title'] ?? 'New Chat',
      deviceId: json['device_id'],
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at']) : DateTime.now(),
      updatedAt: json['updated_at'] != null ? DateTime.parse(json['updated_at']) : DateTime.now(),
      lastMessageAt: json['last_user_message_at'] != null
          ? DateTime.parse(json['last_user_message_at'])
          : (json['last_message_at'] != null ? DateTime.parse(json['last_message_at']) : null),
      model: json['model']?.toString(),
      modelDisplay: json['model_display']?.toString(),
      modelProvider: json['provider_instance_id']?.toString(),
      routeRevision: json['route_revision'] is num ? (json['route_revision'] as num).toInt() : null,
      thinkingMode: _thinkingModeFromJson(json),
      thinkingControl: _thinkingControlFromJson(json['thinking_control']),
      reasoningLevel: json['reasoning_level']?.toString(),
      contextTokens: json['context_tokens'] is num ? (json['context_tokens'] as num).toInt() : null,
      workspaceId: json['workspace_id']?.toString(),
      workspaceName: json['workspace_name']?.toString(),
      workspacePath: json['workspace_path']?.toString(),
      workspaceTrustState: json['workspace_trust_state']?.toString(),
      metadata: (json['metadata'] as Map?)?.cast<String, dynamic>(),
    );
  }

  Session copyWith({
    String? id,
    String? title,
    String? deviceId,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastMessageAt,
    String? model,
    String? modelDisplay,
    String? modelProvider,
    int? routeRevision,
    String? thinkingMode,
    bool clearThinkingMode = false,
    ThinkingControlDescriptorDto? thinkingControl,
    bool clearThinkingControl = false,
    String? reasoningLevel,
    int? contextTokens,
    String? workspaceId,
    String? workspaceName,
    String? workspacePath,
    String? workspaceTrustState,
    Map<String, dynamic>? metadata,
  }) {
    return Session(
      id: id ?? this.id,
      title: title ?? this.title,
      deviceId: deviceId ?? this.deviceId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      model: model ?? this.model,
      modelDisplay: modelDisplay ?? this.modelDisplay,
      modelProvider: modelProvider ?? this.modelProvider,
      routeRevision: routeRevision ?? this.routeRevision,
      thinkingMode: clearThinkingMode ? null : (thinkingMode ?? this.thinkingMode),
      thinkingControl: clearThinkingControl
          ? null
          : (thinkingControl ?? this.thinkingControl),
      reasoningLevel: reasoningLevel ?? this.reasoningLevel,
      contextTokens: contextTokens ?? this.contextTokens,
      workspaceId: workspaceId ?? this.workspaceId,
      workspaceName: workspaceName ?? this.workspaceName,
      workspacePath: workspacePath ?? this.workspacePath,
      workspaceTrustState: workspaceTrustState ?? this.workspaceTrustState,
      metadata: metadata ?? this.metadata,
    );
  }

  static ThinkingControlDescriptorDto? _thinkingControlFromJson(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return ThinkingControlDescriptorDto.fromJson(raw);
    }
    if (raw is Map) {
      return ThinkingControlDescriptorDto.fromJson(
        Map<String, dynamic>.from(raw),
      );
    }
    return null;
  }

  static String? _thinkingModeFromJson(Map<String, dynamic> json) {
    final correctionRaw = json['thinking_correction'];
    if (correctionRaw is Map) {
      final correction = ThinkingRouteCorrectionDto.fromJson(
        Map<String, dynamic>.from(correctionRaw),
      );
      if (!json.containsKey('thinking_mode')) {
        return null;
      }
      final nextMode = json['thinking_mode']?.toString().trim();
      if (nextMode == null || nextMode.isEmpty) {
        return null;
      }
      if (correction.previousSelectionId != null &&
          correction.previousSelectionId == nextMode) {
        return null;
      }
      return nextMode;
    }
    final mode = json['thinking_mode']?.toString().trim();
    if (mode == null || mode.isEmpty) {
      return null;
    }
    return mode;
  }
}
