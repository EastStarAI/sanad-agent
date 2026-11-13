/// The notification taxonomy.
///
/// The Agent owns every decision about an Agent-raised notification: whether an
/// event notifies, its kind, its urgency, its copy, and its target. The Client
/// only projects the kind it is handed, so the wire token — never a positional
/// enum index — is the identity that crosses the socket.
///
/// Two kinds are Client-owned because only the Client can observe them: a lost
/// Agent connection and an account that needs re-authentication. They are
/// listed here so the taxonomy and the per-kind preferences stay one model on
/// every platform, but 174b does not raise them.
enum NotificationKind {
  permissionRequest('permission_request'),
  userQuestion('user_question'),
  blocked('blocked'),
  failed('failed'),
  completed('completed'),
  backgroundTaskDone('background_task_done'),
  scheduledResult('scheduled_result'),
  providerQuota('provider_quota'),
  connectionLost('connection_lost'),
  authRequired('auth_required');

  const NotificationKind(this.wire);

  /// The token the Agent sends and the Client stores in preferences.
  final String wire;

  /// Resolves a wire token, or `null` for a kind this Client does not know.
  ///
  /// An unknown kind is never guessed into a known one: the Agent may add a
  /// kind this build predates, and raising it under the wrong identity would
  /// notify for something the user never enabled.
  static NotificationKind? fromWire(Object? value) {
    if (value is! String) return null;
    final token = value.trim();
    if (token.isEmpty) return null;
    for (final kind in NotificationKind.values) {
      if (kind.wire == token) return kind;
    }
    return null;
  }

  /// Kinds the Client raises itself instead of receiving from the Agent.
  bool get isClientOwned =>
      this == NotificationKind.connectionLost ||
      this == NotificationKind.authRequired;

  /// Whether the notification carries an execution decision that can be
  /// answered straight from the notification surface.
  ///
  /// Only a permission request is an approval. A question needs free text, so
  /// its notification opens the session instead of offering an answer button.
  bool get supportsApprovalActions => this == NotificationKind.permissionRequest;
}
