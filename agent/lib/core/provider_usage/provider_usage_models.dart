/// Unified models for provider account usage limits (Task 55 §3.2).
///
/// These models are transport-neutral and JSON-safe. They cross persistence
/// and protocol boundaries without ever carrying a raw provider payload,
/// credential, or account id. The daemon owns the snapshot; the client renders
library;

//
//  ─── Model rules (Task 55 §3.2) ──────────────────────────────────────
//  • Supported v1 window types: session | weekly | monthly.
//  • No placeholder windows are ever synthesised.
//  • Percentages are clamped to [0, 100]; when only one of used/remaining is
//    known, the other is derived.
//  • NaN / Infinity / non-numeric values never cross the protocol.
//  • `reset_at` is an explicit UTC timestamp; `fetched_at` is required.
//  • `available_resets` is a non-negative int; 0 hides the Reset button.
//  • `reset_credits` is an optional display-safe list of available credits
//    with UTC `expires_at`/`granted_at`; no provider titles or ids.
//  • `extra_details` carries display-safe text only — never raw payload.
//  • `unavailable_reason` is a typed safe reason; it never changes instance
//    readiness.

/// Window type supported in v1 (Task 55 §3.2).
class ProviderUsageWindowType {
  static const session = 'session';
  static const weekly = 'weekly';
  static const monthly = 'monthly';

  static const _known = {session, weekly, monthly};

  /// Returns true for the three v1 window types; false otherwise.
  static bool isKnown(String? value) => _known.contains(value);

  /// Human-readable label for display.
  static String label(String type) {
    switch (type) {
      case session:
        return 'Session';
      case weekly:
        return 'Weekly';
      case monthly:
        return 'Monthly';
      default:
        return type;
    }
  }

  ProviderUsageWindowType._();
}

/// Typed status for a usage fetch outcome (Task 55 §3.4).
class ProviderUsageResultStatus {
  /// Snapshot with windows/details available.
  static const available = 'available';

  /// Instance has no usage adapter (e.g. API-key-only provider without a usage
  /// endpoint). The UI shows no `Usage & limits` section — no error.
  static const unsupported = 'unsupported';

  /// Adapter exists but the usage endpoint is temporarily unreachable or
  /// returned an unexpected response. The section shows a retry affordance.
  static const unavailable = 'unavailable';

  /// Credential resolution failed (expired, missing, relogin required).
  static const authRequired = 'auth_required';

  /// Unexpected failure that does not fit the above.
  static const failed = 'failed';

  static const _known = {
    available,
    unsupported,
    unavailable,
    authRequired,
    failed,
  };

  static bool isKnown(String? value) => _known.contains(value);

  ProviderUsageResultStatus._();
}

/// One usage window inside a [ProviderUsageSnapshot] (Task 55 §3.2).
///
/// Either [usedPercent] or [remainingPercent] (or both) must be non-null for a
/// meaningful window. When only one is present, the other is derived and
/// clamped to [0, 100].
class ProviderUsageWindow {
  /// One of [ProviderUsageWindowType] values.
  final String type;

  /// Human-readable label (e.g. `Session`, `Weekly`). Defaults to the type's
  /// canonical label when not supplied by the adapter.
  final String label;

  /// Percentage of the limit already used, clamped to [0, 100]. May be null
  /// when the provider returns no numeric value for this window.
  final double? usedPercent;

  /// Percentage remaining, clamped to [0, 100]. Derived from `100 − used` when
  /// only `used` is known, and vice-versa.
  final double? remainingPercent;

  /// Explicit UTC reset timestamp for this window, or null when unknown.
  final DateTime? resetAt;

  /// Optional display-safe detail string (e.g. `42 of 100 requests`).
  final String? detail;

  const ProviderUsageWindow({
    required this.type,
    required this.label,
    this.usedPercent,
    this.remainingPercent,
    this.resetAt,
    this.detail,
  });

