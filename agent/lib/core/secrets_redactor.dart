/// Central secrets redactor for runtime notice messages and logs (Plan 30
/// §3.25, §6; hermes research §4.3).
///
/// Provider error bodies and exception strings can leak API keys, bearer
/// tokens, `x-api-key` headers, and authorization fragments into the single
/// `message` field the agent builds for clients and into daemon logs. This
/// redactor is the single owner of secret scrubbing so neither
/// [RuntimeRecoveryService] nor [AgentRunner] re-implement ad-hoc masking.
///
/// It is intentionally conservative: when in doubt it redacts a span rather
/// than leaks it. It never re-interprets the *meaning* of a provider message
/// — it only strips secret-shaped substrings.
class SecretsRedactor {
  const SecretsRedactor();

  // Pre-compiled patterns. Built once.
  static final RegExp _keyPrefix = RegExp(
    r'\b(sk|nvapi|pk|rk|cr)-[A-Za-z0-9_\-]{12,}\b',
  );
  static final RegExp _authHeader = RegExp(
    r'(authorization|x-api-key|x-amz-security-token)\s*[:=]\s*[A-Za-z0-9_\-\.=:]+',
    caseSensitive: false,
  );
  static final RegExp _bearer = RegExp(
    r'\bbearer\s+[A-Za-z0-9_\-\.=:]+',
    caseSensitive: false,
  );
  static final RegExp _assignment = RegExp(
    r'\b(api[_-]?key|apikey|secret|token|password|access[_-]?token|refresh[_-]?token)\b\s*[:=]\s*[A-Za-z0-9_\-\.=:/+]{8,}',
    caseSensitive: false,
  );
  static final RegExp _jsonField = RegExp(
    r'"(api[_-]?key|apikey|secret|token|password|access[_-]?token|refresh[_-]?token|authorization)"\s*:\s*"?[^",}]{4,}"?',
    caseSensitive: false,
  );
  static final RegExp _sensitiveFieldName = RegExp(
    r'^(authorization|x-api-key|x-amz-security-token|api[_-]?key|apikey|secret|secrets|token|password|access[_-]?token|refresh[_-]?token)$',
    caseSensitive: false,
  );

  /// Redacts secret-shaped substrings from [input] and returns the scrubbed
  /// text. Returns an empty string unchanged.
  ///
  /// Recognized patterns:
  /// - `sk-…`, `nvapi-…`, and similar `prefix-…` long-lived API keys.
  /// - `Bearer <token>` authorization headers.
  /// - `x-api-key: <value>` and `api_key`/`apikey` assignments.
  /// - `Authorization: <scheme> <token>` headers.
  /// - JSON credential fields (`"api_key":"…"`).
  String redact(String input) {
    if (input.isEmpty) return input;
    var out = input;
    out = out.replaceAll(_bearer, 'Bearer ***');
    out = out.replaceAllMapped(_keyPrefix, (m) => '${m[1]}-***');
    out = out.replaceAllMapped(_authHeader, (m) => '${m[1]}: ***');
    out = out.replaceAllMapped(_assignment, (m) => '${m[1]}: ***');
    out = out.replaceAllMapped(_jsonField, (m) => '"${m[1]}": "***"');
    return out;
  }

  /// Recursively redacts secret-shaped substrings from JSON-compatible values.
  ///
  /// This keeps the original structure intact so persisted runtime payloads and
  /// continuation metadata remain debuggable without leaking secrets.
  dynamic redactValue(dynamic value) {
    if (value == null) return null;
    if (value is String) return redact(value);
    if (value is Map) {
      return Map<String, dynamic>.fromEntries(
        value.entries.map((entry) {
          final key = entry.key.toString();
          final nextValue = _sensitiveFieldName.hasMatch(key)
              ? '***'
              : redactValue(entry.value);
          return MapEntry(key, nextValue);
        }),
      );
    }
    if (value is Iterable) {
      return value.map(redactValue).toList(growable: false);
    }
    return value;
  }

  Map<String, dynamic> redactMap(Map input) =>
      Map<String, dynamic>.from(redactValue(input) as Map);

  /// Formats [value] for log interpolation without echoing secret fields.
  String redactForLog(Object? value) {
    final redacted = redactValue(value);
    return redacted == null ? 'null' : redacted.toString();
  }
}
