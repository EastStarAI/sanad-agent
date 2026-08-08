enum AuthRefreshOutcome { success, terminalRejected, transientUnavailable }

class AuthRefreshResult {
  final AuthRefreshOutcome outcome;
  final String? accessToken;

  const AuthRefreshResult._({required this.outcome, this.accessToken});

  const AuthRefreshResult.success(String accessToken)
    : this._(outcome: AuthRefreshOutcome.success, accessToken: accessToken);

  const AuthRefreshResult.terminalRejected()
    : this._(outcome: AuthRefreshOutcome.terminalRejected);

  const AuthRefreshResult.transientUnavailable()
    : this._(outcome: AuthRefreshOutcome.transientUnavailable);

  bool get isSuccess => outcome == AuthRefreshOutcome.success;
  bool get isTerminal => outcome == AuthRefreshOutcome.terminalRejected;
}
