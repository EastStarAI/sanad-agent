// Focused tests for the OpenCode Go usage adapter (Task 173).
//
// Covers the adapter contract:
//   • Capability requires an API key.
//   • The request uses the literal account endpoint, bearer credential, and a
//     bounded timeout.
//   • Rolling/Weekly/Monthly map to Session/Weekly/Monthly, percent is USED,
//     and reset timestamps normalize to UTC.
//   • Missing or non-numeric windows are omitted without placeholders.
//   • All-invalid payloads surface `unavailable`.
//   • Auth, HTTP, JSON, and malformed-shape failures map to typed exceptions.
//   • The registry advertises both supported templates.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_usage/opencode_go_usage_adapter.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_adapter.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_di.dart';

void main() {
  ProviderUsageContext context({
    String instanceId = 'instance-1',
    String templateId = 'opencode-go',
    String baseUrl = 'https://opencode.ai/zen/go/v1',
    SecretRecord? credential,
    required ProviderUsageHttpClient Function() httpClientFactory,
  }) {
    return ProviderUsageContext(
      instanceId: instanceId,
      templateId: templateId,
      baseUrl: baseUrl,
      credential: credential,
      httpClientFactory: httpClientFactory,
    );
  }

  SecretRecord apiKeyCredential(String instanceId, {String key = 'sk-test'}) =>
      SecretRecord(
        instanceId: instanceId,
        apiKey: key,
        authMethod: ProviderAuthMethod.apiKey,
      );

  group('OpenCodeGoUsageAdapter.canFetch', () {
    final adapter = OpenCodeGoUsageAdapter();

    test('true with a non-empty API key', () {
      expect(
        adapter.canFetch(
          context(
            credential: apiKeyCredential('instance-1'),
            httpClientFactory: _okFactory({}),
          ),
        ),
        isTrue,
      );
    });

    test('false with no credential', () {
      expect(
        adapter.canFetch(
          context(httpClientFactory: _okFactory({})),
        ),
        isFalse,
      );
    });

    test('false with an empty or whitespace API key', () {
      for (final key in ['', '   ']) {
        expect(
          adapter.canFetch(
            context(
              credential: apiKeyCredential('instance-1', key: key),
              httpClientFactory: _okFactory({}),
            ),
          ),
          isFalse,
        );
      }
    });

    test('false when the credential only carries an access token', () {
      expect(
        adapter.canFetch(
          context(
            credential: SecretRecord(
              instanceId: 'instance-1',
              accessToken: 'oauth-token',
              authMethod: ProviderAuthMethod.deviceCode,
            ),
            httpClientFactory: _okFactory({}),
          ),
        ),
        isFalse,
      );
    });
  });

  group('OpenCodeGoUsageAdapter.fetch', () {
    final adapter = OpenCodeGoUsageAdapter();

    test('maps rolling/weekly/monthly and treats percent as used', () async {
      final calls = <_RecordedCall>[];
      final snapshot = await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1'),
          httpClientFactory: _recordingFactory(calls, {
            'usage': {
              'rolling': {
                'status': 'ok',
                'percent': 3,
                'resetsAt': '2026-09-16T21:44:55.176Z',
              },
              'weekly': {
                'status': 'ok',
                'percent': 2,
                'resetsAt': '2026-09-21T00:00:00.176Z',
              },
              'monthly': {
                'status': 'ok',
                'percent': 2,
                'resetsAt': '2026-10-13T02:13:38.176Z',
              },
            },
          }),
        ),
      );

      expect(
        snapshot.windows.map((w) => (w.type, w.label, w.usedPercent)),
        [
          ('session', 'Session', 3.0),
          ('weekly', 'Weekly', 2.0),
          ('monthly', 'Monthly', 2.0),
        ],
      );
      expect(
        snapshot.windows.map((w) => w.remainingPercent),
        [97.0, 98.0, 98.0],
      );
      expect(
        snapshot.windows.first.resetAt,
        DateTime.utc(2026, 9, 16, 21, 44, 55, 176),
      );
      expect(snapshot.providerInstanceId, 'instance-1');
      expect(snapshot.providerTemplateId, 'opencode-go');
      expect(snapshot.source, 'opencode_go_usage_api');
      expect(snapshot.availableResets, 0);
      expect(snapshot.planName, isNull);
      expect(snapshot.extraDetails, isEmpty);
    });

    test('requests the literal account endpoint with a bearer key', () async {
      final calls = <_RecordedCall>[];
      await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1', key: 'sk-secret'),
          baseUrl: 'https://proxy.example.test/zen/go',
          httpClientFactory: _recordingFactory(calls, _validPayload()),
        ),
      );

      expect(calls, hasLength(1));
      expect(calls.single.url, OpenCodeGoUsageAdapter.usageUrl);
      expect(calls.single.headers?['Authorization'], 'Bearer sk-secret');
      expect(calls.single.headers?['Accept'], 'application/json');
      expect(calls.single.timeout, OpenCodeGoUsageAdapter.fetchTimeout);
    });

    test('keeps a zero percent as a real window', () async {
      final snapshot = await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1'),
          httpClientFactory: _okFactory({
            'usage': {
              'rolling': {'percent': 0, 'resetsAt': null},
            },
          }),
        ),
      );

      expect(snapshot.windows, hasLength(1));
      expect(snapshot.windows.single.type, 'session');
      expect(snapshot.windows.single.usedPercent, 0.0);
      expect(snapshot.windows.single.remainingPercent, 100.0);
      expect(snapshot.windows.single.resetAt, isNull);
    });

    test('omits missing windows without placeholders', () async {
      final snapshot = await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1'),
          httpClientFactory: _okFactory({
            'usage': {
              'weekly': {'percent': 42.5},
            },
          }),
        ),
      );

      expect(snapshot.windows.map((w) => w.type), ['weekly']);
      expect(snapshot.windows.single.usedPercent, 42.5);
      expect(snapshot.windows.single.remainingPercent, 57.5);
    });

    test('omits windows with a non-numeric percent', () async {
      final snapshot = await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1'),
          httpClientFactory: _rawFactory(
            200,
            jsonEncode({
              'usage': {
                'rolling': {'percent': 'not-a-number'},
                'weekly': {'percent': 5},
              },
            }),
          ),
        ),
      );

      expect(snapshot.windows.map((w) => w.type), ['weekly']);
    });

    test('ignores non-finite percent strings', () async {
      final snapshot = await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1'),
          httpClientFactory: _okFactory({
            'usage': {
              'rolling': {'percent': 'Infinity'},
              'monthly': {'percent': 4},
            },
          }),
        ),
      );

      expect(snapshot.windows.map((w) => w.type), ['monthly']);
    });

    test('clamps out-of-range percentages', () async {
      final snapshot = await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1'),
          httpClientFactory: _okFactory({
            'usage': {
              'rolling': {'percent': 150},
              'monthly': {'percent': -20},
            },
          }),
        ),
      );

      expect(snapshot.windows, hasLength(2));
      expect(snapshot.windows[0].usedPercent, 100.0);
      expect(snapshot.windows[0].remainingPercent, 0.0);
      expect(snapshot.windows[1].usedPercent, 0.0);
      expect(snapshot.windows[1].remainingPercent, 100.0);
    });

    test('surfaces unavailable when no window is usable', () async {
      await expectLater(
        adapter.fetch(
          context(
            credential: apiKeyCredential('instance-1'),
            httpClientFactory: _okFactory({
              'usage': {
                'rolling': {'percent': null},
                'weekly': <String, dynamic>{},
              },
            }),
          ),
        ),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
    });

    test('surfaces unavailable for a missing usage object', () async {
      await expectLater(
        adapter.fetch(
          context(
            credential: apiKeyCredential('instance-1'),
            httpClientFactory: _okFactory({'other': true}),
          ),
        ),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
    });

    test('surfaces unavailable for invalid JSON', () async {
      await expectLater(
        adapter.fetch(
          context(
            credential: apiKeyCredential('instance-1'),
            httpClientFactory: _rawFactory(200, 'not-json'),
          ),
        ),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
    });

    test('surfaces unavailable for a non-object JSON payload', () async {
      await expectLater(
        adapter.fetch(
          context(
            credential: apiKeyCredential('instance-1'),
            httpClientFactory: _rawFactory(200, '[]'),
          ),
        ),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
    });

    test('maps 401 and 403 to auth_required', () async {
      for (final status in [401, 403]) {
        await expectLater(
          adapter.fetch(
            context(
              credential: apiKeyCredential('instance-1'),
              httpClientFactory: _rawFactory(status, '{"error":"nope"}'),
            ),
          ),
          throwsA(isA<ProviderUsageAuthException>()),
          reason: 'HTTP $status',
        );
      }
    });

    test('maps other HTTP failures to unavailable', () async {
      for (final status in [400, 404, 429, 500, 503]) {
        await expectLater(
          adapter.fetch(
            context(
              credential: apiKeyCredential('instance-1'),
              httpClientFactory: _rawFactory(status, '{"error":"nope"}'),
            ),
          ),
          throwsA(isA<ProviderUsageUnavailableException>()),
          reason: 'HTTP $status',
        );
      }
    });

    test('throws auth_required without a credential', () async {
      await expectLater(
        adapter.fetch(
          context(httpClientFactory: _okFactory({})),
        ),
        throwsA(isA<ProviderUsageAuthException>()),
      );
    });

    test('closes the HTTP client on success and failure', () async {
      final successClient = _FakeClient(jsonPayload: _validPayload());
      await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1'),
          httpClientFactory: () => successClient,
        ),
      );
      expect(successClient.closed, isTrue);

      final failureClient = _FakeClient(rawBody: 'nope', status: 500);
      await expectLater(
        adapter.fetch(
          context(
            credential: apiKeyCredential('instance-1'),
            httpClientFactory: () => failureClient,
          ),
        ),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
      expect(failureClient.closed, isTrue);
    });

    test('never places the API key in the snapshot', () async {
      final snapshot = await adapter.fetch(
        context(
          credential: apiKeyCredential('instance-1', key: 'sk-hidden-token'),
          httpClientFactory: _okFactory(_validPayload()),
        ),
      );

      expect(snapshot.toString(), isNot(contains('sk-hidden-token')));
      expect(jsonEncode(snapshot.toMap()), isNot(contains('sk-hidden-token')));
    });
  });

  group('ProviderUsageRegistry wiring', () {
    test('advertises both supported templates', () {
      final registry = buildProviderUsageRegistry();
      expect(registry.supportsTemplate('openai-codex'), isTrue);
      expect(registry.supportsTemplate('opencode-go'), isTrue);
      expect(
        registry.adapterFor('opencode-go'),
        isA<OpenCodeGoUsageAdapter>(),
      );
      expect(registry.supportsTemplate('anthropic'), isFalse);
    });
  });
}

