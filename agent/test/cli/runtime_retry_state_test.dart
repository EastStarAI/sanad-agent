import 'package:sanad_agent/cli/models/runtime_retry_state.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

/// The CLI's recovery classification is pure, so the two readings that used to
/// keep an ended turn alive are pinned here without a daemon:
///
/// 1. a durable `idle` snapshot outranks a leftover notice (never `retrying`);
/// 2. a `fatal` notice never promises another attempt, whatever it carries.
void main() {
  useIsolatedSanadTestHome();

  group('RuntimeRetryState', () {
    test('an ended snapshot is not retrying, even with a waiting notice', () {
      // A projection can keep the notice of a turn the daemon already ended.
      // `execution_snapshot.state == idle` means it stopped publishing that
      // turn, so the leftover `waiting` notice must not keep the turn looking
      // like an automatic retry that will never arrive.
      final state = RuntimeRetryState.fromProjection({
        'execution_snapshot': {'state': 'idle', 'revision': 12},
        'runtime_notice': {
          'status': 'waiting',
          'reason': 'timeout',
          'retry_attempt': 1,
          'retry_budget': 1,
          'retry_after_ms': 2000,
        },
      });

      expect(state.hasRetryBudgetLeft, isFalse);
      expect(state.isAutoRetrying, isFalse);
      expect(state.isTrulyBlocked, isFalse);
    });

    test('a fatal notice never reports retry budget left', () {
      // A permanently rejected request is not retried by definition, so the
      // counters its reason happens to carry cannot promise an attempt.
      final state = RuntimeRetryState.fromNotice({
        'status': 'fatal',
        'reason': 'model_not_found',
        'retry_attempt': 1,
        'retry_budget': 3,
      });

      expect(state.hasRetryBudgetLeft, isFalse);
      expect(state.isAutoRetrying, isFalse);
      expect(state.isTrulyBlocked, isTrue);
    });
  });
}
