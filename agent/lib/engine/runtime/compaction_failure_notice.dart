import 'package:logging/logging.dart';

import '../../evolution/db/persisted_runtime_state_repository.dart';
import '../compaction/compaction.dart';

/// Durable `warning` runtime notice for a failed automatic compaction.
///
/// Ownership: the runner's automatic-compaction path is the only writer. The
/// failure itself already reaches the live/historical lifecycle timeline
/// (`context_compaction.failed`), but a non-interactive `sanad run` session has
/// no Client watching it and `session show` does not project compaction
/// operations, so the session used to run uncompacted with no observable
/// reason. This owner makes that state visible to the Client and to whoever
/// observes the session.
///
/// Contract:
/// - The row lives in `session_runtime_notices` with `status: warning` and
///   `severity: warning`. It is never a recovery state: it never enters
///   `RuntimeRecoveryService` memory, so it cannot gate admission, retry
///   classification, or turn recovery, and it offers no client action.
/// - The message is built from one allowlisted cause sentence. No provider
///   text, no summary content, no user content, no path, and no secret.
/// - Automatic compaction is blocked only for the current run, so the message
///   says the session continues uncompacted and that automatic compaction is
///   paused until the run ends.
/// - A later successful automatic compaction of the same session clears the
///   row, and only while the stored row is still a compaction warning.
abstract final class CompactionFailureNotice {
  /// Notice status of a non-recovery, informational warning.
  static const String status = 'warning';

  static const String severity = 'warning';

  static const String title = 'Automatic compaction failed';

  static final Logger _logger = Logger('CompactionFailureNotice');

  /// One short, human-readable sentence per allowlisted failure cause.
  static const Map<String, String> causeSentences = {
    CompactionFailureCause.continuityValidationFailed:
        'the summary did not preserve the conversation continuity anchors',
    CompactionFailureCause.invalidResponse:
        'the summarizer did not return a usable summary',
    CompactionFailureCause.summaryInvalidJson:
        'the summarizer did not return a valid summary object',
    CompactionFailureCause.summarySchemaMismatch:
        'the summary did not match the summary schema',
    CompactionFailureCause.summaryEmpty:
        'the summarizer returned an empty summary',
    CompactionFailureCause.summaryIncomplete:
        'the summarizer stopped before the summary was complete',
    CompactionFailureCause.summaryTruncated:
        'the summary was cut off at the model output limit',
    CompactionFailureCause.summaryReasoningOnly:
        'the summarizer returned reasoning without a summary',
    CompactionFailureCause.summaryToolCall:
        'the summarizer tried to call a tool instead of answering',
    CompactionFailureCause.timeout: 'the summary request timed out',
    CompactionFailureCause.rateLimited:
        'the provider rate limit was reached',
    CompactionFailureCause.overflow:
        'the summary request exceeded the model context window',
    CompactionFailureCause.recoveryCapacityExceeded:
        'the conversation is too large to summarize in bounded passes',
    CompactionFailureCause.projectionStillOverBudget:
        'the compacted projection would still exceed the context limit',
    CompactionFailureCause.toolResultMalformed:
        'the conversation could not be prepared for summarization',
    CompactionFailureCause.pruningFailed:
        'the conversation could not be prepared for summarization',
    CompactionFailureCause.providerError:
        'the provider rejected the summary request',
    CompactionFailureCause.networkError:
        'the provider endpoint could not be reached',
    CompactionFailureCause.persistenceFailed:
        'the compaction boundary could not be saved',
    CompactionFailureCause.databaseError:
        'the compaction boundary could not be saved',
    CompactionFailureCause.sourceRevisionStale:
        'the conversation changed while it was being summarized',
    CompactionFailureCause.claimLost:
        'the conversation changed while it was being summarized',
    CompactionFailureCause.staleOperation:
        'the conversation changed while it was being summarized',
    CompactionFailureCause.superseded:
        'a newer compaction replaced this one',
    CompactionFailureCause.missingMessageRows:
        'the summarized messages are no longer available',
    CompactionFailureCause.interrupted:
        'the daemon restarted while summarizing',
    CompactionFailureCause.unexpectedError:
        'the summarizer failed unexpectedly',
  };

  /// The warning message for one failure: one allowlisted cause sentence, the
  /// run-scoped effect, and no conversation content.
  static String message({
    required CompactionFailureReason reason,
    String? failureCause,
  }) {
    final cause =
        causeSentences[failureCause] ??
        (reason == CompactionFailureReason.continuityValidationFailed
            ? causeSentences[CompactionFailureCause.continuityValidationFailed]!
            : 'the summarizer did not return a usable summary');
    return 'The session is continuing without compacting its context: $cause. '
        'Automatic compaction is paused until this run ends.';
  }

  /// Persists the warning for [sessionId].
  ///
  /// Best effort: a session that cannot record its warning still continues, so
  /// a storage failure is logged as a scalar cause and never replaces the
  /// compaction outcome.
  static void report(
    PersistedRuntimeStateRepository? store, {
    required String sessionId,
    required CompactionFailureReason reason,
    String? failureCause,
    String? requestId,
    String? runId,
  }) {
    if (store == null || sessionId.isEmpty) return;
    try {
      store.upsertNotice(
        sessionId: sessionId,
        requestId: requestId,
        runId: runId,
        status: status,
        reason: reason.wireValue,
        severity: severity,
        title: title,
        message: message(reason: reason, failureCause: failureCause),
        actions: const [],
      );
      _logger.info(
        'Automatic compaction warning recorded; '
        'session=$sessionId reason=${reason.wireValue} '
        'cause=${failureCause ?? 'none'}.',
      );
    } catch (error) {
      _logger.warning(
        'Could not record the automatic compaction warning: '
        '${error.runtimeType}.',
      );
    }
  }

  /// Clears a stored compaction warning after a successful automatic
  /// compaction, leaving any real recovery notice untouched.
  static void clear(
    PersistedRuntimeStateRepository? store, {
    required String sessionId,
  }) {
    if (store == null || sessionId.isEmpty) return;
    try {
      if (!isCompactionWarning(store.findNotice(sessionId))) return;
      store.deleteNotice(sessionId);
    } catch (error) {
      _logger.warning(
        'Could not clear the automatic compaction warning: '
        '${error.runtimeType}.',
      );
    }
  }

  /// Whether a stored notice row is this owner's warning.
  ///
  /// Compaction reasons are the only snake_case reasons a notice row carries;
  /// recovery notices persist a `RuntimeFailureReason` name instead.
  static bool isCompactionWarning(PersistedRuntimeNotice? notice) {
    if (notice == null || notice.status != status) return false;
    return CompactionFailureReason.values.any(
      (reason) => reason.wireValue == notice.reason,
    );
  }
}
