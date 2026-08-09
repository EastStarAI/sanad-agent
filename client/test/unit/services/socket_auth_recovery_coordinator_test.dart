import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/state/socket_auth_recovery_coordinator.dart';
import 'package:sanad_client/features/auth/domain/auth_refresh_result.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';

import '../../mocks/mock_socket_service.dart';

class FakeAuthService extends AuthService {
  final _tokenController = StreamController<String?>.broadcast();
  String? _token;
  int refreshCalls = 0;
  int logoutCalls = 0;
  AuthRefreshResult refreshResult;
  Completer<void>? refreshGate;

  FakeAuthService({
    this.refreshResult = const AuthRefreshResult.success(
      'refreshed-access-token',
    ),
  }) {
    _token = 'existing-access-token';
  }

  @override
  Stream<String?> get accessTokenStream => _tokenController.stream;

  @override
  String? get accessToken => _token;

  @override
  bool get isAuthenticated => _token != null;

  @override
  Future<AuthRefreshResult> refreshAccessToken() async {
    refreshCalls += 1;
    await refreshGate?.future;
    if (refreshResult.isSuccess) {
      _token = refreshResult.accessToken;
      _tokenController.add(_token);
    }
    return refreshResult;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    _token = null;
    _tokenController.add(null);
  }

  @override
  Future<void> init({String? fallbackDeviceId}) async {}

  @override
  void dispose() {
    unawaited(_tokenController.close());
    super.dispose();
  }
}

class TrackingSocketService extends FakeSanadSocketService {
  int connectCalls = 0;
  int disconnectCalls = 0;
  int authFailuresRemaining = 0;
  final List<String?> seenTokens = [];

  TrackingSocketService() : super();

  @override
  void setAccessToken(String? token) {
    seenTokens.add(token);
    super.setAccessToken(token);
  }

  @override
  Future<void> connect() async {
    connectCalls += 1;
    if (authFailuresRemaining > 0) {
      authFailuresRemaining -= 1;
      debugEmitAuthFailure({'message': 'Invalid token'});
      throw StateError('Socket authentication failed');
    }
    setConnected(true);
  }

  @override
  void disconnect() {
    disconnectCalls += 1;
    setConnected(false);
  }
}

void main() {
  group('SocketAuthRecoveryCoordinator', () {
    late FakeAuthService authService;
    late TrackingSocketService socketService;
    late SocketAuthRecoveryCoordinator coordinator;

    setUp(() {
      authService = FakeAuthService();
      socketService = TrackingSocketService();
      coordinator = SocketAuthRecoveryCoordinator(
        authService: authService,
        socketService: socketService,
      )..start();
    });

    tearDown(() {
      coordinator.dispose();
      authService.dispose();
      socketService.dispose();
    });

    test('refreshes token and reconnects after socket auth failure', () async {
      socketService.debugEmitAuthFailure({'message': 'Invalid token'});

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(authService.refreshCalls, 1);
      expect(socketService.seenTokens, contains('refreshed-access-token'));
      expect(socketService.connectCalls, 1);
      expect(socketService.isConnected, isTrue);
    });

    test('logs out once only for terminal refresh rejection', () async {
      authService.refreshResult = const AuthRefreshResult.terminalRejected();

      socketService.debugEmitAuthFailure({'message': 'Invalid token'});

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(authService.refreshCalls, 1);
      expect(authService.logoutCalls, 1);
      expect(socketService.seenTokens, contains(null));
      expect(socketService.isConnected, isFalse);
    });

    test(
      'keeps credentials and cached connection state on transient failure',
      () async {
        authService.refreshResult = const AuthRefreshResult.transientUnavailable();

        socketService.debugEmitAuthFailure({
          'message': 'Authentication unavailable',
        });

        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(authService.refreshCalls, 1);
        expect(authService.logoutCalls, 0);
        expect(authService.isAuthenticated, isTrue);
        expect(socketService.seenTokens, isNot(contains(null)));
      },
    );

    test('rate-limits repeated auth failures after a transient result', () async {
      authService.refreshResult = const AuthRefreshResult.transientUnavailable();

      socketService.debugEmitAuthFailure({'message': 'Authentication unavailable'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      socketService.debugEmitAuthFailure({'message': 'Authentication unavailable'});
      await Future<void>.delayed(Duration.zero);

      expect(authService.refreshCalls, 1);
      expect(authService.logoutCalls, 0);
    });

    test(
      'coalesces concurrent auth failures into one refresh attempt',
      () async {
        authService.refreshGate = Completer<void>();
        final first = coordinator.recover();
        final second = coordinator.recover();
        await Future<void>.delayed(Duration.zero);

        expect(authService.refreshCalls, 1);

        authService.refreshGate!.complete();
        await Future.wait([first, second]);

        expect(socketService.connectCalls, 1);
      },
    );

    test('queues refresh when resume reconnect rejects an expired access token', () async {
      socketService.authFailuresRemaining = 1;

      await coordinator.reconnectForResume();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(authService.refreshCalls, 1);
      expect(authService.logoutCalls, 0);
      expect(socketService.connectCalls, 2);
      expect(socketService.isConnected, isTrue);
    });

    test('treats rejection of a freshly refreshed access token as terminal', () async {
      socketService.authFailuresRemaining = 1;

      await coordinator.recover();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(authService.refreshCalls, 1);
      expect(authService.logoutCalls, 1);
      expect(socketService.isConnected, isFalse);
    });

    test(
      'debounces resume and reconnects without rotating a valid credential',
      () async {
        coordinator.onAppResumed();
        coordinator.onAppResumed();

        await Future<void>.delayed(
          SocketAuthRecoveryCoordinator.resumeDebounce,
        );
        await Future<void>.delayed(Duration.zero);

        expect(authService.refreshCalls, 0);
        expect(socketService.connectCalls, 1);
      },
    );
  });
}
