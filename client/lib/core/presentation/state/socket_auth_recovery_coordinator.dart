import 'dart:async';

import 'package:sanad_client/features/auth/domain/auth_refresh_result.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

enum SessionRecoveryState { idle, reconnecting, refreshing, stale }

enum _PendingRecovery { none, refresh, terminal }

class SocketAuthRecoveryCoordinator {
  static const resumeDebounce = Duration(milliseconds: 500);
  static const authFailureCooldown = Duration(seconds: 2);

  final AuthService authService;
  final SanadSocketService socketService;

  final _stateController = StreamController<SessionRecoveryState>.broadcast();
  Stream<SessionRecoveryState> get states => _stateController.stream;

  StreamSubscription<Map<String, dynamic>>? _authFailureSubscription;
  StreamSubscription<SocketLifecycleState>? _lifecycleSubscription;
  Future<void>? _recoveryFuture;
  Timer? _resumeDebounceTimer;
  DateTime? _lastAuthRecoveryAt;
  _PendingRecovery _pendingRecovery = _PendingRecovery.none;
  bool _resumeReconnectInFlight = false;
  bool _refreshedReconnectInFlight = false;
  bool _disposed = false;

  SocketAuthRecoveryCoordinator({
    required this.authService,
    required this.socketService,
  });

  void start() {
    _authFailureSubscription ??= socketService.onAuthFailure.listen((_) {
      if (_refreshedReconnectInFlight) {
        _pendingRecovery = _PendingRecovery.terminal;
        return;
      }
      if (_resumeReconnectInFlight) {
        _pendingRecovery = _PendingRecovery.refresh;
        return;
      }

      final now = DateTime.now();
      final previous = _lastAuthRecoveryAt;
      if (previous != null && now.difference(previous) < authFailureCooldown) {
        return;
      }
      _lastAuthRecoveryAt = now;
      unawaited(recover().catchError((_) {}));
    });
    _lifecycleSubscription ??= socketService.lifecycleStateStream.listen((
      state,
    ) {
      if (state == SocketLifecycleState.ready) {
        _lastAuthRecoveryAt = null;
        _emit(SessionRecoveryState.idle);
      }
    });
  }

  /// Called when the app becomes active. Re-authenticating the socket also
  /// triggers the existing authoritative device/session/history hydration
  /// listeners after `auth_success`.
  void onAppResumed() {
    if (_disposed || !authService.isAuthenticated) return;
    _lastAuthRecoveryAt = null;
    _resumeDebounceTimer?.cancel();
    _resumeDebounceTimer = Timer(resumeDebounce, () {
      unawaited(reconnectForResume().catchError((_) {}));
    });
  }

  Future<void> reconnectForResume() {
    return _singleFlight(() async {
      _resumeReconnectInFlight = true;
      _emit(SessionRecoveryState.reconnecting);
      try {
        await socketService.reconnect();
      } catch (_) {
        // Keep cached state and credentials. Socket.IO/native reachability will
        // provide a later retry signal when connectivity returns.
        _emit(SessionRecoveryState.stale);
      } finally {
        _resumeReconnectInFlight = false;
      }
    });
  }

  Future<void> recover() {
    return _singleFlight(() async {
      _emit(SessionRecoveryState.refreshing);
      final result = await authService.refreshAccessToken();
      switch (result.outcome) {
        case AuthRefreshOutcome.success:
          socketService.setAccessToken(result.accessToken);
          _refreshedReconnectInFlight = true;
          try {
            await socketService.reconnect();
          } catch (_) {
            _emit(SessionRecoveryState.stale);
          } finally {
            _refreshedReconnectInFlight = false;
          }
          return;
        case AuthRefreshOutcome.terminalRejected:
          await _terminateSession();
          return;
        case AuthRefreshOutcome.transientUnavailable:
          // A timeout, offline state, DNS failure, or 5xx/503 is not evidence
          // that the credential was revoked. Keep both credentials and cache.
          _emit(SessionRecoveryState.stale);
          return;
      }
    });
  }

  Future<void> _singleFlight(Future<void> Function() operation) async {
    if (_recoveryFuture != null) {
      return _recoveryFuture!;
    }

    _recoveryFuture = operation();
    try {
      await _recoveryFuture!;
    } finally {
      _recoveryFuture = null;
      _drainPendingRecovery();
    }
  }

  Future<void> _terminateSession() async {
    socketService.disconnect();
    socketService.setAccessToken(null);
    await authService.logout();
    _emit(SessionRecoveryState.idle);
  }

  void _drainPendingRecovery() {
    if (_disposed || _pendingRecovery == _PendingRecovery.none) return;
    final pending = _pendingRecovery;
    _pendingRecovery = _PendingRecovery.none;
    scheduleMicrotask(() {
      if (_disposed) return;
      switch (pending) {
        case _PendingRecovery.none:
          return;
        case _PendingRecovery.refresh:
          unawaited(recover().catchError((_) {}));
          return;
        case _PendingRecovery.terminal:
          unawaited(_terminateSession().catchError((_) {}));
          return;
      }
    });
  }

  void _emit(SessionRecoveryState state) {
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  void dispose() {
    _disposed = true;
    _resumeDebounceTimer?.cancel();
    unawaited(_authFailureSubscription?.cancel());
    unawaited(_lifecycleSubscription?.cancel());
    unawaited(_stateController.close());
  }
}