Map<String, dynamic> _validPayload() => {
  'usage': {
    'rolling': {'percent': 1, 'resetsAt': '2026-09-16T21:44:55.176Z'},
    'weekly': {'percent': 2, 'resetsAt': '2026-09-21T00:00:00.176Z'},
    'monthly': {'percent': 3, 'resetsAt': '2026-10-13T02:13:38.176Z'},
  },
};

// ── Fake HTTP client machinery ──────────────────────────────────────────

class _RecordedCall {
  final String url;
  final Map<String, String>? headers;
  final Duration? timeout;
  _RecordedCall(this.url, this.headers, this.timeout);
}

class _FakeClient implements ProviderUsageHttpClient {
  final Map<String, dynamic>? jsonPayload;
  final String? rawBody;
  final int status;
  final List<_RecordedCall>? calls;
  bool closed = false;

  _FakeClient({
    this.jsonPayload,
    this.rawBody,
    this.status = 200,
    this.calls,
  });

  @override
  Future<ProviderUsageHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    calls?.add(_RecordedCall(url.toString(), headers, timeout));
    return ProviderUsageHttpResponse(
      status,
      rawBody ?? jsonEncode(jsonPayload ?? {}),
    );
  }

  @override
  Future<ProviderUsageHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    calls?.add(_RecordedCall(url.toString(), headers, timeout));
    return ProviderUsageHttpResponse(status, rawBody ?? '{}');
  }

  @override
  void close() => closed = true;
}

ProviderUsageHttpClient Function() _okFactory(Map<String, dynamic> payload) =>
    () => _FakeClient(jsonPayload: payload);

ProviderUsageHttpClient Function() _rawFactory(int status, String body) =>
    () => _FakeClient(rawBody: body, status: status);

ProviderUsageHttpClient Function() _recordingFactory(
  List<_RecordedCall> calls,
  Map<String, dynamic> payload,
) =>
    () => _FakeClient(jsonPayload: payload, calls: calls);
