import 'auth_session.dart';

abstract class IAuthRepository {
  Future<AuthSession?> restoreSession();
  Future<AuthSession?> synchronizeExternalSession();
  Future<AuthSession?> login();
  Future<void> logout();
  Future<AuthSession?> refreshSession();
  Future<AuthSession?> fetchCredits();
  void cancelLogin();
}
