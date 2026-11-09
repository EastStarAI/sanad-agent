abstract interface class AgentSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Stable, non-secret reason codes for an unavailable Agent vault.
///
/// Diagnostics, `sanad doctor` and the local gateway `/health` payload report
/// one of these codes so an operator can tell a locked-out vault from a missing
/// backend without reading any secret or guessing from a log message.
abstract final class AgentSecretStoreUnavailableReason {
  /// No supported backend for this operating system.
  static const noStore = 'no_store';

  /// This process deliberately refused to start an OS authorization prompt
  /// because nobody is present to answer it.
  static const interactionForbidden = 'interaction_forbidden';

  /// The operating system demanded an interactive authorization while this
  /// process was allowed to prompt (no UI session, locked screen, or a policy
  /// that forbids the prompt).
  static const interactionRequired = 'interaction_required';

  /// The item's access control rejected this binary (`errSecAuthFailed`).
  static const authorizationDenied = 'authorization_denied';

  /// The authorization prompt was dismissed (`errSecUserCanceled`).
  static const authorizationCanceled = 'authorization_canceled';

  /// A secret mutation was attempted through a plaintext file in a process that
  /// deliberately never opened the vault.
  static const plaintextFallbackBlocked = 'plaintext_fallback_blocked';

  /// `SANAD_SECRET_STORE=file` was requested for the production namespace. The
  /// owner-only file backend is a development and test aid, and the production
  /// Home's items are encrypted by the operating system, so the request is
  /// refused rather than quietly downgrading them to plaintext.
  static const fileStoreRefusedForApp = 'file_store_refused_for_app';

  /// `SANAD_SECRET_STORE=os` was requested inside the Dart test runtime or a
  /// deterministic E2E process, which must never reach the real credential
  /// store.
  static const osStoreRefusedForTest = 'os_store_refused_for_test';

  /// `SANAD_SECRET_STORE` carried a value that is neither `file` nor `os`.
  static const invalidStoreSelection = 'invalid_store_selection';

  /// The vault is still opening: the operating-system store has not answered
  /// yet, so a missing value is unknown rather than absent.
  static const vaultNotReady = 'vault_not_ready';

  /// The vault backend failed for another reason; the message carries the code.
  static const backendError = 'backend_error';

  /// The vault was explicitly disabled (for example a Home with no owner).
  static const unavailable = 'unavailable';
}

class AgentSecretStoreUnavailable implements Exception {
  const AgentSecretStoreUnavailable(
    this.message, {
    this.reasonCode = AgentSecretStoreUnavailableReason.unavailable,
  });

  final String message;

  /// Non-secret machine-readable cause, one of
  /// [AgentSecretStoreUnavailableReason].
  final String reasonCode;

  @override
  String toString() => 'AgentSecretStoreUnavailable($reasonCode): $message';
}
