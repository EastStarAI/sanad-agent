import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/notifications/application/notification_presence_store.dart';

/// Reports the conversation surface that is currently on screen.
///
/// This is the only writer of the session half of presence, and it reports
/// identity rather than reacting to arrivals: a notification decision reads
/// "is the user looking at this session" and nothing here decides whether a
/// banner is raised. Because it lives inside the routed conversation surface,
/// leaving the surface (Settings, another device, the tray-hidden window)
/// either clears it or is caught by the window lifecycle.
class NotificationPresenceReporter extends StatefulWidget {
  const NotificationPresenceReporter({
    super.key,
    required this.destination,
    required this.child,
  });

  /// The destination the routed surface is presenting, when it has one.
  final ConversationDestination? destination;

  final Widget child;

  @override
  State<NotificationPresenceReporter> createState() =>
      _NotificationPresenceReporterState();
}

class _NotificationPresenceReporterState extends State<NotificationPresenceReporter> {
  late final NotificationPresenceStore _presence;
  StreamSubscription<SessionState>? _sessionSubscription;

  @override
  void initState() {
    super.initState();
    // Presence is observation, not authority: a surface mounted without the
    // provider (an isolated widget test, a preview) reports nothing instead of
    // failing, and the display pipeline then treats the ask as not on screen.
    _presence = context.read<NotificationPresenceStore?>() ?? NotificationPresenceStore();
    final sessionCubit = context.read<SessionCubit>();
    _sessionSubscription = sessionCubit.stream.listen((_) => _reportPendingRequest());
    _reportSurface();
  }

  @override
  void didUpdateWidget(covariant NotificationPresenceReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination != widget.destination) {
      _reportSurface();
    }
  }

  @override
  void dispose() {
    unawaited(_sessionSubscription?.cancel());
    _presence.clearConversationSurface();
    super.dispose();
  }

  void _reportSurface() {
    final destination = widget.destination;
    final sessionId = destination?.sessionId;
    if (destination == null ||
        destination.kind != ConversationDestinationKind.session ||
        sessionId == null ||
        sessionId.isEmpty) {
      _presence.clearConversationSurface();
      return;
    }
    _presence.reportConversationSurface(
      deviceId: destination.deviceId,
      sessionId: sessionId,
      requestId: _pendingRequestId(),
    );
  }

  void _reportPendingRequest() {
    final destination = widget.destination;
    final sessionId = destination?.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    _presence.reportPendingRequest(_pendingRequestId());
  }

  String? _pendingRequestId() {
    final destination = widget.destination;
    final sessionId = destination?.sessionId;
    if (destination == null || sessionId == null || sessionId.isEmpty) return null;
    return context
        .read<SessionCubit>()
        .state
        .attentionStateFor(destination.deviceId, sessionId)
        ?.pendingSuspendedRequest
        ?.requestId;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
