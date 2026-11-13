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
///
/// Coverage is by shape, not by vendor list: a self-identifying key (a known
/// prefix), a name/value pair (`token=…`, `token: …`), a named CLI flag
/// (`--token abc123`), or a named JSON field. A credential with no name, no
/// recognizable prefix, and no assignment — a bare positional argument such as
/// `-p hunt4`, or a value that continues on the next line — cannot be told
/// apart from ordinary text, so it is not detected and must not be composed
/// into a low-trust surface in the first place.
class SecretsRedactor {
  const SecretsRedactor();

  // Pre-compiled patterns. Built once.
  static final RegExp _keyPrefix = RegExp(
    r'\b(sk|nvapi|pk|rk|cr)-[A-Za-z0-9_\-]{12,}\b',
  );

  /// AWS access key ids are self-identifying: a documented four-letter key-id
  /// prefix followed by upper-case alphanumerics (`AKIA…`, `ASIA…`, and the
  /// same shape for IAM roles, groups, and STS sessions).
  static final RegExp _awsKeyId = RegExp(
    r'\b(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|ASCA)[A-Z0-9]{16,}',
  );

  /// Source-host tokens keep a readable prefix and a long opaque body:
  /// GitHub's `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` families, its fine-grained
  /// `github_pat_` form, and GitLab's `glpat-`.
  static final RegExp _sourceHostToken = RegExp(
    r'\b(gh[pousr]_|github_pat_|glpat-)[A-Za-z0-9_\-]{16,}',
  );
  static final RegExp _authHeader = RegExp(
    r'(authorization|x-api-key|x-amz-security-token)\s*[:=]\s*[A-Za-z0-9_\-\.=:]+',
    caseSensitive: false,
  );
  static final RegExp _bearer = RegExp(
    r'\bbearer\s+[A-Za-z0-9_\-\.=:]+',
    caseSensitive: false,
  );

  /// A credential named and assigned in one expression: `api_key=VALUE`,
  /// `token: VALUE`, and the flag form `--password=VALUE` (the `\b` holds
  /// between the dash and the name).
  ///
  /// The value floor is four characters, not eight: a short flag password such
  /// as `--password=hunt4` is still a credential.
  static final RegExp _assignment = RegExp(
    r'\b(api[_-]?key|apikey|secret|client[_-]?secret|token|password|passwd|access[_-]?token|refresh[_-]?token|auth[_-]?token|private[_-]?key)\b\s*[:=]\s*[A-Za-z0-9_\-\.=:/+]{4,}',
    caseSensitive: false,
  );

  /// A named CLI flag whose value is the next word: `--token abc123`,
  /// `-password hunt4`. The flag name is diagnostic, the value is not.
  static final RegExp _flagSecret = RegExp(
    r'(?<![\w-])(--?(?:api[_-]?key|apikey|secret|client[_-]?secret|token|password|passwd|access[_-]?token|refresh[_-]?token|auth[_-]?token|private[_-]?key))(?:\s*=\s*|\s+)\S+',
    caseSensitive: false,
  );
  static final RegExp _jsonField = RegExp(
    r'"(api[_-]?key|apikey|secret|token|password|access[_-]?token|refresh[_-]?token|authorization)"\s*:\s*"?[^",}]{4,}"?',
    caseSensitive: false,
  );
  static final RegExp _sensitiveFieldName = RegExp(
    r'^(authorization|proxy-authorization|x-api-key|x-goog-api-key|x-amz-security-token|api[_-]?key|apikey|secret|secrets|token|password|access[_-]?token|refresh[_-]?token)$',
    caseSensitive: false,
  );

  /// Redacts secret-shaped substrings from [input] and returns the scrubbed
  /// text. Returns an empty string unchanged.
  ///
  /// Recognized patterns:
  /// - `sk-…`, `nvapi-…`, and similar `prefix-…` long-lived API keys.
  /// - AWS access key ids (`AKIA…`, `ASIA…`) and source-host tokens (`ghp_…`,
  ///   `github_pat_…`, `glpat-…`).
  /// - `Bearer <token>` authorization headers.
  /// - `x-api-key: <value>` and `api_key`/`apikey` assignments, including the
  ///   flag form `--password=hunt4`.
  /// - A named CLI flag with its value in the next word: `--token abc123`.
  /// - `Authorization: <scheme> <token>` headers.
  /// - JSON credential fields (`"api_key":"…"`).
  String redact(String input) {
    if (input.isEmpty) return input;
    var out = input;
    out = out.replaceAll(_bearer, 'Bearer ***');
    out = out.replaceAllMapped(_keyPrefix, (m) => '${m[1]}-***');
    out = out.replaceAllMapped(_awsKeyId, (m) => '${m[1]}***');
    out = out.replaceAllMapped(_sourceHostToken, (m) => '${m[1]}***');
    out = out.replaceAllMapped(_authHeader, (m) => '${m[1]}: ***');
    out = out.replaceAllMapped(_flagSecret, (m) => '${m[1]} ***');
    out = out.replaceAllMapped(_assignment, (m) => '${m[1]}: ***');
    out = out.replaceAllMapped(_jsonField, (m) => '"${m[1]}": "***"');
    return out;
  }

  /// Whether [key] names a credential-bearing field or header (for example
  /// `Authorization`, `x-api-key`, `api-key`, `api_key`, `token`).
  bool isSensitiveFieldName(String key) => _sensitiveFieldName.hasMatch(key);

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