  /// Whether at least one percentage is available.
  bool get hasPercent => usedPercent != null || remainingPercent != null;

  /// Whether this window is fully exhausted (used >= 100).
  bool get isExhausted =>
      usedPercent != null && usedPercent! >= 100.0 ||
      remainingPercent != null && remainingPercent! <= 0.0;

  Map<String, dynamic> toMap() => {
    'type': type,
    'label': label,
    if (usedPercent != null) 'used_percent': _round(usedPercent!),
    if (remainingPercent != null)
      'remaining_percent': _round(remainingPercent!),
    if (resetAt != null) 'reset_at': resetAt!.toUtc().toIso8601String(),
    if (detail != null) 'detail': detail,
  };

  factory ProviderUsageWindow.fromMap(Map<String, dynamic> map) {
    return ProviderUsageWindow(
      type: map['type'] as String,
      label:
          (map['label'] as String?) ??
          ProviderUsageWindowType.label(map['type'] as String),
      usedPercent: _parseClampedPercent(map['used_percent']),
      remainingPercent: _parseClampedPercent(map['remaining_percent']),
      resetAt: _parseUtcDate(map['reset_at']),
      detail: map['detail'] as String?,
    );
  }

  @override
  String toString() =>
      'ProviderUsageWindow(type=$type, used=${usedPercent ?? "?"}%, '
      'remaining=${remainingPercent ?? "?"}%, reset=$resetAt)';
}

/// One display-safe banked reset credit (Task 174).
///
/// Only timestamps cross the protocol. Provider titles, descriptions, profile
/// ids, and account identifiers stay in the adapter.
class ProviderUsageResetCredit {
  /// UTC instant when this credit expires, when the provider reports it.
  final DateTime? expiresAt;

  /// UTC instant when this credit was granted, when reported.
  final DateTime? grantedAt;

  const ProviderUsageResetCredit({this.expiresAt, this.grantedAt});

  Map<String, dynamic> toMap() => {
    if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    if (grantedAt != null) 'granted_at': grantedAt!.toUtc().toIso8601String(),
  };

  factory ProviderUsageResetCredit.fromMap(Map<String, dynamic> map) =>
      ProviderUsageResetCredit(
        expiresAt: _parseUtcDate(map['expires_at']),
        grantedAt: _parseUtcDate(map['granted_at']),
      );

  @override
  String toString() =>
      'ProviderUsageResetCredit(expires=$expiresAt, granted=$grantedAt)';
}

/// A unified usage snapshot for a single [ProviderInstance] (Task 55 §3.2).
class ProviderUsageSnapshot {
  /// Owning instance UUID.
  final String providerInstanceId;

  /// Template id (e.g. `openai-codex`).
  final String providerTemplateId;

  /// Adapter source label (e.g. `chatgpt_usage_api`).
  final String source;

  /// Required UTC timestamp marking when the daemon fetched this snapshot.
  final DateTime fetchedAt;

  /// Optional plan name (e.g. `Plus`).
  final String? planName;

  /// Usage windows. Only the windows the provider actually returns.
  final List<ProviderUsageWindow> windows;

  /// Non-negative reset credit count. `0` hides the Reset button.
  final int availableResets;

  /// Available reset credits with display-safe expiry timestamps. Empty when
  /// the provider does not expose per-credit detail.
  final List<ProviderUsageResetCredit> resetCredits;

  /// Display-safe extra detail lines.
  final List<String> extraDetails;

  /// Typed reason when the snapshot is unavailable. Never affects readiness.
  final String? unavailableReason;

  const ProviderUsageSnapshot({
    required this.providerInstanceId,
    required this.providerTemplateId,
    required this.source,
    required this.fetchedAt,
    this.planName,
    this.windows = const [],
    this.availableResets = 0,
    this.resetCredits = const [],
    this.extraDetails = const [],
    this.unavailableReason,
  });

