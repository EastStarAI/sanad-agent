// ChatGPT (`openai-codex`) usage adapter — read-only (Task 55 §3.3, Gate A).
//
// Mirrors the reference implementation's contract while adapting to Sanad's
// instance-first credential model and typed-result surface:
//
//   • Fetches `GET <base>/wham/usage` (or `<base>/api/codex/usage` for
//     non-ChatGPT-style base URLs) with `Authorization: Bearer <token>` and
//     `ChatGPT-Account-Id` when an account id is available from the credential.
//   • Reads `primary_window` and `secondary_window` defensively: a window is
//     emitted ONLY when it returns a numeric `used_percent`. No Session window
//     is synthesised when ChatGPT omits it (current behaviour: Weekly + Monthly
//     only). The mapping is fixed in code, not inferred from a `primary_window`
//     label, and is covered by fixtures for missing/combined windows.
//   • Parses `rate_limit_reset_credits.available_count` (and the optional
//     `applicable_available_count`) into `availableResets` / `applicableResets`
//     (non-negative ints; a zero count hides the Reset button).
//   • The per-credit list is NOT part of this payload: only the dedicated
//     `GET <base>/rate-limit-reset-credits` document carries `credits[]`, so a
//     non-zero count triggers one extra request. That request is optional: a
//     non-2xx, a timeout, or a non-JSON body degrades the card to the count
//     alone — never a throw, never a body in logs. Entries cross the protocol
//     as display-safe UTC `expires_at`/`granted_at` plus an opaque `credit_id`
//     used only to target that row's redemption; provider titles, descriptions,
//     and reset types never leave the adapter, and the id is never rendered or
//     logged.
//   • Ignores unknown fields for forward compatibility.
//   • Never logs the URL query, headers, raw response, token, or account id.
//   • Throws typed exceptions; messages are display-safe and never include the
//     response body.

import 'dart:convert';

import 'package:logging/logging.dart';

import 'provider_usage_adapter.dart';
import 'provider_usage_models.dart';
import 'provider_usage_parsing.dart';

/// Fixed mapping from ChatGPT `/wham/usage` window keys to Sanad window types.
///
/// ChatGPT currently returns `primary_window` (Session / 5h) and
/// `secondary_window` (Weekly). The mapping is **pinned by code**, not derived
/// from a `primary_window` label, and each window is emitted only when its
/// `used_percent` is present and numeric. See Task 55 §3.3 and §4.
class _CodexWindowSpec {
  final String payloadKey;
  final String sanadType;
  final String label;
  const _CodexWindowSpec(this.payloadKey, this.sanadType, this.label);
}

const _codexWindowSpecs = <_CodexWindowSpec>[
  _CodexWindowSpec(
    'primary_window',
    ProviderUsageWindowType.session,
    'Session',
  ),
  _CodexWindowSpec(
    'secondary_window',
    ProviderUsageWindowType.weekly,
    'Weekly',
  ),
];

/// Adapter that fetches ChatGPT account usage for `openai-codex` instances.
///
/// Read-only in Gate A: the reset endpoint is implemented in Gate D.
class ChatGptUsageAdapter implements ProviderUsageResetAdapter {
  /// Template id this adapter handles.
  static const adapterTemplateId = 'openai-codex';

  @override
  String get templateId => adapterTemplateId;

  @override
  String get sourceLabel => 'chatgpt_usage_api';

  final Logger _log = Logger('ChatGptUsageAdapter');

  /// HTTP timeout for the usage fetch. The reference impl uses 15s; Sanad keeps
  /// a single constant here to avoid scattered magic values (Task 55 §4).
  static const fetchTimeout = Duration(seconds: 15);

  /// Clock seam for expiry filtering and `fetched_at`.
  ///
  /// Production reads the wall clock in UTC. Tests pin it so reference fixtures
  /// that carry absolute instants keep asserting real parsing and ordering
  /// instead of silently rotting once those instants pass.
  final DateTime Function() _now;

  ChatGptUsageAdapter({DateTime Function()? now})
    : _now = now ?? _systemUtcNow;

  static DateTime _systemUtcNow() => DateTime.now().toUtc();

  @override
  bool canFetch(ProviderUsageContext context) {
    // ChatGPT usage requires an OAuth bearer token (access token). API-key-only
    // credentials cannot reach `/wham/usage`. We do NOT infer support from
    // `authMethod` in the client; this check lives in the daemon adapter.
    final cred = context.credential;
    if (cred == null) return false;
    final token = cred.accessToken ?? cred.apiKey;
    return token != null && token.trim().isNotEmpty;
  }

