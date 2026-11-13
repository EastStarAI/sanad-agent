import 'package:equatable/equatable.dart';

import '../models/notification_kind.dart';
import '../models/notification_payload.dart';
import '../models/notification_presence.dart';

/// What a push means for the user while the app is running.
enum MobileForegroundOutcome {
  /// The user is looking at the exact session: the in-app prompt is the only
  /// surface, and no banner or sound is raised.
  inAppOnly,

  /// The user is somewhere else in the app: raise a heads-up notification with
  /// the Agent copy and actions.
  headsUp,
}

/// One foreground decision plus the session it was made about.
class MobileForegroundDecision extends Equatable {
  const MobileForegroundDecision(this.outcome, {this.kind, this.sessionId});

  final MobileForegroundOutcome outcome;
  final NotificationKind? kind;
  final String? sessionId;

  bool get isInAppOnly => outcome == MobileForegroundOutcome.inAppOnly;

  bool get showsBanner => outcome == MobileForegroundOutcome.headsUp;

  @override
  List<Object?> get props => [outcome, kind, sessionId];
}

/// The mobile foreground rule.
///
/// A push is only a wake-up: the Client decides what the user sees. The rule is
/// the same one the desktop pipeline already applies, expressed for mobile so
/// that a foreground arrival is either folded into the open conversation or
/// raised as a heads-up banner:
///
/// - the exact visible session means in-app only, because the prompt the ask
///   needs is already on screen;
/// - any other visible surface means a heads-up banner, because an open app on a
///   different session is not evidence that a human is watching this one;
/// - a backgrounded or terminated app is never "in app", so the operating
///   system presents the notification it was handed.
///
/// The decision is pure and injected, so the matrix is proven by tests instead
/// of by a device. It deliberately reuses [NotificationPresence.showsAsk] rather
/// than re-deriving "is the user looking at this", so mobile and desktop can
/// never disagree about the same session.
class MobileForegroundPolicy {
  MobileForegroundPolicy._();

  static MobileForegroundDecision decide({
    required NotificationPayload payload,
    required NotificationPresence presence,
    required bool appInForeground,
  }) {
    if (!appInForeground) {
      return MobileForegroundDecision(
        MobileForegroundOutcome.headsUp,
        kind: payload.kind,
        sessionId: payload.sessionId,
      );
    }
    final outcome = presence.showsAsk(
      sessionId: payload.sessionId,
      requestId: payload.requestId,
    )
        ? MobileForegroundOutcome.inAppOnly
        : MobileForegroundOutcome.headsUp;
    return MobileForegroundDecision(
      outcome,
      kind: payload.kind,
      sessionId: payload.sessionId,
    );
  }

  /// The session a native foreground hook must treat as already on screen.
  ///
  /// iOS asks the app whether to present a remote notification while the app is
  /// in the foreground, before any Dart code sees it. Mirroring the exact
  /// session keeps that hook per-event instead of making the whole foreground
  /// silent, which the product rejects: another session must still raise a
  /// banner.
  static String? visibleSessionForNative(
    NotificationPresence presence, {
    required bool appInForeground,
  }) {
    if (!appInForeground || !presence.windowVisible) return null;
    final sessionId = presence.sessionId;
    if (sessionId == null || sessionId.isEmpty) return null;
    return sessionId;
  }
}
