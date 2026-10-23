import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';

import 'session_turn_executor.dart';

/// What one inbound session input does at admission.
///
/// The classifier decides only this disposition. Every projection, publication,
/// durable reservation, route rewrite, and queue mutation stays with
/// `SessionRunOrchestrator`, which remains the sole admission and active-run
/// authority.
enum SessionInputDisposition {
  /// A `steer_only` command found no live owner, so it is rejected and is never
  /// queued or admitted as a new turn.
  rejectSteerOnly,

  /// A queue-promotion command lost its owner before delivery and reports a
  /// stale owner.
  staleQueuePromotion,

  /// The live owner accepts this input as a steer.
  steer,

  /// Older work still owns the session, so the input waits in FIFO order.
  queue,

  /// Nothing older owns the session, so the input becomes a new turn now.
  immediate,
}

/// Pure classification of an inbound session event into a [SessionInputDisposition].
///
/// The inputs are read-only projections the orchestrator already holds, and the
/// two owner questions that only the orchestrator can answer (`ownsRun` and
/// `hasOlderWork`) arrive as typed callbacks so no state leaves its owner.
class SessionInputClassifier {
  const SessionInputClassifier();

  /// Whether a live, non-invalidated owner can accept a steer for this input.
  ///
  /// A steer targets the exact `ActiveRun.agentRunner` only while its owner
  /// still matches the durable running/resuming work, has not begun Stop, and is
  /// not in a recovery wait that owns the session.
  bool canSteer({
    required bool controlledRestartDraining,
    required MessageDeliveryIntent deliveryIntent,
    required ActiveRun? activeRun,
    required bool Function(ActiveRun activeRun) ownsRun,
    required SessionWorkItem? durableActiveWork,
    required RuntimeNotice? activeRecoveryNotice,
  }) {
    return !controlledRestartDraining &&
        deliveryIntent == MessageDeliveryIntent.auto &&
        activeRun != null &&
        ownsRun(activeRun) &&
        !activeRun.stopRequested &&
        (durableActiveWork == null ||
            durableActiveWork.state == SessionWorkState.running ||
            durableActiveWork.state == SessionWorkState.resuming) &&
        (activeRecoveryNotice == null ||
            activeRecoveryNotice.status == RuntimeNoticeStatus.resuming);
  }

  /// Classifies one inbound event.
  ///
  /// [hasOlderWork] is evaluated only on the paths that need it, so a classified
  /// steer never reads the busy, compaction, or queue projections. That keeps
  /// the admission reads of a steer identical to the pre-split flow.
  SessionInputDisposition classify({
    required bool controlledRestartDraining,
    required MessageDeliveryIntent deliveryIntent,
    required ActiveRun? activeRun,
    required bool Function(ActiveRun activeRun) ownsRun,
    required SessionWorkItem? durableActiveWork,
    required RuntimeNotice? activeRecoveryNotice,
    required bool steerOnlyRequested,
    required bool isQueuePromotionCommand,
    required bool steerActionable,
    required bool Function() hasOlderWork,
  }) {
    final steerable = canSteer(
      controlledRestartDraining: controlledRestartDraining,
      deliveryIntent: deliveryIntent,
      activeRun: activeRun,
      ownsRun: ownsRun,
      durableActiveWork: durableActiveWork,
      activeRecoveryNotice: activeRecoveryNotice,
    );
    // A `steer_only` command may never become a turn: without a live owner the
    // message is rejected instead of falling through to the ordinary
    // admission path, so the text is neither queued nor admitted as a new
    // turn (and an unknown session id is never created by a steer). Clients
    // that omit the flag keep the legacy admit-or-queue behaviour.
    if (steerOnlyRequested && !steerable) {
      return SessionInputDisposition.rejectSteerOnly;
    }
    if (!steerable && isQueuePromotionCommand) {
      return SessionInputDisposition.staleQueuePromotion;
    }
    if (steerable && steerActionable) {
      return SessionInputDisposition.steer;
    }
    if (hasOlderWork()) {
      return SessionInputDisposition.queue;
    }
    return SessionInputDisposition.immediate;
  }
}
