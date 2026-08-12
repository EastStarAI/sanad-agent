import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/domain/auth_session.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';

class AuthRepositoryImpl implements IAuthRepository {
  final AuthService _authService;

  AuthRepositoryImpl(this._authService);

  @override
  Future<AuthSession?> restoreSession() async {
    await _authService.init();
    return _snapshot();
  }

  @override
  Future<AuthSession?> synchronizeExternalSession() async {
    await _authService.synchronizeDesktopAuthFile();
    return _snapshot();
  }

  @override
  Future<AuthSession?> login({void Function()? onCompleting}) async {
    await _authService.login(onCompleting: onCompleting);
    return _snapshot();
  }

  @override
  Future<void> logout() {
    return _authService.logout();
  }

  @override
  Future<AuthSession?> refreshSession() async {
    final result = await _authService.refreshAccessToken();
    if (!result.isSuccess) return null;
    await _authService.fetchProfile();
    return _snapshot();
  }

  @override
  Future<AuthSession?> fetchCredits() async {
    await _authService.fetchCredits();
    return _snapshot();
  }

  @override
  Future<void> cancelLogin() => _authService.cancelLogin();

  AuthSession? _snapshot() {
    final accessToken = _authService.accessToken;
    if (accessToken == null) return null;

    return AuthSession(
      username: _authService.username ?? 'User',
      displayName: _authService.displayName ?? _authService.username ?? 'User',
      email: _authService.email ?? '',
      userId: _authService.userId ?? '',
      accessToken: accessToken,
      userCredits: _authService.userCredits,
      totalCredits: _authService.totalCredits,
    );
  }
}
