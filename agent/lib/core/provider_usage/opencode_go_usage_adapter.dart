// OpenCode Go (`opencode-go`) account usage adapter — read-only (Task 173).
//
// OpenCode Go is an API-key subscription provider. The account usage endpoint
// is a literal account URL, not the instance's configured model base URL:
// model routing may move a request to another wire and rewrite the base path,
// while the account limits belong to the OpenCode account itself.
//
// Contract:
//   • `GET https://opencode.ai/zen/go/v1/usage` with the instance's API key.
//   • Payload: `{"usage": {"rolling"|"weekly"|"monthly": {"percent", "resetsAt"}}}`.
//   • `percent` is the USED percentage; the remaining share is derived.
//   • A window without a numeric percent is omitted; no placeholder is created.
//   • `resetsAt` is ISO-8601 and normalized to UTC; it may be absent.
//   • No usable window surfaces `unavailable`, never an empty card.
//   • OpenCode Go exposes no reset credits and no plan name in this payload.
//   • Credentials, headers, and response bodies never enter logs.

import 'dart:convert';

import 'package:logging/logging.dart';

import 'provider_usage_adapter.dart';
import 'provider_usage_models.dart';
import 'provider_usage_parsing.dart';

/// Fixed mapping from OpenCode Go payload keys to Sanad window types.
///
/// The provider's `rolling` window is its 5-hour allowance, which is the same
/// concept Sanad already models as `session`. The mapping is pinned in code and
/// each window is emitted only when it returns a numeric `percent`.
class _GoWindowSpec {
  final String payloadKey;
  final String sanadType;
  final String label;
  const _GoWindowSpec(this.payloadKey, this.sanadType, this.label);
}

const _goWindowSpecs = <_GoWindowSpec>[
  _GoWindowSpec(
    'rolling',
    ProviderUsageWindowType.session,
    'Session',
  ),
  _GoWindowSpec('weekly', ProviderUsageWindowType.weekly, 'Weekly'),
  _GoWindowSpec('monthly', ProviderUsageWindowType.monthly, 'Monthly'),
];

/// Adapter that fetches OpenCode Go account usage for `opencode-go` instances.
class OpenCodeGoUsageAdapter implements ProviderUsageAdapter {
  /// Template id this adapter handles.
  static const adapterTemplateId = 'opencode-go';

  /// Literal account-usage endpoint. Deliberately independent of the
  /// instance's configured model base URL.
  static const usageUrl = 'https://opencode.ai/zen/go/v1/usage';

  /// Account usage is a small account-scoped request; a short deadline keeps a
  /// slow endpoint from holding the disclosure open.
  static const fetchTimeout = Duration(seconds: 10);

  @override
  String get templateId => adapterTemplateId;

  @override
  String get sourceLabel => 'opencode_go_usage_api';

  final Logger _log = Logger('OpenCodeGoUsageAdapter');

  @override
  bool canFetch(ProviderUsageContext context) {
    final key = context.credential?.apiKey;
    return key != null && key.trim().isNotEmpty;
  }

  @override
  Future<ProviderUsageSnapshot> fetch(ProviderUsageContext context) async {
    final token = context.credential?.apiKey?.trim();
    if (token == null || token.isEmpty) {
      throw const ProviderUsageAuthException(
        'OpenCode Go API key is required to view usage.',
      );
    }

    final client = context.httpClientFactory();
    try {
      final resp = await client.get(
        Uri.parse(usageUrl),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
          'User-Agent': 'sanad-agent',
        },
        timeout: fetchTimeout,
      );

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        // The key was rejected; surface auth_required without leaking the body.
        _log.warning('OpenCode Go usage fetch rejected (HTTP ${resp.statusCode})');
        throw const ProviderUsageAuthException(
          'OpenCode Go API key is required to view usage.',
        );
      }
      if (!resp.isSuccess) {
        _log.warning('OpenCode Go usage fetch failed (HTTP ${resp.statusCode})');
        throw const ProviderUsageUnavailableException();
      }

      Object? decoded;
      try {
        decoded = jsonDecode(resp.body);
      } catch (_) {
        _log.warning('OpenCode Go usage payload is not valid JSON');
        throw const ProviderUsageUnavailableException(
          'Usage response was malformed.',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        _log.warning('OpenCode Go usage payload is not a JSON object');
        throw const ProviderUsageUnavailableException(
          'Usage response was malformed.',
        );
      }

      return _mapPayload(decoded, context);
    } on ProviderUsageException {
      rethrow;
    } catch (error) {
      _log.warning('OpenCode Go usage fetch failed (${error.runtimeType})');
      throw const ProviderUsageUnavailableException();
    } finally {
      client.close();
    }
  }

  ProviderUsageSnapshot _mapPayload(
    Map<String, dynamic> payload,
    ProviderUsageContext context,
  ) {
    final usage = payload['usage'];
    if (usage is! Map) {
      throw const ProviderUsageUnavailableException(
        'Usage response was malformed.',
      );
    }

    final windows = <ProviderUsageWindow>[];
    for (final spec in _goWindowSpecs) {
      final raw = usage[spec.payloadKey];
      if (raw is! Map) continue;
      final used = parseUsagePercent(raw['percent']);
      if (used == null) continue;

      final pair = derivePercentPair(usedRaw: used);
      windows.add(
        ProviderUsageWindow(
          type: spec.sanadType,
          label: spec.label,
          usedPercent: pair.used,
          remainingPercent: pair.remaining,
          resetAt: parseUsageResetAt(raw['resetsAt']),
        ),
      );
    }

    if (windows.isEmpty) {
      // Nothing usable came back; surface a retry instead of an empty card.
      throw const ProviderUsageUnavailableException(
        'No usage windows are currently available.',
      );
    }

    return ProviderUsageSnapshot(
      providerInstanceId: context.instanceId,
      providerTemplateId: context.templateId,
      source: sourceLabel,
      fetchedAt: DateTime.now().toUtc(),
      windows: windows,
    );
  }
}
