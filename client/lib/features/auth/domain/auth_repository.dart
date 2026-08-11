import 'auth_session.dart';

abstract class IAuthRepository {
  Future<AuthSession?> restoreSession();
  Future<AuthSession?> synchronizeExternalSession();
  Future<AuthSession?> login({void Function()? onCompleting});
  Future<void> logout();
  Future<AuthSession?> refreshSession();
  Future<AuthSession?> fetchCredits();
  void cancelLogin();
}