  Map<String, dynamic> toMap() => {
    'provider_instance_id': providerInstanceId,
    'provider_template_id': providerTemplateId,
    'source': source,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    if (planName != null) 'plan_name': planName,
    'windows': windows.map((w) => w.toMap()).toList(),
    'available_resets': availableResets,
    'reset_credits': resetCredits.map((c) => c.toMap()).toList(),
    'extra_details': extraDetails,
    if (unavailableReason != null) 'unavailable_reason': unavailableReason,
  };

  factory ProviderUsageSnapshot.fromMap(Map<String, dynamic> map) {
    return ProviderUsageSnapshot(
      providerInstanceId: map['provider_instance_id'] as String,
      providerTemplateId: map['provider_template_id'] as String,
      source: map['source'] as String,
      fetchedAt: _parseUtcDate(map['fetched_at']) ?? DateTime.now().toUtc(),
      planName: map['plan_name'] as String?,
      windows: (map['windows'] as List<dynamic>? ?? [])
          .map((w) => ProviderUsageWindow.fromMap(w as Map<String, dynamic>))
          .toList(),
      availableResets: (map['available_resets'] as num?)?.toInt() ?? 0,
      resetCredits: (map['reset_credits'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ProviderUsageResetCredit.fromMap)
          .toList(),
      extraDetails: (map['extra_details'] as List<dynamic>? ?? [])
          .map((d) => d.toString())
          .toList(),
      unavailableReason: map['unavailable_reason'] as String?,
    );
  }

  /// Whether at least one window, reset credit, or detail is present and no
  /// reason blocks it.
  bool get hasContent =>
      (windows.isNotEmpty ||
          resetCredits.isNotEmpty ||
          extraDetails.isNotEmpty) &&
      unavailableReason == null;

  @override
  String toString() =>
      'ProviderUsageSnapshot(instance=$providerInstanceId, '
      'template=$providerTemplateId, source=$source, '
      'windows=${windows.length}, resets=$availableResets, '
      'resetCredits=${resetCredits.length})';
}

/// Typed result of a `provider.usage.get` request (Task 55 §3.4).
class ProviderUsageResult {
  final String status;

  /// Snapshot when status is `available`, otherwise null.
  final ProviderUsageSnapshot? snapshot;

  /// Safe, display-ready message for non-available statuses.
  final String? message;

  /// Request correlation id echoed back to the client.
  String? requestId;

  /// Instance UUID the result belongs to.
  final String? providerInstanceId;

  ProviderUsageResult({
    required this.status,
    this.snapshot,
    this.message,
    this.requestId,
    this.providerInstanceId,
  });

  bool get isAvailable => status == ProviderUsageResultStatus.available;

  Map<String, dynamic> toMap() => {
    'status': status,
    if (providerInstanceId != null) 'provider_instance_id': providerInstanceId,
    if (requestId != null) 'request_id': requestId,
    if (snapshot != null) 'snapshot': snapshot!.toMap(),
    if (message != null) 'message': message,
  };

  // ── Convenience factories ────────────────────────────────────────────

  factory ProviderUsageResult.available(ProviderUsageSnapshot snapshot) =>
      ProviderUsageResult(
        status: ProviderUsageResultStatus.available,
        snapshot: snapshot,
        providerInstanceId: snapshot.providerInstanceId,
      );

  factory ProviderUsageResult.unsupported(String instanceId) =>
      ProviderUsageResult(
        status: ProviderUsageResultStatus.unsupported,
        providerInstanceId: instanceId,
      );

  factory ProviderUsageResult.unavailable(String instanceId, String message) =>
      ProviderUsageResult(
        status: ProviderUsageResultStatus.unavailable,
        providerInstanceId: instanceId,
        message: message,
      );

  factory ProviderUsageResult.authRequired(String instanceId, String message) =>
      ProviderUsageResult(
        status: ProviderUsageResultStatus.authRequired,
        providerInstanceId: instanceId,
        message: message,
      );

