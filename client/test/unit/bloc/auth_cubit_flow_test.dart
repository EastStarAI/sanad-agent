import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/domain/auth_session.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restores, logs in, and logs out through the auth repository', () async {
    final repository = _FakeAuthRepository();
    final cubit = AuthCubit(authRepository: repository);

    await cubit.init();
    expect(cubit.state, isA<AuthUnauthenticated>());

    await cubit.login();
    final authenticated = cubit.state as AuthAuthenticated;
    expect(authenticated.accessToken, 'access-token');
    expect(authenticated.userId, 'user-1');

    await cubit.logout();
    expect(cubit.state, isA<AuthUnauthenticated>());
    expect(repository.loggedOut, isTrue);

    await cubit.close();
  });

  test('cancelLogin emits AuthUnauthenticated and cancels session login', () async {
    final repository = _FakeAuthRepository();
    final cubit = AuthCubit(authRepository: repository);

    cubit.cancelLogin();
    expect(cubit.state, isA<AuthUnauthenticated>());
    expect(repository.loginCancelled, isTrue);

    await cubit.close();
  });

  test('terminal session invalidation updates presentation without a second logout', () async {
    final repository = _FakeAuthRepository();
    final cubit = AuthCubit(authRepository: repository);

    await cubit.login();
    cubit.invalidateRejectedSession();

    expect(cubit.state, isA<AuthUnauthenticated>());
    expect(repository.loggedOut, isFalse);

    await cubit.close();
  });
}

class _FakeAuthRepository implements IAuthRepository {
  bool loggedOut = false;
  bool loginCancelled = false;

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<AuthSession?> login() async => const AuthSession(
    username: 'Test User',
    email: 'test@example.com',
    userId: 'user-1',
    accessToken: 'access-token',
    userCredits: 10,
    totalCredits: 20,
  );

  @override
  Future<void> logout() async {
    loggedOut = true;
  }

  @override
  Future<AuthSession?> refreshSession() async => null;

  @override
  Future<AuthSession?> fetchCredits() async => null;

  @override
  void cancelLogin() {
    loginCancelled = true;
  }
}
