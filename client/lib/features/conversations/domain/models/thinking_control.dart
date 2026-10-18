enum ThinkingCapabilityStatus { supported, unsupported, unknown }

enum ThinkingControlKind {
  effort,
  toggle,
  tokenBudget,
  level,
  adaptive,
  modelVariant,
}

class ThinkingControlOptionDto {
  final String id;
  final String label;
  final bool isOff;
  final bool isProviderDefault;

  /// Actual known token count for a token-budget option supplied by the agent
  /// descriptor. Absent for `Off`, non-budget and unknown options, so the client
  /// never derives a budget from an effort-like label.
  final int? budgetTokens;

  const ThinkingControlOptionDto({
    required this.id,
    required this.label,
    this.isOff = false,
    this.isProviderDefault = false,
    this.budgetTokens,
  });

  factory ThinkingControlOptionDto.fromJson(Map<String, dynamic> json) {
    return ThinkingControlOptionDto(
      id: (json['id'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      isOff: json['is_off'] as bool? ?? false,
      isProviderDefault: json['is_provider_default'] as bool? ?? false,
      budgetTokens: _parseBudgetTokens(json['budget_tokens']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'is_off': isOff,
    'is_provider_default': isProviderDefault,
    if (budgetTokens != null) 'budget_tokens': budgetTokens,
  };
}

/// Parses the optional declared token budget. Only a positive, integral JSON
/// number is a budget; malformed, non-positive, non-integral and non-numeric
/// values are treated as absent metadata rather than as zero, a truncated value
/// or any other substituted count the agent never declared.
int? _parseBudgetTokens(Object? raw) {
  if (raw is! num) {
    return null;
  }
  if (raw is double) {
    // A fractional budget is not an integral token count: truncating it would
    // invent a value, so it stays absent metadata.
    if (!raw.isFinite || raw != raw.truncateToDouble()) {
      return null;
    }
  }
  final value = raw.toInt();
  return value > 0 ? value : null;
}

class ThinkingControlDescriptorDto {
  final ThinkingCapabilityStatus status;
  final ThinkingControlKind? kind;
  final List<ThinkingControlOptionDto> options;
  final String? defaultOptionId;
  final String capabilityRevision;
  final String source;

  const ThinkingControlDescriptorDto({
    required this.status,
    this.kind,
    this.options = const [],
    this.defaultOptionId,
    this.capabilityRevision = 'unknown',
    this.source = 'unknown',
  });

  bool get isSupported => status == ThinkingCapabilityStatus.supported;

  bool get isSelectable => isSupported && options.isNotEmpty;

  factory ThinkingControlDescriptorDto.fromJson(Map<String, dynamic> json) {
    return ThinkingControlDescriptorDto(
      status: _parseStatus(json['status']),
      kind: _parseKind(json['kind']),
      options: (json['options'] as List? ?? const [])
          .map(
            (entry) => ThinkingControlOptionDto.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .toList(growable: false),
      defaultOptionId: json['default_option_id']?.toString(),
      capabilityRevision: json['capability_revision']?.toString() ?? 'unknown',
      source: json['source']?.toString() ?? 'unknown',
    );
  }

  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (kind != null) 'kind': _kindWireValue(kind!),
    'options': options.map((option) => option.toJson()).toList(),
    if (defaultOptionId != null) 'default_option_id': defaultOptionId,
    'capability_revision': capabilityRevision,
    'source': source,
  };
}

ThinkingCapabilityStatus _parseStatus(Object? raw) {
  return switch (raw?.toString()) {
    'supported' => ThinkingCapabilityStatus.supported,
    'unsupported' => ThinkingCapabilityStatus.unsupported,
    _ => ThinkingCapabilityStatus.unknown,
  };
}

ThinkingControlKind? _parseKind(Object? raw) {
  return switch (raw?.toString()) {
    'effort' => ThinkingControlKind.effort,
    'toggle' => ThinkingControlKind.toggle,
    'token_budget' => ThinkingControlKind.tokenBudget,
    'level' => ThinkingControlKind.level,
    'adaptive' => ThinkingControlKind.adaptive,
    'model_variant' => ThinkingControlKind.modelVariant,
    _ => null,
  };
}

String _kindWireValue(ThinkingControlKind kind) {
  return switch (kind) {
    ThinkingControlKind.effort => 'effort',
    ThinkingControlKind.toggle => 'toggle',
    ThinkingControlKind.tokenBudget => 'token_budget',
    ThinkingControlKind.level => 'level',
    ThinkingControlKind.adaptive => 'adaptive',
    ThinkingControlKind.modelVariant => 'model_variant',
  };
}

class ThinkingRouteCorrectionDto {
  final String reason;
  final String? previousSelectionId;
  final DateTime correctedAt;

  const ThinkingRouteCorrectionDto({
    required this.reason,
    this.previousSelectionId,
    required this.correctedAt,
  });

  factory ThinkingRouteCorrectionDto.fromJson(Map<String, dynamic> json) {
    return ThinkingRouteCorrectionDto(
      reason: json['reason']?.toString() ?? 'thinking_option_unavailable_for_route',
      previousSelectionId: json['previous_selection_id']?.toString(),
      correctedAt: DateTime.parse(
        json['corrected_at'] as String? ?? DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }
}
