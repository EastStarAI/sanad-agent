/// Typed thinking-control capability models (Task 43 Gate A).
///
/// These models describe what thinking options a model exposes. They are
/// transport-neutral, JSON-safe, and carry no native request wire shape.
library;

/// Whether the effective model route exposes user-selectable thinking control.
enum ThinkingCapabilityStatus {
  supported,
  unsupported,
  unknown;

  static ThinkingCapabilityStatus? tryParse(String? raw) {
    if (raw == null) return null;
    return switch (raw) {
      'supported' => ThinkingCapabilityStatus.supported,
      'unsupported' => ThinkingCapabilityStatus.unsupported,
      'unknown' => ThinkingCapabilityStatus.unknown,
      _ => null,
    };
  }

  String get wireValue => name;
}

/// Native control family advertised for a supported model route.
enum ThinkingControlKind {
  effort,
  toggle,
  tokenBudget,
  level,
  adaptive,
  modelVariant;

  static ThinkingControlKind? tryParse(String? raw) {
    if (raw == null) return null;
    return switch (raw) {
      'effort' => ThinkingControlKind.effort,
      'toggle' => ThinkingControlKind.toggle,
      'token_budget' || 'tokenBudget' => ThinkingControlKind.tokenBudget,
      'level' => ThinkingControlKind.level,
      'adaptive' => ThinkingControlKind.adaptive,
      'model_variant' || 'modelVariant' => ThinkingControlKind.modelVariant,
      _ => null,
    };
  }

  String get wireValue => switch (this) {
    ThinkingControlKind.effort => 'effort',
    ThinkingControlKind.toggle => 'toggle',
    ThinkingControlKind.tokenBudget => 'token_budget',
    ThinkingControlKind.level => 'level',
    ThinkingControlKind.adaptive => 'adaptive',
    ThinkingControlKind.modelVariant => 'model_variant',
  };
}

/// One selectable thinking option for the client composer.
class ThinkingControlOption {
  /// Stable source-neutral selection id persisted with the route.
  final String id;

  /// English UI label.
  final String label;

  /// Whether this option explicitly disables thinking controls.
  final bool isOff;

  /// Whether this option is the known native default of its model.
  ///
  /// It marks a concrete default *value* the provider applies when the control
  /// is omitted, which is metadata only. It is not an omission selection:
  /// omitting the control stays the separate provider-Default contract that
  /// emits no request field at all, and this flag never dispatches by itself.
  final bool isProviderDefault;

  /// Positive token count this option requests, or `null`.
  ///
  /// Present only for an option that is genuinely a token budget, and only
  /// with the positive token count the route actually resolves for this
  /// exact option id — taken from the owning policy's authoritative budget
  /// resolution, never a duplicated table. It is absent for Off, for
  /// effort/level/toggle options, and whenever the count is unknown, so a
  /// client can disclose the effective budget without inventing one.
  final int? budgetTokens;

