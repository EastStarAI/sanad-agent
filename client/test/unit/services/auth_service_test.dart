import 'package:sanad_auth_lock/sanad_auth_lock.dart';
import 'package:sanad_client/features/auth/domain/auth_refresh_result.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_callback_contract.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/features/auth/infrastructure/portal_auth_client.dart';
import 'package:sanad_client/infrastructure/local_tools/sanad_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:sanad_client/utils/app_platform.dart';

class MockSanadSettingsStore extends Fake implements SanadSettingsStore {
  Map<String, dynamic> authDocument = {};
  Future<void> Function()? beforeNextLock;
  Object? nextLockError;

  @override
  Future<T> withAuthFileLock<T>(Future<T> Function() operation) async {
    final lockError = nextLockError;
    nextLockError = null;
    if (lockError != null) throw lockError;
    final beforeLock = beforeNextLock;
    beforeNextLock = null;
    await beforeLock?.call();
    return operation();
  }

  @override
  Future<Map<String, dynamic>> readAuthDocument() async => authDocument;

  @override
  Future<void> saveAuthDocument(Map<String, dynamic> data) async {
    authDocument = data;
  }

  @override
  Future<void> deleteAuthDocument() async {
    authDocument = {};
  }
}

class MockDio extends Fake implements Dio {
  @override
  BaseOptions options = BaseOptions();
  @override
  final interceptors = Interceptors();
}

class StubPortalAuthClient extends PortalAuthClient {
  PortalAuthRefresh? response;
  Object? error;
  int refreshCalls = 0;
  int redemptionCalls = 0;

  StubPortalAuthClient() : super(dio: MockDio());

  @override
  Future<PortalClientTransaction> createClientTransaction({
    required String clientId,
    required String redirectUri,
    required String codeChallenge,
  }) async {
    return const PortalClientTransaction(
      transactionId: 'expected-transaction',
      authorizationUrl: 'https://portal.test/authorize',
      expiresIn: 30,
    );
  }

  @override
  Future<PortalAuthTokens> redeemAuthorizationCode({
    required String clientId,
    required String redirectUri,
    required String code,
    required String codeVerifier,
  }) async {
    redemptionCalls += 1;
    return const PortalAuthTokens(
      accessToken: 'synthetic-access',
      refreshToken: 'synthetic-refresh',
      tokenType: 'bearer',
    );
  }

  @override
  Future<PortalAuthRefresh> refresh({required String refreshToken}) async {
    refreshCalls += 1;
    final failure = error;
    if (failure != null) throw failure;
    return response!;
  }

  @override
  Future<void> logout({String? accessToken, String? refreshToken}) async {}
}

class StubCallbackBinding implements AuthCallbackBinding {
  StubCallbackBinding(this.result);

  final AuthCallbackResult result;
  bool disposed = false;

  @override
  String get clientId => 'sanad_flutter_desktop';

  @override
  String get redirectUri => 'http://127.0.0.1:49152/oauth/callback';

  @override
  Future<AuthCallbackResult> waitForResult(Duration timeout) async => result;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuthService authService;
  late MockSanadSettingsStore mockStore;
  late SharedPreferences prefs;

  setUp(() async {
    AppPlatform.overrideIsDesktop = true;
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mockStore = MockSanadSettingsStore();
    authService = AuthService(
      dio: MockDio(),
      prefs: prefs,
      settingsStore: mockStore,
    );
  });

  tearDown(() {
    authService.dispose();
    AppPlatform.overrideIsDesktop = null;
  });

