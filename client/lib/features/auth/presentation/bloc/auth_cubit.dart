import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/domain/auth_session.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import 'auth_state.dart';

class AuthCubit extends Cubit<AuthState> {
  static final _logger = Logger('AuthCubit');
  final IAuthRepository _authRepository;

  AuthCubit({required IAuthRepository authRepository}) : _authRepository = authRepository, super(AuthInitial());

  Future<void> init() async {
    emit(AuthLoading());

    try {
      final session = await _authRepository.restoreSession();
      if (session == null) {
        emit(AuthUnauthenticated());
      } else {
        emit(_authenticated(session));
      }
    } catch (e) {
      _logger.warning('Failed to restore auth session: $e');
      emit(AuthUnauthenticated());
    }
  }

  Future<void> synchronizeExternalSession() async {
    try {
      final session = await _authRepository.synchronizeExternalSession();
      if (session == null) {
        emit(AuthUnauthenticated());
      } else {
        emit(_authenticated(session));
      }
    } catch (e) {
      _logger.warning('Failed to synchronize external auth session: $e');
    }
  }

  Future<void> login() async {
    emit(AuthLoading());
    try {
      final session = await _authRepository.login(
        onCompleting: () => emit(AuthCompleting()),
      );
      if (session == null) {
        emit(AuthUnauthenticated());
      } else {
        emit(_authenticated(session));
      }
    } catch (e) {
      _logger.severe('Login failed: $e');
      emit(AuthError(e.toString()));
      emit(AuthUnauthenticated());
    }
  }

  void cancelLogin() {
    _authRepository.cancelLogin();
    emit(AuthUnauthenticated());
  }

  Future<void> logout() async {
    await _authRepository.logout();
    emit(AuthUnauthenticated());
  }

  void invalidateRejectedSession() {
    if (state is AuthAuthenticated) {
      emit(AuthUnauthenticated());
    }
  }

  Future<void> fetchCredits() async {
    final currentState = state;
    if (currentState is! AuthAuthenticated) return;

    try {
      final session = await _authRepository.fetchCredits();
      if (session != null) {
        emit(_authenticated(session));
      }
    } catch (e) {
      _logger.warning('Failed to fetch credits: $e');
    }
  }

  AuthAuthenticated _authenticated(AuthSession session) {
    return AuthAuthenticated(
      username: session.username,
      displayName: session.displayName,
      email: session.email,
      userId: session.userId,
      accessToken: session.accessToken,
      userCredits: session.userCredits,
      totalCredits: session.totalCredits,
    );
  }
}
