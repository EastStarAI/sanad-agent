import 'dart:async';

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
    expect(authenticated.username, 'ahmedattia');
    expect(authenticated.displayName, 'Ahmed Attia');

    await cubit.logout();
    expect(cubit.state, isA<AuthUnauthenticated>());
    expect(repository.loggedOut, isTrue);

    await cubit.close();
  });

  test('shows completing state until co-located login finishes', () async {
    final release = Completer<void>();
    final repository = _FakeAuthRepository(completingRelease: release.future);
    final cubit = AuthCubit(authRepository: repository);
    final states = <AuthState>[];
    final subscription = cubit.stream.listen(states.add);

    final login = cubit.login();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state, isA<AuthCompleting>());

    release.complete();
    await login;
    expect(cubit.state, isA<AuthAuthenticated>());
    expect(states.whereType<AuthCompleting>(), hasLength(1));

    await subscription.cancel();
    await cubit.close();
  });

  test('external authentication exchange updates presentation state', () async {
    final repository = _FakeAuthRepository();
    final cubit = AuthCubit(authRepository: repository);

    await cubit.synchronizeExternalSession();

    expect(cubit.state, isA<AuthAuthenticated>());
    await cubit.close();
  });

  test(
    'cancelLogin emits AuthUnauthenticated and cancels session login',
    () async {
      final repository = _FakeAuthRepository();
      final cubit = AuthCubit(authRepository: repository);

    await cubit.cancelLogin();
    expect(cubit.state, isA<AuthUnauthenticated>());
      expect(repository.loginCancelled, isTrue);

      await cubit.close();
    },
  );

  test(
    'terminal session invalidation updates presentation without a second logout',
    () async {
      final repository = _FakeAuthRepository();
      final cubit = AuthCubit(authRepository: repository);

      await cubit.login();
      cubit.invalidateRejectedSession();

      expect(cubit.state, isA<AuthUnauthenticated>());
      expect(repository.loggedOut, isFalse);

      await cubit.close();
    },
  );
}

class _FakeAuthRepository implements IAuthRepository {
  _FakeAuthRepository({this.completingRelease});

  final Future<void>? completingRelease;
  bool loggedOut = false;
  bool loginCancelled = false;

  @override
  Future<AuthSession?> restoreSession() async => null;

  @override
  Future<AuthSession?> synchronizeExternalSession() async => login();

  @override
  Future<AuthSession?> login({void Function()? onCompleting}) async {
    final release = completingRelease;
    if (release != null) {
      onCompleting?.call();
      await release;
    }
    return const AuthSession(
      username: 'ahmedattia',
      displayName: 'Ahmed Attia',
      email: 'test@example.com',
      userId: 'user-1',
      accessToken: 'access-token',
      userCredits: 10,
      totalCredits: 20,
    );
  }

  @override
  Future<void> logout() async {
    loggedOut = true;
  }

  @override
  Future<AuthSession?> refreshSession() async => null;

  @override
  Future<AuthSession?> fetchCredits() async => null;

  @override
  Future<void> cancelLogin() async {
    loginCancelled = true;
  }
}
