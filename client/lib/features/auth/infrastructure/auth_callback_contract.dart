class AuthLoginCancelledException implements Exception {
  const AuthLoginCancelledException();

  @override
  String toString() => 'Login cancelled by user.';
}

class AuthCallbackResult {
  final String code;
  final String state;

  const AuthCallbackResult({required this.code, required this.state});
}

abstract class AuthCallbackBinding {
  String get clientId;
  String get redirectUri;
  Future<AuthCallbackResult> waitForResult(Duration timeout);
  Future<void> cancel();
  Future<void> dispose();
}