  group('AuthService SSoT Logic', () {
    test('init restores from auth.json if present', () async {
      mockStore.authDocument = {
        'access_token': 'file_token',
        'refresh_token': 'file_refresh',
        'hardware_id': 'file_device',
      };

      await authService.init();

      expect(authService.accessToken, equals('file_token'));
      expect(authService.hardwareId, equals('file_device'));
    });

    test(
      'external exchange reconciles login and logout without echoing',
      () async {
        mockStore.authDocument = {'hardware_id': 'device-1'};
        await authService.init();
        var exchangeCount = 0;
        final subscription = authService.authenticationExchangeStream.listen(
          (_) => exchangeCount += 1,
        );

        mockStore.authDocument = {
          'access_token': 'external-access',
          'refresh_token': 'external-refresh',
          'hardware_id': 'device-1',
        };
        await authService.synchronizeDesktopAuthFile();
        expect(authService.accessToken, 'external-access');

        mockStore.authDocument = {'hardware_id': 'device-1'};
        await authService.synchronizeDesktopAuthFile();
        expect(authService.accessToken, isNull);
        expect(exchangeCount, 0);

        await subscription.cancel();
      },
    );

    test('atomic auth session value overrides legacy credential mirrors', () async {
      await prefs.setString(
        'backend_auth_session_v1',
        '{"access_token":"atomic-access","refresh_token":"atomic-refresh"}',
      );
      await prefs.setString('backend_access_token', 'legacy-access');
      await prefs.setString('backend_refresh_token', 'legacy-refresh');

      await authService.init(fallbackDeviceId: 'device-1');

      expect(authService.accessToken, 'atomic-access');
      expect(mockStore.authDocument['access_token'], 'atomic-access');
      expect(mockStore.authDocument['refresh_token'], 'atomic-refresh');
    });

    test(
      'init uses the canonical desktop hardware id when auth is restored from preferences',
      () async {
        await prefs.setString('backend_access_token', 'prefs_token');
        await prefs.setString('backend_refresh_token', 'prefs_refresh');
        await prefs.setString('hardware_id', 'stale_prefs_device');

        await authService.init(fallbackDeviceId: 'canonical_device');

        expect(authService.accessToken, equals('prefs_token'));
        expect(authService.hardwareId, equals('canonical_device'));

        expect(mockStore.authDocument['access_token'], equals('prefs_token'));
        expect(
          mockStore.authDocument['hardware_id'],
          equals('canonical_device'),
        );
      },
    );

    test('wrong callback state is rejected before code redemption', () async {
      final portal = StubPortalAuthClient();
      final callback = StubCallbackBinding(
        const AuthCallbackResult(
          code: 'copied-code',
          state: 'attacker-transaction',
        ),
      );
      authService.dispose();
      authService = AuthService(
        dio: MockDio(),
        prefs: prefs,
        settingsStore: mockStore,
        portalAuth: portal,
        callbackBindingFactory: () async => callback,
        authorizationLauncher: (_) async => true,
      );

      await expectLater(authService.login(), throwsStateError);

      expect(portal.redemptionCalls, 0);
      expect(authService.accessToken, isNull);
      expect(callback.disposed, isTrue);
      expect(prefs.getString('backend_access_token'), isNull);
    });

    test('logout clears tokens but preserves hardware_id', () async {
      mockStore.authDocument = {
        'access_token': 'test_token',
        'refresh_token': 'test_refresh',
        'hardware_id': 'test_hardware',
      };
      await prefs.setString('backend_access_token', 'test_token');
      await prefs.setString('backend_refresh_token', 'test_refresh');
      final exchange = authService.authenticationExchangeStream.first;

      await authService.logout();
      await exchange;

      expect(mockStore.authDocument['access_token'], isNull);
      expect(mockStore.authDocument['refresh_token'], isNull);
      expect(mockStore.authDocument['hardware_id'], equals('test_hardware'));
      expect(prefs.getString('backend_access_token'), isNull);
      expect(prefs.getString('backend_refresh_token'), isNull);
    });

    test(
      'persists a rotated credential pair after successful refresh',
      () async {
        final portal = StubPortalAuthClient()
          ..response = const PortalAuthRefresh(
            accessToken: 'rotated-access',
            refreshToken: 'rotated-refresh',
            tokenType: 'bearer',
          );
        authService.dispose();
        authService = AuthService(
          dio: MockDio(),
          prefs: prefs,
          settingsStore: mockStore,
          portalAuth: portal,
        );
        mockStore.authDocument = {
          'access_token': 'old-access',
          'refresh_token': 'old-refresh',
          'hardware_id': 'device-1',
        };
        await authService.init();
        final exchange = authService.authenticationExchangeStream.first;

        final result = await authService.refreshAccessToken();
        await exchange;

        expect(result.outcome, AuthRefreshOutcome.success);
        expect(result.accessToken, 'rotated-access');
        expect(prefs.getString('backend_access_token'), 'rotated-access');
        expect(prefs.getString('backend_refresh_token'), 'rotated-refresh');
        expect(mockStore.authDocument['access_token'], 'rotated-access');
        expect(mockStore.authDocument['refresh_token'], 'rotated-refresh');
      },
    );

    test(
      'adopts credentials rotated while waiting for the desktop lock',
      () async {
        final portal = StubPortalAuthClient();
        authService.dispose();
        authService = AuthService(
          dio: MockDio(),
          prefs: prefs,
          settingsStore: mockStore,
          portalAuth: portal,
        );
        mockStore.authDocument = {
          'access_token': 'old-access',
          'refresh_token': 'old-refresh',
          'hardware_id': 'device-1',
        };
        await authService.init();
        mockStore.beforeNextLock = () async {
          mockStore.authDocument = {
            'access_token': 'peer-access',
            'refresh_token': 'peer-refresh',
            'hardware_id': 'device-1',
          };
          // Model an exchange notification arriving while this refresh waits.
          await authService.synchronizeDesktopAuthFile();
        };

        final result = await authService.refreshAccessToken();

        expect(result.outcome, AuthRefreshOutcome.success);
        expect(result.accessToken, 'peer-access');
        expect(authService.accessToken, 'peer-access');
        expect(portal.refreshCalls, 0);
        expect(prefs.getString('backend_refresh_token'), 'peer-refresh');
      },
    );

    test(
      'treats desktop lock timeout as transient without clearing credentials',
      () async {
        mockStore.authDocument = {
          'access_token': 'old-access',
          'refresh_token': 'old-refresh',
          'hardware_id': 'device-1',
        };
        await authService.init();
        mockStore.nextLockError = const AuthFileLockTimeout(
          Duration(seconds: 15),
        );

        final result = await authService.refreshAccessToken();

        expect(result.outcome, AuthRefreshOutcome.transientUnavailable);
        expect(authService.accessToken, 'old-access');
        expect(mockStore.authDocument['refresh_token'], 'old-refresh');
      },
    );

    test(
      'classifies portal 401 as terminal rejection without clearing credentials',
      () async {
        final portal = StubPortalAuthClient()
          ..error = DioException(
            requestOptions: RequestOptions(path: '/auth/refresh'),
            response: Response<void>(
              requestOptions: RequestOptions(path: '/auth/refresh'),
              statusCode: 401,
            ),
          );
        authService.dispose();
        authService = AuthService(
          dio: MockDio(),
          prefs: prefs,
          settingsStore: mockStore,
          portalAuth: portal,
        );
        mockStore.authDocument = {
          'access_token': 'old-access',
          'refresh_token': 'old-refresh',
          'hardware_id': 'device-1',
        };
        await authService.init();

        final result = await authService.refreshAccessToken();

        expect(result.outcome, AuthRefreshOutcome.terminalRejected);
        expect(prefs.getString('backend_refresh_token'), 'old-refresh');
      },
    );

    test(
      'classifies timeout and 503 as transient without clearing credentials',
      () async {
        for (final failure in <DioException>[
          DioException(
            requestOptions: RequestOptions(path: '/auth/refresh'),
            type: DioExceptionType.connectionTimeout,
          ),
          DioException(
            requestOptions: RequestOptions(path: '/auth/refresh'),
            response: Response<void>(
              requestOptions: RequestOptions(path: '/auth/refresh'),
              statusCode: 503,
            ),
          ),
        ]) {
          final portal = StubPortalAuthClient()..error = failure;
          authService.dispose();
          authService = AuthService(
            dio: MockDio(),
            prefs: prefs,
            settingsStore: mockStore,
            portalAuth: portal,
          );
          mockStore.authDocument = {
            'access_token': 'old-access',
            'refresh_token': 'old-refresh',
            'hardware_id': 'device-1',
          };
          await authService.init();

          final result = await authService.refreshAccessToken();

          expect(result.outcome, AuthRefreshOutcome.transientUnavailable);
          expect(prefs.getString('backend_access_token'), 'old-access');
          expect(prefs.getString('backend_refresh_token'), 'old-refresh');
        }
      },
    );
  });
}
