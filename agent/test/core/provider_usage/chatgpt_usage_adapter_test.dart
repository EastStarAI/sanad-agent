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
import 'dart:io';
import 'dart:isolate';

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

  // The reference fixtures carry absolute instants, so an adapter reading the
  // real wall clock would eventually filter them out and rot the assertions.
  // Pinning "now" keeps the fixtures reference-faithful and the expectations
  // exact, whatever day CI runs on.
  final pinnedNow = DateTime.utc(2026, 11, 15, 12);
  ChatGptUsageAdapter pinnedClockAdapter() =>
      ChatGptUsageAdapter(now: () => pinnedNow);

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
    final adapter = pinnedClockAdapter();

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

        // The usage call carries Authorization but never a leaked account id
        // when none was supplied, and the optional detail call reuses the same
        // headers (it only adds a different path).
        expect(calls.first.headers?['Authorization'], 'Bearer tok-a');
        expect(
          calls.first.headers?.containsKey('ChatGPT-Account-Id'),
          isFalse,
        );
        expect(calls.first.url, 'https://chatgpt.com/backend-api/wham/usage');
        expect(calls.last.headers?['Authorization'], 'Bearer tok-a');
        expect(
          calls.last.url,
          'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits',
        );
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
      'the /usage payload alone keeps the count and yields no credit rows',
      () async {
        // Regression for the bug the live test found: the per-credit list is not
        // in this document, so a parser that looks for
        // `rate_limit_reset_credits.credits[]` here silently renders a
        // count-only card. The detail call below fails on purpose.
        final calls = <_RecordedCall>[];
        final ctx = context(
          instanceId: 'inst-usage-only',
          credential: oauthCred('inst-usage-only'),
          httpClientFactory: _routedFactory({
            '/usage': _Route.json(
              _fixture('test/fixtures/chatgpt_usage_reference_shape.json'),
            ),
            '/rate-limit-reset-credits': _Route.error(500),
          }, calls),
        );

        final snap = await adapter.fetch(ctx);

        expect(snap.availableResets, 2);
        expect(snap.applicableResets, 1);
        expect(snap.resetCredits, isEmpty);
        expect(calls.map((c) => c.url), [
          'https://chatgpt.com/backend-api/wham/usage',
          'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits',
        ]);
      },
    );

    test(
      'reads the dedicated detail document into sorted, sanitized credits',
      () async {
        final calls = <_RecordedCall>[];
        final ctx = context(
          instanceId: 'inst-credits',
          credential: oauthCred('inst-credits'),
          httpClientFactory: _routedFactory({
            '/usage': _Route.json(
              _fixture('test/fixtures/chatgpt_usage_reference_shape.json'),
            ),
            '/rate-limit-reset-credits': _Route.json(
              _fixture(
                'test/fixtures/chatgpt_rate_limit_reset_credits_reference_shape.json',
              ),
            ),
          }, calls),
        );

        final snap = await adapter.fetch(ctx);

        expect(calls, hasLength(2));
        expect(snap.availableResets, 2);
        expect(
          snap.resetCredits.map((c) => c.expiresAt!.toIso8601String()),
          ['2026-11-16T10:00:00.000Z', '2026-11-20T10:00:00.000Z'],
          reason: 'only available credits cross, earliest expiry first',
        );
        expect(
          snap.resetCredits.map((c) => c.grantedAt?.toIso8601String()),
          ['2026-11-02T10:00:00.000Z', '2026-11-01T10:00:00.000Z'],
        );
        expect(snap.resetCredits.every((c) => c.expiresAt!.isUtc), isTrue);

        final mapText = snap.toMap().toString();
        // The opaque id crosses so a row can redeem its own credit...
        expect(
          snap.resetCredits.map((c) => c.creditId),
          ['RateLimitResetCredit_synthetic_2', 'RateLimitResetCredit_synthetic_1'],
          reason: 'ids follow the expiry order and are never rendered',
        );
        // ...while provider copy, reset types, and descriptions never do.
        expect(mapText, isNot(contains('codex_rate_limits')));
        expect(mapText, isNot(contains('Full reset')));
        expect(mapText, isNot(contains('provider-private')));
      },
    );

    test('a zero count makes exactly one request', () async {
      final calls = <_RecordedCall>[];
      final ctx = context(
        instanceId: 'inst-zero',
        credential: oauthCred('inst-zero'),
        httpClientFactory: _routedFactory({
          '/usage': _Route.json({
            'rate_limit': {
              'primary_window': {'used_percent': 10},
            },
            'rate_limit_reset_credits': {'available_count': 0},
          }),
          '/rate-limit-reset-credits': _Route.json(
            _fixture(
              'test/fixtures/chatgpt_rate_limit_reset_credits_reference_shape.json',
            ),
          ),
        }, calls),
      );

      final snap = await adapter.fetch(ctx);

      expect(snap.availableResets, 0);
      expect(snap.resetCredits, isEmpty);
      expect(calls, hasLength(1), reason: 'no detail call at zero credits');
    });

    test('a failing detail call degrades to the count without throwing', () async {
      for (final route in [
        _Route.error(500),
        _Route.error(404),
        _Route.raw(200, 'not json at all'),
        _Route.raw(200, '[]'),
        _Route.throwing(),
      ]) {
        final ctx = context(
          instanceId: 'inst-degraded',
          credential: oauthCred('inst-degraded'),
          httpClientFactory: _routedFactory({
            '/usage': _Route.json({
              'rate_limit': {
                'primary_window': {'used_percent': 10},
              },
              'rate_limit_reset_credits': {'available_count': 1},
            }),
            '/rate-limit-reset-credits': route,
          }, <_RecordedCall>[]),
        );

        final snap = await adapter.fetch(ctx);

        expect(snap.availableResets, 1);
        expect(snap.resetCredits, isEmpty);
        expect(snap.windows, isNotEmpty);
      }
    });

    test('status and expiry filtering drops unusable entries', () async {
      // Instants are derived from the pinned clock so this test cannot rot: the
      // only surviving credit must be in the future, and an `available` credit
      // whose timestamp has passed must still be dropped.
      final now = pinnedNow;
      final future = now.add(const Duration(days: 10));
      final past = now.subtract(const Duration(hours: 2));
      final ctx = context(
        instanceId: 'inst-filter',
        credential: oauthCred('inst-filter'),
        httpClientFactory: _routedFactory({
          '/usage': _Route.json({
            'rate_limit': {
              'primary_window': {'used_percent': 10},
            },
            'rate_limit_reset_credits': {'available_count': 4},
          }),
          '/rate-limit-reset-credits': _Route.json({
            'available_count': 4,
            'credits': [
              {
                'status': 'available',
                'granted_at': past.toIso8601String(),
                'expires_at': future.toIso8601String(),
              },
              {'status': 'redeemed', 'expires_at': future.toIso8601String()},
              {'status': 'expired', 'expires_at': future.toIso8601String()},
              {'status': 'available', 'expires_at': past.toIso8601String()},
              {'status': 'available', 'expires_at': 'not-a-date'},
              {'status': 'available'},
              'not-an-object',
            ],
          }),
        }, <_RecordedCall>[]),
      );

      final snap = await adapter.fetch(ctx);

      expect(snap.resetCredits, hasLength(1));
      expect(snap.resetCredits.single.expiresAt!.isAtSameMomentAs(future), isTrue);
      expect(
        snap.resetCredits.single.grantedAt!.isAtSameMomentAs(past),
        isTrue,
      );
    });

    test('a past expiry is dropped even when the status says available', () async {
      final now = pinnedNow;
      final ctx = context(
        instanceId: 'inst-expired',
        credential: oauthCred('inst-expired'),
        httpClientFactory: _routedFactory({
          '/usage': _Route.json({
            'rate_limit': {
              'primary_window': {'used_percent': 10},
            },
            'rate_limit_reset_credits': {'available_count': 1},
          }),
          '/rate-limit-reset-credits': _Route.json({
            'available_count': 1,
            'credits': [
              {
                'id': 'RateLimitResetCredit_stale',
                'status': 'available',
                'expires_at': now
                    .subtract(const Duration(minutes: 1))
                    .toIso8601String(),
              },
            ],
          }),
        }, <_RecordedCall>[]),
      );

      final snap = await adapter.fetch(ctx);

      // The count stays authoritative; only the unusable row disappears, so the
      // Client shows the count line instead of a dead action.
      expect(snap.availableResets, 1);
      expect(snap.resetCredits, isEmpty);
    });

    test('applicable count is null when the provider omits it', () async {
      final ctx = context(
        instanceId: 'inst-no-applicable',
        credential: oauthCred('inst-no-applicable'),
        httpClientFactory: _routedFactory({
          '/usage': _Route.json({
            'rate_limit': {
              'primary_window': {'used_percent': 10},
            },
            'rate_limit_reset_credits': {'available_count': 0},
          }),
        }, <_RecordedCall>[]),
      );

      final snap = await adapter.fetch(ctx);

      expect(snap.applicableResets, isNull);
      expect(snap.toMap().containsKey('applicable_resets'), isFalse);
    });

    test('a zero applicable count survives with the available count', () async {
      final ctx = context(
        instanceId: 'inst-blocked',
        credential: oauthCred('inst-blocked'),
        httpClientFactory: _routedFactory({
          '/usage': _Route.json({
            'rate_limit': {
              'primary_window': {'used_percent': 10},
            },
            'rate_limit_reset_credits': {
              'available_count': 1,
              'applicable_available_count': 0,
            },
          }),
          '/rate-limit-reset-credits': _Route.json(
            _fixture(
              'test/fixtures/chatgpt_rate_limit_reset_credits_reference_shape.json',
            ),
          ),
        }, <_RecordedCall>[]),
      );

      final snap = await adapter.fetch(ctx);

      expect(snap.availableResets, 1);
      expect(snap.applicableResets, 0);
      expect(snap.resetCredits, isNotEmpty);
      expect(snap.toMap()['applicable_resets'], 0);
    });

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
      final adapterInstance = pinnedClockAdapter();
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
      // Backward compatibility: with no credit id the body keeps its original
      // single-field shape, so an older Client still spends the provider's
      // default credit.
      expect(jsonDecode(calls.single.body!), {
        'redeem_request_id': 'stable-key',
      });
    });

    test('targets the credit the user pressed', () async {
      final calls = <_RecordedCall>[];
      final adapter = ChatGptUsageAdapter();
      final ctx = context(
        instanceId: 'inst-reset',
        credential: oauthCred('inst-reset'),
        httpClientFactory: () => _FakeClient(
          rawBody: jsonEncode({'code': 'reset', 'windows_reset': 1}),
          calls: calls,
        ),
      );
      await adapter.reset(
        ctx,
        idempotencyKey: 'stable-key',
        creditId: 'RateLimitResetCredit_abc',
      );

      expect(jsonDecode(calls.single.body!), {
        'redeem_request_id': 'stable-key',
        'credit_id': 'RateLimitResetCredit_abc',
      });
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

  /// Request body of a POST, kept verbatim so a test can prove a targeted
  /// redemption never loses the idempotency key.
  final String? body;
  _RecordedCall(this.url, this.headers, [this.body]);
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
    calls?.add(_RecordedCall(url.toString(), headers, body?.toString()));
    return ProviderUsageHttpResponse(status, rawBody ?? '{}');
  }

  @override
  void close() {}
}

