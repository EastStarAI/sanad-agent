// Focused tests for the ChatGPT usage adapter (Task 55 Gate A).
//
// Covers the Task 55 §3.3 contract and the Gate A exit criteria:
//   • Fetching a specific instance snapshot without leaking credentials.
//   • Missing Session window does NOT create a placeholder and does not fail
//     the rest of the snapshot (Weekly/Monthly only).
//   • Weekly/Monthly present without Session, alone or combined.
//   • Malformed/partial payload, non-numeric percents, and unknown extra fields
//     are handled defensively.
//   • `used_percent` is treated as USED, not remaining.
//   • Banked reset credits surface as `availableResets`; 0 hides the button.
//   • Auth/network failures map to typed exceptions with safe messages.

import 'dart:convert';
import 'package:test/test.dart';
import 'package:sanad_agent/core/provider_usage/chatgpt_usage_adapter.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_adapter.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';

void main() {
  ProviderUsageContext context({
    required String instanceId,
    String templateId = 'openai-codex',
    String baseUrl = 'https://chatgpt.com/backend-api/codex',
    SecretRecord? credential,
    String? accountId,
    required ProviderUsageHttpClient Function() httpClientFactory,
  }) {
    return ProviderUsageContext(
      instanceId: instanceId,
      templateId: templateId,
      baseUrl: baseUrl,
      credential: credential,
      accountId: accountId,
      httpClientFactory: httpClientFactory,
    );
  }

  SecretRecord oauthCred(String instanceId, {String? accessToken}) =>
      SecretRecord(
        instanceId: instanceId,
        accessToken: accessToken ?? 'token-abc',
        refreshToken: 'refresh',
        authMethod: ProviderAuthMethod.deviceCode,
      );

  group('ChatGptUsageAdapter.canFetch', () {
    final adapter = ChatGptUsageAdapter();

    test('true with an OAuth access token', () {
      final ctx = context(
        instanceId: 'i1',
        credential: oauthCred('i1'),
        httpClientFactory: _okFactory({}),
      );
      expect(adapter.canFetch(ctx), isTrue);
    });

    test('false with no credential', () {
      final ctx = context(
        instanceId: 'i2',
        credential: null,
        httpClientFactory: _okFactory({}),
      );
      expect(adapter.canFetch(ctx), isFalse);
    });

    test('false with an empty token', () {
      final ctx = context(
        instanceId: 'i3',
        credential: SecretRecord(
          instanceId: 'i3',
          accessToken: '',
          authMethod: ProviderAuthMethod.deviceCode,
        ),
        httpClientFactory: _okFactory({}),
      );
      expect(adapter.canFetch(ctx), isFalse);
    });
  });

  group('ChatGptUsageAdapter.fetch', () {
    final adapter = ChatGptUsageAdapter();

    test(
      'maps primary+secondary to Session+Weekly and treats percent as used',
      () async {
        final payload = {
          'plan_type': 'plus',
          'rate_limit': {
            'primary_window': {'used_percent': 21, 'reset_at': 1779846359},
            'secondary_window': {'used_percent': 4, 'reset_at': 1780230796},
          },
          'rate_limit_reset_credits': {'available_count': 2},
          'credits': {'has_credits': false},
        };
        final calls = <_RecordedCall>[];
        final ctx = context(
          instanceId: 'inst-a',
          credential: oauthCred('inst-a', accessToken: 'tok-a'),
          httpClientFactory: _recordingFactory(calls, payload),
        );
        final snap = await adapter.fetch(ctx);

        expect(snap.providerInstanceId, 'inst-a');
        expect(snap.providerTemplateId, 'openai-codex');
        expect(snap.source, 'chatgpt_usage_api');
        expect(snap.planName, 'Plus');
        expect(snap.windows.map((w) => w.type).toList(), ['session', 'weekly']);
        // used_percent is USED (Task 55 §3.3): 21% used → 79% remaining.
        expect(snap.windows[0].usedPercent, 21);
        expect(snap.windows[0].remainingPercent, 79);
        expect(snap.windows[1].usedPercent, 4);
        expect(snap.windows[1].remainingPercent, 96);
        expect(snap.availableResets, 2);
        expect(snap.fetchedAt.isUtc, isTrue);
        expect(snap.windows[0].resetAt?.isUtc, isTrue);

        // The recorded HTTP call carries Authorization but never a leaked
        // account id when none was supplied.
        expect(calls.single.headers?['Authorization'], 'Bearer tok-a');
        expect(
          calls.single.headers?.containsKey('ChatGPT-Account-Id'),
          isFalse,
        );
        expect(calls.single.url, 'https://chatgpt.com/backend-api/wham/usage');
      },
    );

    test('adds ChatGPT-Account-Id header when accountId is present', () async {
      final payload = {
        'rate_limit': {
          'primary_window': {'used_percent': 10},
        },
      };
      final calls = <_RecordedCall>[];
      final ctx = context(
        instanceId: 'inst-b',
        credential: oauthCred('inst-b'),
        accountId: 'acct-123',
        httpClientFactory: _recordingFactory(calls, payload),
      );
      await adapter.fetch(ctx);
      expect(calls.single.headers?['ChatGPT-Account-Id'], 'acct-123');
    });

    test('Weekly/Monthly only — no Session window, no placeholder', () async {
      // Current ChatGPT behaviour: primary_window (Session) may be absent;
      // only weekly + monthly present. No placeholder session is synthesised.
      final payload = {
        'plan_type': 'plus',
        'rate_limit': {
          'secondary_window': {'used_percent': 50, 'reset_at': 1780230796},
        },
        'credits': {'has_credits': false},
      };
      final ctx = context(
        instanceId: 'inst-c',
        credential: oauthCred('inst-c'),
        httpClientFactory: _okFactory(payload),
      );
      final snap = await adapter.fetch(ctx);

      expect(snap.windows.single.type, 'weekly');
      expect(snap.windows.single.usedPercent, 50);
      expect(snap.windows.single.remainingPercent, 50);
      // No session placeholder.
      expect(snap.windows.where((w) => w.type == 'session'), isEmpty);
    });

    test('single Session window — Weekly absent', () async {
      final payload = {
        'rate_limit': {
          'primary_window': {'used_percent': 80},
        },
      };
      final ctx = context(
        instanceId: 'inst-d',
        credential: oauthCred('inst-d'),
        httpClientFactory: _okFactory(payload),
      );
      final snap = await adapter.fetch(ctx);
      expect(snap.windows.single.type, 'session');
      expect(snap.windows.single.usedPercent, 80);
      expect(snap.windows.single.remainingPercent, 20);
    });

    test('no windows at all and no usable data → unavailable', () async {
      final payload = <String, dynamic>{};
      final ctx = context(
        instanceId: 'inst-e',
        credential: oauthCred('inst-e'),
        httpClientFactory: _okFactory(payload),
      );
      await expectLater(
        adapter.fetch(ctx),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
    });

    test('malformed JSON body → unavailable, no raw body in message', () async {
      final ctx = context(
        instanceId: 'inst-f',
        credential: oauthCred('inst-f'),
        httpClientFactory: _rawFactory(200, 'not-json'),
      );
      await expectLater(
        adapter.fetch(ctx),
        throwsA(
          allOf(
            isA<ProviderUsageUnavailableException>(),
            predicate<ProviderUsageUnavailableException>(
              (e) => !e.message.contains('not-json'),
              'no raw body leak',
            ),
          ),
        ),
      );
    });

    test('non-object JSON (array) → unavailable', () async {
      final ctx = context(
        instanceId: 'inst-g',
        credential: oauthCred('inst-g'),
        httpClientFactory: _rawFactory(200, '[1,2,3]'),
      );
      await expectLater(
        adapter.fetch(ctx),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
    });

    test('non-numeric used_percent drops the window, keeps the rest', () async {
      final payload = {
        'plan_type': 'plus',
        'rate_limit': {
          'primary_window': {'used_percent': 'high', 'reset_at': 1780230796},
          'secondary_window': {'used_percent': 30},
        },
      };
      final ctx = context(
        instanceId: 'inst-h',
        credential: oauthCred('inst-h'),
        httpClientFactory: _okFactory(payload),
      );
      final snap = await adapter.fetch(ctx);
      // primary dropped (non-numeric), secondary kept.
      expect(snap.windows.single.type, 'weekly');
      expect(snap.planName, 'Plus');
    });

    test(
      'NaN/Infinity used_percent in body → unavailable (Dart JSON rejects NaN)',
      () async {
        // Dart's jsonDecode rejects bare NaN/Infinity (unlike Python's
        // json.loads). So a NaN in the wire body fails at decode time and the
        // adapter surfaces `unavailable` — NaN can never reach the window parser.
        final ctx = context(
          instanceId: 'inst-i',
          credential: oauthCred('inst-i'),
          httpClientFactory: _rawFactory(
            200,
            '{"rate_limit":{"primary_window":{"used_percent":NaN},'
            '"secondary_window":{"used_percent":50}}}',
          ),
        );
        await expectLater(
          adapter.fetch(ctx),
          throwsA(isA<ProviderUsageUnavailableException>()),
        );
      },
    );

    test('unknown extra fields are ignored (forward compatibility)', () async {
      final payload = {
        'plan_type': 'plus',
        'rate_limit': {
          'primary_window': {
            'used_percent': 10,
            'unknown_blob': {'x': 1},
          },
        },
        'unknown_top_level': {'foo': 'bar'},
      };
      final ctx = context(
        instanceId: 'inst-j',
        credential: oauthCred('inst-j'),
        httpClientFactory: _okFactory(payload),
      );
      final snap = await adapter.fetch(ctx);
      expect(snap.windows.single.type, 'session');
      // The unknown blob never reaches the snapshot.
      expect(jsonEncode(snap.toMap()).contains('unknown_blob'), isFalse);
      expect(jsonEncode(snap.toMap()).contains('foo'), isFalse);
    });

    test('used_percent clamped to [0, 100]', () async {
      final payload = {
        'rate_limit': {
          'primary_window': {'used_percent': 150},
          'secondary_window': {'used_percent': -5},
        },
      };
      final ctx = context(
        instanceId: 'inst-k',
        credential: oauthCred('inst-k'),
        httpClientFactory: _okFactory(payload),
      );
      final snap = await adapter.fetch(ctx);
      expect(
        snap.windows.firstWhere((w) => w.type == 'session').usedPercent,
        100,
      );
      expect(snap.windows.firstWhere((w) => w.type == 'weekly').usedPercent, 0);
    });

    test('HTTP 401 → auth exception, body never in message', () async {
      final ctx = context(
        instanceId: 'inst-l',
        credential: oauthCred('inst-l'),
        httpClientFactory: _rawFactory(
          401,
          '{"detail":"invalid token secret"}',
        ),
      );
      await expectLater(
        adapter.fetch(ctx),
        throwsA(
          allOf(
            isA<ProviderUsageAuthException>(),
            predicate<ProviderUsageAuthException>(
              (e) => !e.message.contains('secret'),
              'no body leak',
            ),
          ),
        ),
      );
    });

    test('HTTP 500 → unavailable', () async {
      final ctx = context(
        instanceId: 'inst-m',
        credential: oauthCred('inst-m'),
        httpClientFactory: _rawFactory(500, 'boom'),
      );
      await expectLater(
        adapter.fetch(ctx),
        throwsA(isA<ProviderUsageUnavailableException>()),
      );
    });

    test('missing credential → auth exception', () async {
      final ctx = context(
        instanceId: 'inst-n',
        credential: null,
        httpClientFactory: _okFactory({}),
      );
      await expectLater(
        adapter.fetch(ctx),
        throwsA(isA<ProviderUsageAuthException>()),
      );
    });

    test('non-/backend-api base URL uses /api/codex path', () async {
      final payload = {
        'rate_limit': {
          'primary_window': {'used_percent': 5},
        },
      };
      final calls = <_RecordedCall>[];
      final ctx = context(
        instanceId: 'inst-o',
        baseUrl: 'https://gateway.example.com/codex',
        credential: oauthCred('inst-o'),
        httpClientFactory: _recordingFactory(calls, payload),
      );
      await adapter.fetch(ctx);
      expect(calls.single.url, 'https://gateway.example.com/api/codex/usage');
    });

    test('availableResets is 0 when count missing or non-numeric', () async {
      final payload = {
        'rate_limit': {
          'primary_window': {'used_percent': 10},
        },
        // no rate_limit_reset_credits
      };
      final ctx = context(
        instanceId: 'inst-p',
        credential: oauthCred('inst-p'),
        httpClientFactory: _okFactory(payload),
      );
      final snap = await adapter.fetch(ctx);
      expect(snap.availableResets, 0);
      expect(snap.resetCredits, isEmpty);
    });

    test(
      'parses available reset credits with UTC expiry, sorted and sanitized',
      () async {
        final payload = {
          'rate_limit': {
            'primary_window': {'used_percent': 10},
          },
          'rate_limit_reset_credits': {
            'available_count': 3,
            'credits': [
              {
                'status': 'available',
                'title': 'Full reset (Weekly + 5 hr)',
                'description': 'provider-private',
                'profile_user_id': 'PROFILE-LEAK',
                'granted_at': '2026-11-01T10:00:00Z',
                'expires_at': '2026-11-20T10:00:00Z',
              },
              {'status': 'redeemed', 'expires_at': '2026-11-10T10:00:00Z'},
              {'status': 'available', 'expires_at': '2026-11-15T10:00:00Z'},
              {'status': 'available', 'expires_at': 'not-a-date'},
              {'status': 'available'},
            ],
          },
        };
        final ctx = context(
          instanceId: 'inst-credits',
          credential: oauthCred('inst-credits'),
          httpClientFactory: _okFactory(payload),
        );
        final snap = await adapter.fetch(ctx);

        expect(snap.availableResets, 3);
        expect(snap.resetCredits, hasLength(2));
        expect(snap.resetCredits.map((c) => c.expiresAt!.toIso8601String()), [
          '2026-11-15T10:00:00.000Z',
          '2026-11-20T10:00:00.000Z',
        ]);
        expect(
          snap.resetCredits.last.grantedAt?.toIso8601String(),
          '2026-11-01T10:00:00.000Z',
        );
        expect(snap.resetCredits.every((c) => c.expiresAt!.isUtc), isTrue);

        final mapText = snap.toMap().toString();
        expect(mapText, isNot(contains('PROFILE-LEAK')));
        expect(mapText, isNot(contains('Full reset')));
        expect(mapText, isNot(contains('provider-private')));
        expect(snap.toMap()['reset_credits'] as List, hasLength(2));
      },
    );

    test('snapshot JSON never contains token or account id', () async {
      final payload = {
        'rate_limit': {
          'primary_window': {'used_percent': 12},
        },
      };
      final ctx = context(
        instanceId: 'inst-q',
        credential: oauthCred('inst-q', accessToken: 'SUPERSECRET'),
        accountId: 'ACCT-LEAK',
        httpClientFactory: _okFactory(payload),
      );
      final snap = await adapter.fetch(ctx);
      final encoded = jsonEncode(snap.toMap());
      expect(encoded.contains('SUPERSECRET'), isFalse);
      expect(encoded.contains('ACCT-LEAK'), isFalse);
    });

    test('different instances do not share state', () async {
      final adapterInstance = ChatGptUsageAdapter();
      final payload1 = {
        'rate_limit': {
          'primary_window': {'used_percent': 1},
        },
      };
      final payload2 = {
        'rate_limit': {
          'primary_window': {'used_percent': 99},
        },
      };
      final snap1 = await adapterInstance.fetch(
        context(
          instanceId: 'inst-r1',
          credential: oauthCred('inst-r1'),
          httpClientFactory: _okFactory(payload1),
        ),
      );
      final snap2 = await adapterInstance.fetch(
        context(
          instanceId: 'inst-r2',
          credential: oauthCred('inst-r2'),
          httpClientFactory: _okFactory(payload2),
        ),
      );
      expect(snap1.providerInstanceId, 'inst-r1');
      expect(snap2.providerInstanceId, 'inst-r2');
      expect(snap1.windows.first.usedPercent, 1);
      expect(snap2.windows.first.usedPercent, 99);
    });
  });

  group('ChatGptUsageAdapter.reset', () {
    test('posts the daemon idempotency key to the consume endpoint', () async {
      final calls = <_RecordedCall>[];
      final adapter = ChatGptUsageAdapter();
      final ctx = context(
        instanceId: 'inst-reset',
        credential: oauthCred('inst-reset'),
        httpClientFactory: () => _FakeClient(
          rawBody: jsonEncode({'code': 'reset', 'windows_reset': 2}),
          calls: calls,
        ),
      );
      final result = await adapter.reset(ctx, idempotencyKey: 'stable-key');
      expect(result.status, 'reset');
      expect(
        calls.single.url,
        'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume',
      );
    });

    test(
      'maps provider nothing_to_reset without treating it as success',
      () async {
        final adapter = ChatGptUsageAdapter();
        final result = await adapter.reset(
          context(
            instanceId: 'inst-reset',
            credential: oauthCred('inst-reset'),
            httpClientFactory: () =>
                _FakeClient(rawBody: jsonEncode({'code': 'nothing_to_reset'})),
          ),
          idempotencyKey: 'stable-key',
        );
        expect(result.status, 'nothing_to_reset');
      },
    );
  });

  group('ProviderUsageRegistry', () {
    test('supportsTemplate reflects registered adapters only', () {
      final r = ProviderUsageRegistry();
      expect(r.supportsTemplate('openai-codex'), isFalse);
      r.register(ChatGptUsageAdapter());
      expect(r.supportsTemplate('openai-codex'), isTrue);
      expect(r.supportsTemplate('openai'), isFalse);
      expect(r.adapterFor('openai-codex'), isA<ChatGptUsageAdapter>());
    });

    test('register replaces an existing adapter for the same template', () {
      final r = ProviderUsageRegistry();
      r.register(ChatGptUsageAdapter());
      r.register(ChatGptUsageAdapter());
      expect(r.registeredTemplates.length, 1);
    });
  });

  group('isChatGptTemplate', () {
    test('matches template and aliases', () {
      expect(isChatGptTemplate('openai-codex'), isTrue);
      expect(isChatGptTemplate('codex'), isTrue);
      expect(isChatGptTemplate('chatgpt-subscription'), isTrue);
      expect(isChatGptTemplate('openai'), isFalse);
    });
  });
}

// ── Fake HTTP client machinery ──────────────────────────────────────────

class _RecordedCall {
  final String url;
  final Map<String, String>? headers;
  _RecordedCall(this.url, this.headers);
}

class _FakeClient implements ProviderUsageHttpClient {
  final Map<String, dynamic>? jsonPayload;
  final String? rawBody;
  final int status;
  final List<_RecordedCall>? calls;

  _FakeClient({this.jsonPayload, this.rawBody, this.status = 200, this.calls});

  @override
  Future<ProviderUsageHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    calls?.add(_RecordedCall(url.toString(), headers));
    final body = rawBody ?? jsonEncode(jsonPayload ?? {});
    return ProviderUsageHttpResponse(status, body);
  }

  @override
  Future<ProviderUsageHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    calls?.add(_RecordedCall(url.toString(), headers));
    return ProviderUsageHttpResponse(status, rawBody ?? '{}');
  }

  @override
  void close() {}
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