  @override
  Future<ProviderUsageSnapshot> fetch(ProviderUsageContext context) async {
    final cred = context.credential;
    final token = cred?.accessToken ?? cred?.apiKey;
    if (token == null || token.trim().isEmpty) {
      throw const ProviderUsageAuthException(
        'ChatGPT account sign-in required to view usage.',
      );
    }

    final usageUrl = _resolveUsageUrl(context.baseUrl);
    final headers = _buildHeaders(token, context.accountId);
    final client = context.httpClientFactory();
    try {
      final resp = await client.get(
        Uri.parse(usageUrl),
        headers: headers,
        timeout: fetchTimeout,
      );

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        // Credential rejected — surface auth_required, never leak the body.
        _log.warning('ChatGPT usage fetch rejected (HTTP ${resp.statusCode})');
        throw const ProviderUsageAuthException(
          'ChatGPT account sign-in required to view usage.',
        );
      }
      if (!resp.isSuccess) {
        _log.warning('ChatGPT usage fetch failed (HTTP ${resp.statusCode})');
        throw const ProviderUsageUnavailableException();
      }

      final dynamic decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        _log.warning('ChatGPT usage payload is not a JSON object');
        throw const ProviderUsageUnavailableException(
          'Usage response was malformed.',
        );
      }