ProviderUsageHttpClient Function() _okFactory(Map<String, dynamic> payload) =>
    () => _FakeClient(jsonPayload: payload);

/// One routed answer for [_RoutedFakeClient].
class _Route {
  final int status;
  final String body;
  final bool throws;

  _Route.json(Map<String, dynamic> payload)
    : status = 200,
      body = jsonEncode(payload),
      throws = false;

  _Route.raw(this.status, this.body) : throws = false;

  _Route.error(this.status) : body = '{}', throws = false;

  _Route.throwing() : status = 0, body = '', throws = true;
}

/// Answers each request from the first route whose key is a path suffix, so a
/// test can drive the usage call and the reset-credit call independently.
class _RoutedFakeClient implements ProviderUsageHttpClient {
  final Map<String, _Route> routes;
  final List<_RecordedCall> calls;

  _RoutedFakeClient(this.routes, this.calls);

  @override
  Future<ProviderUsageHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    calls.add(_RecordedCall(url.toString(), headers));
    _Route? route;
    for (final entry in routes.entries) {
      if (url.path.endsWith(entry.key)) {
        route = entry.value;
        break;
      }
    }
    if (route == null) {
      throw StateError('unrouted request: ${url.path}');
    }
    if (route.throws) throw Exception('simulated transport failure');
    return ProviderUsageHttpResponse(route.status, route.body);
  }

  @override
  Future<ProviderUsageHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    calls.add(_RecordedCall(url.toString(), headers));
    return const ProviderUsageHttpResponse(200, '{}');
  }

  @override
  void close() {}
}

ProviderUsageHttpClient Function() _routedFactory(
  Map<String, _Route> routes,
  List<_RecordedCall> calls,
) => () => _RoutedFakeClient(routes, calls);

/// Loads a checked-in fixture relative to the package root so the suite does
/// not depend on the caller's working directory.
Map<String, dynamic> _fixture(String relativePath) {
  final agentRoot = Isolate.resolvePackageUriSync(
    Uri.parse('package:sanad_agent/'),
  )!.resolve('../');
  return jsonDecode(
        File.fromUri(agentRoot.resolve(relativePath)).readAsStringSync(),
      )
      as Map<String, dynamic>;
}

ProviderUsageHttpClient Function() _rawFactory(int status, String body) =>
    () => _FakeClient(rawBody: body, status: status);

ProviderUsageHttpClient Function() _recordingFactory(
  List<_RecordedCall> calls,
  Map<String, dynamic> payload,
) =>
    () => _FakeClient(jsonPayload: payload, calls: calls);
