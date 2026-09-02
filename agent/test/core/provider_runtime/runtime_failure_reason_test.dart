import 'package:test/test.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';

void main() {
  group('RuntimeFailureReason.classify — HTTP status codes', () {
    test('401 → auth', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 401),
        equals(RuntimeFailureReason.auth),
      );
    });

    test('403 → auth', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 403),
        equals(RuntimeFailureReason.auth),
      );
    });

    test('402 → billing', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 402),
        equals(RuntimeFailureReason.billing),
      );
    });

    test('429 → rateLimit by default', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 429),
        equals(RuntimeFailureReason.rateLimit),
      );
    });

    test('429 with "upstream" → upstreamRateLimit', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 429,
          body: 'upstream rate limited by aggregator',
        ),
        equals(RuntimeFailureReason.upstreamRateLimit),
      );
    });

    test('429 with "overload" → overloaded', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 429,
          body: 'server overloaded',
        ),
        equals(RuntimeFailureReason.overloaded),
      );
    });

    test('429 with "quota" and no reset hint → billing', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 429, body: 'quota exceeded'),
        equals(RuntimeFailureReason.billing),
      );
    });

    test('429 with "quota" and trusted reset hint → rateLimit', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 429,
          body: 'quota exceeded',
          hasTrustedTemporaryReset: true,
        ),
        equals(RuntimeFailureReason.rateLimit),
      );
    });

    test('413 → payloadTooLarge', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 413),
        equals(RuntimeFailureReason.payloadTooLarge),
      );
    });

    test('503 with overload body → overloaded', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 503,
          body: 'service at capacity / overloaded',
        ),
        equals(RuntimeFailureReason.overloaded),
      );
    });

    test('503 upstream connection reset → networkError', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 503,
          body:
              'upstream connect error or disconnect/reset before headers. '
              'reset reason: remote connection failure',
        ),
        equals(RuntimeFailureReason.networkError),
      );
    });

    test('503 explicit upstream rate limit → upstreamRateLimit', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 503,
          body: 'upstream rate limit exceeded; too many requests',
        ),
        equals(RuntimeFailureReason.upstreamRateLimit),
      );
    });

    test('504 gateway timeout → timeout', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 504),
        equals(RuntimeFailureReason.timeout),
      );
    });

    test('504 with gateway body → timeout (not upstreamRateLimit)', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 504,
          body: 'upstream gateway timeout',
        ),
        equals(RuntimeFailureReason.timeout),
      );
    });

    test('500 with ResourceExhausted and request limit → rateLimit', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 500,
          body:
              'ResourceExhausted: Worker local total request limit reached (49/48)',
        ),
        equals(RuntimeFailureReason.rateLimit),
      );
    });

    test('500 with vague ResourceExhausted body → unknown', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 500,
          body: 'ResourceExhausted',
        ),
        equals(RuntimeFailureReason.unknown),
      );
    });

    test('500 with ResourceExhausted + capacity → overloaded', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 500,
          body: 'ResourceExhausted: worker unavailable / capacity exceeded',
        ),
        equals(RuntimeFailureReason.overloaded),
      );
    });

    test(
      '500 with ResourceExhausted + insufficient quota without reset → billing',
      () {
        expect(
          RuntimeFailureReason.classify(
            statusCode: 500,
            body: 'ResourceExhausted: insufficient quota',
          ),
          equals(RuntimeFailureReason.billing),
        );
      },
    );

    test(
      '500 with ResourceExhausted + insufficient quota with trusted reset → rateLimit',
      () {
        expect(
          RuntimeFailureReason.classify(
            statusCode: 500,
            body: 'ResourceExhausted: insufficient quota',
            hasTrustedTemporaryReset: true,
          ),
          equals(RuntimeFailureReason.rateLimit),
        );
      },
    );

    test('500 unknown → unknown', () {
      expect(
        RuntimeFailureReason.classify(statusCode: 500),
        equals(RuntimeFailureReason.unknown),
      );
    });

    test('404 with model body → modelNotFound', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 404,
          body: 'model not available',
        ),
        equals(RuntimeFailureReason.modelNotFound),
      );
    });

    test('400 generic bad request → invalidRequest', () {
      expect(
        RuntimeFailureReason.classify(
          statusCode: 400,
          body: 'unsupported parameter: foo',
        ),
        equals(RuntimeFailureReason.invalidRequest),
      );
    });
  });

  group('RuntimeFailureReason.classify — body patterns (no status)', () {
    test('insufficient credits → billing', () {
      expect(
        RuntimeFailureReason.classify(body: 'insufficient credits'),
        equals(RuntimeFailureReason.billing),
      );
    });

    test('payment required → billing', () {
      expect(
        RuntimeFailureReason.classify(body: 'payment required'),
        equals(RuntimeFailureReason.billing),
      );
    });

    test('insufficient_quota → billing', () {
      expect(
        RuntimeFailureReason.classify(body: 'insufficient_quota'),
        equals(RuntimeFailureReason.billing),
      );
    });

    test('usage limit with reset text → rateLimit', () {
      expect(
        RuntimeFailureReason.classify(
          body:
              'Usage limit reached. Your limit will reset at 2026-07-11 04:21:28',
        ),
        equals(RuntimeFailureReason.rateLimit),
      );
    });

    test('rate limit text → rateLimit', () {
      expect(
        RuntimeFailureReason.classify(body: 'rate limit exceeded'),
        equals(RuntimeFailureReason.rateLimit),
      );
    });

    test('context length → contextOverflow', () {
      expect(
        RuntimeFailureReason.classify(body: 'maximum context length exceeded'),
        equals(RuntimeFailureReason.contextOverflow),
      );
      expect(
        RuntimeFailureReason.classify(
          statusCode: 400,
          body: 'maximum context length exceeded',
        ),
        equals(RuntimeFailureReason.contextOverflow),
      );
    });

    test('timeout → timeout', () {
      expect(
        RuntimeFailureReason.classify(body: 'request timed out'),
        equals(RuntimeFailureReason.timeout),
      );
    });

    test('socket error → networkError', () {
      expect(
        RuntimeFailureReason.classify(body: 'socket exception'),
        equals(RuntimeFailureReason.networkError),
      );
    });

    test('certificate verify failed → tlsCertificate', () {
      expect(
        RuntimeFailureReason.classify(
          body: 'HandshakeException: certificate verify failed (OS Error)',
        ),
        equals(RuntimeFailureReason.tlsCertificate),
      );
    });

    test('interrupted tls handshake stays networkError', () {
      expect(
        RuntimeFailureReason.classify(
          body: 'SocketException: connection reset during tls handshake',
        ),
        equals(RuntimeFailureReason.networkError),
      );
    });

    test('ssl transient alert stays networkError', () {
      expect(
        RuntimeFailureReason.classify(
          body: 'network error: ssl alert handshake failure',
        ),
        equals(RuntimeFailureReason.networkError),
      );
    });

    test('content_filter → contentPolicyBlocked', () {
      expect(
        RuntimeFailureReason.classify(body: 'triggered content_filter'),
        equals(RuntimeFailureReason.contentPolicyBlocked),
      );
    });

    test('gibberish → unknown', () {
      expect(
        RuntimeFailureReason.classify(body: 'xyz random gibberish'),
        equals(RuntimeFailureReason.unknown),
      );
    });
  });

  group('RuntimeFailureReason.decision — key distinctions', () {
    test('rate_limit is waiting + retryable + allows failover', () {
      final d = RuntimeFailureReason.rateLimit.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.waiting));
      expect(d.retryable, isTrue);
      expect(d.allowAutoFailover, isTrue);
    });

    test('upstreamRateLimit is waiting + allows failover', () {
      final d = RuntimeFailureReason.upstreamRateLimit.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.waiting));
      expect(d.allowAutoFailover, isTrue);
    });

    test('overloaded is waiting but NOT failover (server-side)', () {
      final d = RuntimeFailureReason.overloaded.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.waiting));
      expect(d.allowAutoFailover, isFalse);
    });

    test('billing is blocked + NOT retryable + allows failover', () {
      final d = RuntimeFailureReason.billing.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.blocked));
      expect(d.retryable, isFalse);
      expect(d.allowAutoFailover, isTrue);
    });

    test('auth is blocked + NOT retryable + NOT failover', () {
      final d = RuntimeFailureReason.auth.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.blocked));
      expect(d.retryable, isFalse);
      expect(d.allowAutoFailover, isFalse);
    });

    test('contextOverflow is fatal + NOT retryable', () {
      final d = RuntimeFailureReason.contextOverflow.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.fatal));
      expect(d.retryable, isFalse);
    });

    test('contentPolicyBlocked is fatal', () {
      final d = RuntimeFailureReason.contentPolicyBlocked.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.fatal));
    });

    test('networkError is blocked + manual retry', () {
      final d = RuntimeFailureReason.networkError.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.blocked));
      expect(d.allowManualRetry, isTrue);
      expect(d.uiActions, contains(RuntimeNoticeAction.retry));
    });

    test('tlsCertificate is blocked + manual retry but not auto retry', () {
      final d = RuntimeFailureReason.tlsCertificate.decision();
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.blocked));
      expect(d.retryable, isFalse);
      expect(d.allowManualRetry, isTrue);
    });

    test('auth exposes openProviderSettings action', () {
      final d = RuntimeFailureReason.auth.decision();
      expect(d.uiActions, contains(RuntimeNoticeAction.openProviderSettings));
    });

    test('modelNotFound exposes changeProvider action', () {
      final d = RuntimeFailureReason.modelNotFound.decision();
      expect(d.uiActions, contains(RuntimeNoticeAction.changeProvider));
    });
  });

  // ── Plan 30 Phase H: per-reason retry budget & unknown-manual ──────────
  group('RuntimeFailureReason — Plan 30 Phase H retry policy', () {
    test('unknown is NOT auto-retryable (manual only)', () {
      final d = RuntimeFailureReason.unknown.decision();
      // Phase H §5: unknown is blocked with manual retry, NOT auto-retry.
      expect(d.allowManualRetry, isTrue);
      // retryable=true still allows manual retry path; the runtime must NOT
      // consume an automatic budget for unknown (handled by budget policy).
      expect(d.noticeStatus, equals(RuntimeNoticeStatus.blocked));
    });

    test('deterministic 4xx reasons are not auto-retryable', () {
      // Phase H §5: auth, billing, model-not-found, content-policy,
      // payload/format must not consume auto-retry budget.
      for (final reason in [
        RuntimeFailureReason.auth,
        RuntimeFailureReason.billing,
        RuntimeFailureReason.modelNotFound,
        RuntimeFailureReason.contentPolicyBlocked,
        RuntimeFailureReason.payloadTooLarge,
        RuntimeFailureReason.contextOverflow,
      ]) {
        final d = reason.decision();
        expect(
          d.retryable,
          isFalse,
          reason: '$reason must not be retryable (deterministic failure)',
        );
      }
    });

    test('network/timeout are retryable but blocked (manual)', () {
      final net = RuntimeFailureReason.networkError.decision();
      final timeout = RuntimeFailureReason.timeout.decision();
      expect(net.retryable, isTrue);
      expect(net.noticeStatus, equals(RuntimeNoticeStatus.blocked));
      expect(timeout.retryable, isTrue);
      expect(timeout.noticeStatus, equals(RuntimeNoticeStatus.blocked));
    });

    test('rate-limit and overloaded are waiting + retryable', () {
      expect(
        RuntimeFailureReason.rateLimit.decision().noticeStatus,
        equals(RuntimeNoticeStatus.waiting),
      );
      expect(
        RuntimeFailureReason.overloaded.decision().noticeStatus,
        equals(RuntimeNoticeStatus.waiting),
      );
    });
  });

  // ── Plan 30 Phase H §5: expanded model-not-found patterns ─────────────
  group('RuntimeFailureReason.classify — Phase H model-not-found', () {
    test('recognizes "Unknown Model, please check the model code."', () {
      expect(
        RuntimeFailureReason.classify(
          body: 'Unknown Model, please check the model code.',
        ),
        equals(RuntimeFailureReason.modelNotFound),
      );
    });

    test('recognizes "Unknown Model" without status code', () {
      expect(
        RuntimeFailureReason.classify(body: 'Unknown Model'),
        equals(RuntimeFailureReason.modelNotFound),
      );
    });

    test('recognizes model-not-found via 400 with model body', () {
      // Some providers return 400 for an invalid model id.
      expect(
        RuntimeFailureReason.classify(
          statusCode: 400,
          body: 'Unknown Model, please check the model code.',
        ),
        equals(RuntimeFailureReason.modelNotFound),
      );
    });
  });

  group('RuntimeNotice payload', () {
    test('waiting notice includes retry_after_ms and resume_at', () {
      final now = DateTime.utc(2026, 7, 9, 12, 0, 0);
      final resume = now.add(const Duration(seconds: 24));
      final notice = RuntimeNotice(
        sessionId: 's1',
        status: RuntimeNoticeStatus.waiting,
        reason: RuntimeFailureReason.rateLimit,
        title: 'NVIDIA NIM rate limit reached',
        message: 'Continuing automatically.',
        providerInstanceId: 'p1',
        providerDisplayName: 'NVIDIA NIM',
        resumeAt: resume,
        limit: 38,
        actions: const [
          RuntimeNoticeAction.stop,
          RuntimeNoticeAction.changeProvider,
        ],
        createdAt: now,
        updatedAt: now,
      );
      final payload = notice.toPayload();
      expect(payload['status'], equals('waiting'));
      expect(payload['reason'], equals('rate_limit'));
      expect(payload['provider_instance_id'], equals('p1'));
      expect(payload['limit']['requests_per_minute'], equals(38));
      expect(payload['resume_at'], equals(resume.toIso8601String()));
      expect(payload['actions'], equals(['stop', 'change_provider']));
    });

    test('blocked notice has no resume_at/retry_after_ms', () {
      final now = DateTime.utc(2026, 7, 9, 12, 0, 0);
      final notice = RuntimeNotice(
        sessionId: 's1',
        status: RuntimeNoticeStatus.blocked,
        reason: RuntimeFailureReason.networkError,
        title: 'Connection failed',
        message: 'Could not reach the service.',
        actions: const [
          RuntimeNoticeAction.retry,
          RuntimeNoticeAction.changeProvider,
        ],
        createdAt: now,
        updatedAt: now,
      );
      final payload = notice.toPayload();
      expect(payload['status'], equals('blocked'));
      expect(payload.containsKey('resume_at'), isFalse);
      expect(payload.containsKey('retry_after_ms'), isFalse);
    });
  });
}
