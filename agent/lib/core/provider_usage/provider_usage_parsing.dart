/// Shared defensive parsing for provider usage adapters.
///
/// Adapters translate provider payloads into the unified usage models; the
/// numeric and timestamp rules are identical across providers (clamp
/// percentages to `[0, 100]`, treat missing or non-finite values as absent, and
/// normalize reset timestamps to UTC). Keeping them here means a new adapter
/// cannot drift from the established normalization contract.
library;

/// Parses a numeric percentage and clamps it to `[0, 100]`.
///
/// Returns null for a missing value, a non-numeric value, `NaN`, or infinity.
/// Negative values become `0`; values above `100` become `100`.
double? parseUsagePercent(Object? raw) {
  if (raw == null) return null;
  final double? parsed;
  if (raw is num) {
    parsed = raw.toDouble();
  } else {
    parsed = double.tryParse(raw.toString().trim());
  }
  if (parsed == null || parsed.isNaN || parsed.isInfinite) return null;
  if (parsed < 0) return 0.0;
  if (parsed > 100) return 100.0;
  return parsed;
}

/// Parses a reset timestamp into UTC.
///
/// Accepts ISO-8601 text (including a trailing `Z`) or epoch seconds. Returns
/// null for a missing, empty, non-finite, or unparseable value.
DateTime? parseUsageResetAt(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    final value = raw.toDouble();
    if (value.isNaN || value.isInfinite) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
      isUtc: true,
    );
  }
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  var normalised = text;
  if (normalised.endsWith('Z')) {
    normalised = '${normalised.substring(0, normalised.length - 1)}+00:00';
  }
  return DateTime.tryParse(normalised)?.toUtc();
}