  factory ProviderUsageResult.failed(String instanceId, String message) =>
      ProviderUsageResult(
        status: ProviderUsageResultStatus.failed,
        providerInstanceId: instanceId,
        message: message,
      );
}

/// Typed reset outcomes for `provider.usage.reset`.
class ProviderUsageResetStatus {
  static const reset = 'reset';
  static const confirmationRequired = 'confirmation_required';
  static const nothingToReset = 'nothing_to_reset';
  static const noCredit = 'no_credit';
  static const alreadyRedeemed = 'already_redeemed';
  static const authRequired = 'auth_required';
  static const unsupported = 'unsupported';
  static const failed = 'failed';
  ProviderUsageResetStatus._();
}

/// Result of a reset request. A confirmation token is bound to the exact
/// preflight snapshot and expires quickly; clients must not reuse it later.
class ProviderUsageResetResult {
  final String status;
  final String providerInstanceId;
  final String? requestId;
  final String message;
  final int? availableResets;
  final ProviderUsageSnapshot? snapshot;
  final String? confirmationToken;
  final bool refreshFailed;

  const ProviderUsageResetResult({
    required this.status,
    required this.providerInstanceId,
    required this.message,
    this.requestId,
    this.availableResets,
    this.snapshot,
    this.confirmationToken,
    this.refreshFailed = false,
  });

  Map<String, dynamic> toMap() => {
    'status': status,
    'provider_instance_id': providerInstanceId,
    if (requestId != null) 'request_id': requestId,
    'message': message,
    if (availableResets != null) 'available_resets': availableResets,
    if (snapshot != null) 'snapshot': snapshot!.toMap(),
    if (confirmationToken != null) 'confirmation_token': confirmationToken,
    if (refreshFailed) 'refresh_failed': true,
  };
}

// ── Internal parsing helpers ────────────────────────────────────────────

/// Parses a numeric percent value, clamping to [0, 100]. Returns null for
/// non-numeric, NaN, Infinity, or out-of-range-after-clamp-impossible values.
double? _parseClampedPercent(Object? raw) {
  if (raw == null) return null;
  double? v;
  if (raw is num) {
    v = raw.toDouble();
  } else {
    final parsed = double.tryParse(raw.toString());
    v = parsed;
  }
  if (v == null) return null;
  if (v.isNaN || v.isInfinite) return null;
  // Clamp to [0, 100].
  if (v < 0) v = 0.0;
  if (v > 100) v = 100.0;
  return v;
}

DateTime? _parseUtcDate(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (raw.toDouble() * 1000).round(),
      isUtc: true,
    );
  }
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  var normalised = text;
  if (normalised.endsWith('Z')) {
    normalised = '${normalised.substring(0, normalised.length - 1)}+00:00';
  }
  final dt = DateTime.tryParse(normalised);
  if (dt == null) return null;
  return dt.isUtc ? dt : dt.toUtc();
}

double _round(double v) => (v * 100).roundToDouble() / 100;

/// Parses and clamps a raw percentage, deriving the complementary value when
/// only one side is known. Returns `(used, remaining)` where either may be
/// null if the input is not a valid finite number.
({double? used, double? remaining}) derivePercentPair({
  double? usedRaw,
  double? remainingRaw,
}) {
  final used = _sanitizePercent(usedRaw);
  final remaining = _sanitizePercent(remainingRaw);
  if (used == null && remaining != null) {
    return (used: 100.0 - remaining, remaining: remaining);
  }
  if (remaining == null && used != null) {
    return (used: used, remaining: 100.0 - used);
  }
  return (used: used, remaining: remaining);
}

double? _sanitizePercent(double? v) {
  if (v == null) return null;
  if (v.isNaN || v.isInfinite) return null;
  if (v < 0) return 0.0;
  if (v > 100) return 100.0;
  return v;
}