      final resetCount = _parseResetCount(decoded['rate_limit_reset_credits']);
      final resetCredits = resetCount > 0
          ? await _fetchResetCredits(client, context, headers)
          : const <ProviderUsageResetCredit>[];
      return _mapPayload(decoded, context, resetCredits);
    } on ProviderUsageException {
      rethrow;
    } on FormatException {
      _log.warning('ChatGPT usage payload failed to parse');
      throw const ProviderUsageUnavailableException(
        'Usage response was malformed.',
      );
    } catch (e) {
      // Network/unknown error — message stays generic; details stay in logs.
      _log.warning('ChatGPT usage fetch error: $e');
      throw const ProviderUsageUnavailableException();
    } finally {
      client.close();
    }
  }

  /// Consumes at most one credit.
  ///
  /// ChatGPT accepts a targeted redemption: the body carries the opaque
  /// `credit_id` of the row the user pressed beside the daemon idempotency key.
  /// Without a credit id the request keeps its original shape and the provider
  /// spends its default credit.
  @override
  Future<ProviderUsageResetAdapterResult> reset(
    ProviderUsageContext context, {
    required String idempotencyKey,
    String? creditId,
  }) async {
    final cred = context.credential;
    final token = cred?.accessToken ?? cred?.apiKey;
    if (token == null || token.trim().isEmpty) {
      throw const ProviderUsageAuthException(
        'ChatGPT account sign-in required to reset limits.',
      );
    }
    final client = context.httpClientFactory();
    try {
      final response = await client.post(
        Uri.parse(_resolveConsumeUrl(context.baseUrl)),
        headers: {
          ..._buildHeaders(token, context.accountId),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'redeem_request_id': idempotencyKey,
          if (creditId != null && creditId.trim().isNotEmpty)
            'credit_id': creditId.trim(),
        }),
        timeout: fetchTimeout,
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const ProviderUsageAuthException(
          'ChatGPT account sign-in required to reset limits.',
        );
      }
      if (!response.isSuccess) {
        _log.warning('ChatGPT reset failed (HTTP ${response.statusCode})');
        throw const ProviderUsageUnavailableException(
          'Reset could not be completed. Please try again.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const ProviderUsageUnavailableException(
          'Reset response was malformed.',
        );
      }
      final code = decoded['code']?.toString().trim().toLowerCase();
      switch (code) {
        case ProviderUsageResetStatus.reset:
        case ProviderUsageResetStatus.nothingToReset:
        case ProviderUsageResetStatus.noCredit:
        case ProviderUsageResetStatus.alreadyRedeemed:
          return ProviderUsageResetAdapterResult(code!);
        default:
          throw const ProviderUsageUnavailableException(
            'Reset returned an unexpected result.',
          );
      }
    } on ProviderUsageException {
      rethrow;
    } on FormatException {
      throw const ProviderUsageUnavailableException(
        'Reset response was malformed.',
      );
    } catch (_) {
      throw const ProviderUsageUnavailableException(
        'Reset could not be completed. Please try again.',
      );
    } finally {
      client.close();
    }
  }

  // ── Wire helpers ─────────────────────────────────────────────────────

  /// Builds the request headers. The token/account id never enter logs.
  Map<String, String> _buildHeaders(String token, String? accountId) {
    final h = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'User-Agent': 'sanad-agent',
    };
    if (accountId != null && accountId.trim().isNotEmpty) {
      h['ChatGPT-Account-Id'] = accountId.trim();
    }
    return h;
  }

  /// Resolves the usage endpoint URL. Mirrors the reference split:
  /// Resolves the provider's ChatGPT-style API base (Task 55 §3.3):
  /// base URLs containing `/backend-api` use the ChatGPT `/wham/...` family;
  /// everything else uses `/api/codex/...`.
  String _resolveWhamBase(String baseUrl) {
    var normalised = baseUrl.trim();
    if (normalised.isEmpty) {
      normalised = 'https://chatgpt.com/backend-api/codex';
    }
    normalised = normalised.replaceAll(RegExp(r'/+$'), '');
    if (normalised.endsWith('/codex')) {
      normalised = normalised.substring(0, normalised.length - '/codex'.length);
    }
    return normalised.contains('/backend-api')
        ? '$normalised/wham'
        : '$normalised/api/codex';
  }

  String _resolveUsageUrl(String baseUrl) => '${_resolveWhamBase(baseUrl)}/usage';

  /// The list endpoint. `rate_limit_reset_credits` on `/usage` carries only the
  /// count; the per-credit detail (status, granted/expiry) lives here.
  String _resolveResetCreditsUrl(String baseUrl) =>
      '${_resolveWhamBase(baseUrl)}/rate-limit-reset-credits';

  String _resolveConsumeUrl(String baseUrl) =>
      '${_resolveWhamBase(baseUrl)}/rate-limit-reset-credits/consume';

  /// Reads the optional per-credit detail document.
  ///
  /// This call never fails the snapshot: reset-credit detail is decoration on a
  /// valid count, so any transport, status, or shape problem yields an empty
  /// list and the Client renders the count alone. The body never reaches a log.
  Future<List<ProviderUsageResetCredit>> _fetchResetCredits(
    ProviderUsageHttpClient client,
    ProviderUsageContext context,
    Map<String, String> headers,
  ) async {
    try {
      final resp = await client.get(
        Uri.parse(_resolveResetCreditsUrl(context.baseUrl)),
        headers: headers,
        timeout: fetchTimeout,
      );
      if (!resp.isSuccess) {
        _log.fine(
          'ChatGPT reset-credit detail unavailable (HTTP ${resp.statusCode})',
        );
        return const [];
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return const [];
      return _parseResetCredits(decoded);
    } catch (_) {
      _log.fine('ChatGPT reset-credit detail could not be read');
      return const [];
    }
  }

  // ── Defensive parsing ────────────────────────────────────────────────

  ProviderUsageSnapshot _mapPayload(
    Map<String, dynamic> payload,
    ProviderUsageContext context,
    List<ProviderUsageResetCredit> resetCredits,
  ) {
    final rateLimit =
        (payload['rate_limit'] as Map<String, dynamic>?) ?? const {};

    final windows = <ProviderUsageWindow>[];
    for (final spec in _codexWindowSpecs) {
      final win = _parseWindow(rateLimit[spec.payloadKey], spec);
      if (win != null) windows.add(win);
    }

    final planName = _titleCaseSlug(payload['plan_type']);
    final resetCounts = payload['rate_limit_reset_credits'];
    // The count stays sourced from this payload; the credit rows come from the
    // dedicated list document read by `_fetchResetCredits`.
    final availableResets = _parseResetCount(resetCounts);
    final applicableResets = _parseApplicableResetCount(resetCounts);
    final extraDetails = _parseExtraDetails(payload, availableResets);

    if (windows.isEmpty && extraDetails.isEmpty && planName == null) {
      // The payload returned nothing usable. Surface as unavailable rather than
      // an empty card; the client shows a retry affordance.
      throw const ProviderUsageUnavailableException(
        'No usage windows are currently available.',
      );
    }

    return ProviderUsageSnapshot(
      providerInstanceId: context.instanceId,
      providerTemplateId: context.templateId,
      source: sourceLabel,
      fetchedAt: _now().toUtc(),
      planName: planName,
      windows: windows,
      availableResets: availableResets,
      applicableResets: applicableResets,
      resetCredits: resetCredits,
      extraDetails: extraDetails,
    );
  }

  /// Parses one ChatGPT window object. Returns null when the window is absent
  /// or lacks a numeric `used_percent` — no placeholder is synthesised
  /// (Task 55 §3.2, §3.3).
  ProviderUsageWindow? _parseWindow(Object? raw, _CodexWindowSpec spec) {
    if (raw is! Map<String, dynamic>) return null;
    final usedRaw = raw['used_percent'];
    if (usedRaw == null) return null;
    final used = parseUsagePercent(usedRaw);
    if (used == null) return null;

    final pair = derivePercentPair(usedRaw: used);
    return ProviderUsageWindow(
      type: spec.sanadType,
      label: spec.label,
      usedPercent: pair.used,
      remainingPercent: pair.remaining,
      resetAt: parseUsageResetAt(raw['reset_at']),
      detail: _parseDetail(raw),
    );
  }

  String? _parseDetail(Map<String, dynamic> win) {
    // Emit a concise detail when both limit and remaining request counts are
    // present; otherwise omit (Task 55 §3.2 extra_details).
    final limit = win['limit'];
    final remaining = win['remaining'];
    if (limit is num && remaining is num) {
      return '${remaining.toInt()} of ${limit.toInt()} requests';
    }
    return null;
  }

  int _parseResetCount(Object? raw) {
    if (raw is! Map<String, dynamic>) return 0;
    final count = raw['available_count'];
    if (count is num) {
      final v = count.toInt();
      return v < 0 ? 0 : v;
    }
    return 0;
  }

  /// Parses the optional `applicable_available_count`.
  ///
  /// Returns null when the provider omits it or sends a non-numeric value, so
  /// "unknown" never reads as "not applicable".
  int? _parseApplicableResetCount(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final count = raw['applicable_available_count'];
    if (count is num) {
      final v = count.toInt();
      return v < 0 ? 0 : v;
    }
    return null;
  }

  /// Parses the dedicated `rate-limit-reset-credits` document.
  ///
  /// The per-credit list is not part of `/usage`: that payload carries only
  /// `available_count` (and sometimes `applicable_available_count`). Each entry
  /// here carries `status`, `granted_at`, `expires_at`, and an opaque `id` the
  /// adapter keeps only for targeted redemption. Provider `title`,
  /// `description`, and `reset_type` are dropped: they are provider copy, and
  /// the protocol never carries them.
  ///
  /// Only credits that are available and carry a valid, not-yet-passed expiry
  /// cross the protocol: an expired credit cannot be spent, so carrying it would
  /// offer an action that must fail. The list is sorted by earliest expiry so the
  /// Client can render the most urgent credit first.
  List<ProviderUsageResetCredit> _parseResetCredits(Object? raw) {
    if (raw is! Map<String, dynamic>) return const [];
    final credits = raw['credits'];
    if (credits is! List) return const [];

    final now = _now().toUtc();
    final parsed = <ProviderUsageResetCredit>[];
    for (final item in credits) {
      if (item is! Map<String, dynamic>) continue;
      final status = item['status']?.toString().trim().toLowerCase();
      if (status != null && status.isNotEmpty && status != 'available') {
        continue;
      }
      final expiresAt = parseUsageResetAt(item['expires_at']);
      if (expiresAt == null) continue;
      // `status` can still read `available` for a credit the account has
      // already let expire, so the timestamp is the authority.
      if (!expiresAt.isAfter(now)) continue;
      final rawId = item['id']?.toString().trim();
      parsed.add(
        ProviderUsageResetCredit(
          expiresAt: expiresAt,
          grantedAt: parseUsageResetAt(item['granted_at']),
          creditId: rawId == null || rawId.isEmpty || rawId.length > 256
              ? null
              : rawId,
        ),
      );
    }
    parsed.sort((a, b) => a.expiresAt!.compareTo(b.expiresAt!));
    return parsed;
  }

  List<String> _parseExtraDetails(Map<String, dynamic> payload, int resets) {
    final details = <String>[];
    // Banked resets hint is surfaced as extra_details when > 0. Reset UX
    // (button, confirmation) is added in Gate D; Gate A only surfaces the count
    // via `availableResets`, which the UI hides when 0.
    // (No textual hint here — the count is structured data on the snapshot.)

    final credits = payload['credits'];
    if (credits is Map<String, dynamic>) {
      if (credits['has_credits'] == true) {
        final balance = credits['balance'];
        if (balance is num && !balance.isNaN && !balance.isInfinite) {
          details.add('Credits balance: \$${balance.toStringAsFixed(2)}');
        } else if (credits['unlimited'] == true) {
          details.add('Credits balance: unlimited');
        }
      }
    }
    return details;
  }

  String? _titleCaseSlug(Object? raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;
    // e.g. "plus" → "Plus", "pro-lambda" → "Pro Lambda".
    final parts = text
        .replaceAll('_', '-')
        .split('-')
        .where((p) => p.isNotEmpty)
        .map((p) => '${p[0].toUpperCase()}${p.substring(1).toLowerCase()}');
    final out = parts.join(' ');
    return out.isEmpty ? null : out;
  }
}

/// Whether a given template id is the ChatGPT/Codex template. Kept here so the
/// daemon wiring (Gate B) can route to this adapter without importing the full
/// provider registry. Aliases mirror [ProviderRegistry]'s `openai-codex` entry.
bool isChatGptTemplate(String templateId) =>
    templateId == ChatGptUsageAdapter.adapterTemplateId ||
    templateId == 'codex' ||
    templateId == 'chatgpt-subscription';
