/// Parsed response of `provider.auth.start`.
///
/// Carries the session id, flow kind, and device-code/loopback artifacts
/// (verification URI, user code, interval, expiry) needed by the UI to render
/// the sign-in surface. An [error] field is set when the agent fails to start
/// the flow.
class AuthSessionDto {
  final String? sessionId;
  final String? flow;
  final String? verificationUri;
  final String? verificationUriComplete;
  final String? userCode;
  final int? interval;
  final int? expiresAt;
  final String? error;

  const AuthSessionDto({
    this.sessionId,
    this.flow,
    this.verificationUri,
    this.verificationUriComplete,
    this.userCode,
    this.interval,
    this.expiresAt,
    this.error,
  });

  bool get hasError => error != null && error!.isNotEmpty;

  factory AuthSessionDto.fromJson(Map<String, dynamic> json) {
    return AuthSessionDto(
      sessionId: json['session_id']?.toString(),
      flow: json['flow']?.toString(),
      verificationUri: json['verification_uri']?.toString(),
      verificationUriComplete: json['verification_uri_complete']?.toString(),
      userCode: json['user_code']?.toString(),
      interval: json['interval'] is int ? json['interval'] as int : int.tryParse(json['interval']?.toString() ?? ''),
      expiresAt: json['expires_at'] is int
          ? json['expires_at'] as int
          : int.tryParse(json['expires_at']?.toString() ?? ''),
      error: json['error']?.toString(),
    );
  }
}

/// Status of a polling cycle for `provider.auth.poll` / `provider.auth.submit`.
enum AuthPollStatus { pending, approved, expired, error, cancelled, unknown }

/// Parsed response of `provider.auth.poll` / `provider.auth.submit`.
class AuthPollDto {
  final AuthPollStatus status;
  final String? error;
  final bool authenticated;
  final int? interval;

  const AuthPollDto({
    required this.status,
    this.error,
    this.authenticated = false,
    this.interval,
  });

  factory AuthPollDto.fromJson(Map<String, dynamic> json) {
    final raw = (json['status'] ?? '').toString();
    final status = switch (raw) {
      'pending' => AuthPollStatus.pending,
      'approved' => AuthPollStatus.approved,
      'expired' => AuthPollStatus.expired,
      'error' => AuthPollStatus.error,
      'cancelled' => AuthPollStatus.cancelled,
      _ => AuthPollStatus.unknown,
    };
    return AuthPollDto(
      status: status,
      error: json['error']?.toString(),
      authenticated: (json['authenticated'] as bool?) ?? status == AuthPollStatus.approved,
      interval: json['interval'] is int
          ? json['interval'] as int
          : int.tryParse(json['interval']?.toString() ?? ''),
    );
  }
}