  const ThinkingControlOption({
    required this.id,
    required this.label,
    this.isOff = false,
    this.isProviderDefault = false,
    this.budgetTokens,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'label': label,
    'is_off': isOff,
    'is_provider_default': isProviderDefault,
    // A budget option's token count is positive by contract; anything else is
    // not a budget and stays absent instead of shipping a meaningless zero.
    if (budgetTokens != null && budgetTokens! > 0)
      'budget_tokens': budgetTokens,
  };

  factory ThinkingControlOption.fromMap(Map<String, dynamic> map) {
    return ThinkingControlOption(
      id: map['id'] as String,
      label: map['label'] as String,
      isOff: map['is_off'] as bool? ?? false,
      isProviderDefault: map['is_provider_default'] as bool? ?? false,
      budgetTokens: parseBudgetTokens(map['budget_tokens']),
    );
  }

  /// Parses a disclosed budget count: a whole positive token count, or `null`.
  ///
  /// A fractional, non-finite or non-positive count is not a budget, so it is
  /// treated as unavailable rather than truncated, rounded or allowed to
  /// throw. A malformed value from a peer therefore never becomes a fabricated
  /// token count, and never fails a metadata round-trip.
  static int? parseBudgetTokens(Object? raw) {
    if (raw is! num || !raw.isFinite) return null;
    if (raw is double && raw.truncateToDouble() != raw) return null;
    final count = raw.toInt();
    return count > 0 ? count : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThinkingControlOption &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          label == other.label &&
          isOff == other.isOff &&
          isProviderDefault == other.isProviderDefault &&
          budgetTokens == other.budgetTokens;

  @override
  int get hashCode =>
      Object.hash(id, label, isOff, isProviderDefault, budgetTokens);
}

/// Per-model thinking capability descriptor shipped with model snapshots.
class ThinkingControlDescriptor {
  final ThinkingCapabilityStatus status;
  final ThinkingControlKind? kind;
  final List<ThinkingControlOption> options;

  /// Known native default option id, or `null` when no default is known.
  ///
  /// It names the option the provider applies when the control is omitted, as
  /// truthful metadata; it is not an omission selection. Omitting the control
  /// stays the separate provider-Default contract that emits no request field.
  final String? defaultOptionId;

  /// Authority layer that supplied [defaultOptionId] (`config_override`,
  /// `endpoint_declared`, `provider_reported`, `shipped_default`, `models_dev`,
  /// `models_dev_canonical`), or `null` when no default is known. It differs
  /// from the options' layer when a lower layer filled a missing default.
  final String? defaultSource;
  final String capabilityRevision;
  final String source;
  final DateTime? observedAt;

  const ThinkingControlDescriptor({
    required this.status,
    this.kind,
    this.options = const [],
    this.defaultOptionId,
    this.defaultSource,
    required this.capabilityRevision,
    required this.source,
    this.observedAt,
  });

  bool get isSupported => status == ThinkingCapabilityStatus.supported;

  bool get isSelectable => isSupported && options.isNotEmpty;

  bool containsOptionId(String? selectionId) {
    if (selectionId == null || selectionId.trim().isEmpty) {
      return false;
    }
    return options.any((option) => option.id == selectionId);
  }

  Map<String, dynamic> toMap() => {
    'status': status.wireValue,
    if (kind != null) 'kind': kind!.wireValue,
    'options': options.map((option) => option.toMap()).toList(),
    if (defaultOptionId != null) 'default_option_id': defaultOptionId,
    if (defaultSource != null) 'default_source': defaultSource,
    'capability_revision': capabilityRevision,
    'source': source,
    if (observedAt != null)
      'observed_at': observedAt!.toUtc().toIso8601String(),
  };

  factory ThinkingControlDescriptor.fromMap(Map<String, dynamic> map) {
    final status =
        ThinkingCapabilityStatus.tryParse(map['status'] as String?) ??
        ThinkingCapabilityStatus.unknown;
    return ThinkingControlDescriptor(
      status: status,
      kind: ThinkingControlKind.tryParse(map['kind'] as String?),
      options: (map['options'] as List<dynamic>? ?? [])
          .map(
            (entry) =>
                ThinkingControlOption.fromMap(entry as Map<String, dynamic>),
          )
          .toList(growable: false),
      defaultOptionId: map['default_option_id'] as String?,
      defaultSource: map['default_source'] as String?,
      capabilityRevision: map['capability_revision'] as String? ?? 'unknown',
      source: map['source'] as String? ?? 'unknown',
      observedAt: _parseUtcDate(map['observed_at']),
    );
  }

  static ThinkingControlDescriptor unknown({
    String capabilityRevision = 'unknown',
    String source = 'unknown',
    DateTime? observedAt,
  }) {
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.unknown,
      capabilityRevision: capabilityRevision,
      source: source,
      observedAt: observedAt,
    );
  }

  static ThinkingControlDescriptor unsupported({
    String capabilityRevision = 'unsupported',
    String source = 'profile',
    DateTime? observedAt,
  }) {
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.unsupported,
      capabilityRevision: capabilityRevision,
      source: source,
      observedAt: observedAt,
    );
  }

  ThinkingControlDescriptor copyWith({
    ThinkingCapabilityStatus? status,
    ThinkingControlKind? kind,
    List<ThinkingControlOption>? options,
    String? defaultOptionId,
    String? defaultSource,
    String? capabilityRevision,
    String? source,
    DateTime? observedAt,
  }) {
    return ThinkingControlDescriptor(
      status: status ?? this.status,
      kind: kind ?? this.kind,
      options: options ?? this.options,
      defaultOptionId: defaultOptionId ?? this.defaultOptionId,
      defaultSource: defaultSource ?? this.defaultSource,
      capabilityRevision: capabilityRevision ?? this.capabilityRevision,
      source: source ?? this.source,
      observedAt: observedAt ?? this.observedAt,
    );
  }
}

DateTime? _parseUtcDate(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed : parsed.toUtc();
}
