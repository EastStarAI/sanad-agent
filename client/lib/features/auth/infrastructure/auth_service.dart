import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:dio/dio.dart';
import 'package:sanad_auth_lock/sanad_auth_lock.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/core/config/app_config.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

import 'package:sanad_client/infrastructure/local_tools/sanad_settings_store.dart';
import 'package:sanad_client/infrastructure/web_auth_popup_service_stub.dart'
    if (dart.library.html) 'package:sanad_client/infrastructure/web_auth_popup_service.dart';
import 'package:sanad_client/features/auth/domain/auth_refresh_result.dart';
import 'package:sanad_client/features/auth/infrastructure/portal_auth_client.dart';
import 'package:sanad_client/features/auth/infrastructure/colocated_auth_coupling_client.dart';
import 'package:sanad_client/features/auth/domain/user_display_name.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_callback_binding.dart';
import 'package:url_launcher/url_launcher.dart';

class AuthLoginChallenge {
  /// Short code the user types into the portal (CLI/headless fallback only).
  /// Empty on desktop/web/mobile where the portal can bind the browser session
  /// directly to the auth session.
  final String userCode;
  final String authUrl;
  final int expiresIn;

  const AuthLoginChallenge({
    required this.userCode,
    required this.authUrl,
    required this.expiresIn,
  });
}

Future<bool> _launchPortalAuthorization(Uri uri) async {
  if (kIsWeb) {
    return WebAuthPopupService.instance.openAuthPopup(uri.toString());
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

class AuthService {
  static final _logger = Logger('AuthService');
  static const _authSessionKey = 'backend_auth_session_v1';
  static const _pendingAgentLogoutKey = 'agent_logout_pending';
  int _loginAttempt = 0;
  AuthCallbackBinding? _activeLoginCallback;
  ColocatedEnrollmentRequest? _activeColocatedEnrollment;
  bool _isPolling = false;
  final Dio _dio;
  final SanadSettingsStore _settingsStore;
  final SharedPreferences? _prefs;
  final PortalAuthClient _portalAuth;
  final ColocatedAuthCouplingClient _colocatedCoupling;
  final Future<AuthCallbackBinding> Function() _callbackBindingFactory;
  final Future<bool> Function(Uri uri) _authorizationLauncher;
  final _accessTokenController = StreamController<String?>.broadcast();
  final _authenticationExchangeController = StreamController<void>.broadcast();
  final _loginChallengeController = StreamController<AuthLoginChallenge?>.broadcast();
  Future<AuthRefreshResult>? _refreshFuture;

  String? _backendAccessToken;
  String? _backendRefreshToken;
  String? _hardwareId;
  AuthLoginChallenge? _loginChallenge;
  String? username;
  String? displayName;
  String? email;
  String? userId;

  double userCredits = 0.0;
  double totalCredits = 0.0;

  bool get isAuthenticated => _backendAccessToken != null;
  bool get isPolling => _isPolling;
  String? get accessToken => _backendAccessToken;
  String? get hardwareId => _hardwareId;
  Stream<String?> get accessTokenStream => _accessTokenController.stream;
  Stream<void> get authenticationExchangeStream => _authenticationExchangeController.stream;
  AuthLoginChallenge? get loginChallenge => _loginChallenge;
  Stream<AuthLoginChallenge?> get loginChallengeStream => _loginChallengeController.stream;

  AuthService({
    Dio? dio,
    SanadSettingsStore? settingsStore,
    SharedPreferences? prefs,
    PortalAuthClient? portalAuth,
    ColocatedAuthCouplingClient? colocatedCoupling,
    Future<AuthCallbackBinding> Function()? callbackBindingFactory,
    Future<bool> Function(Uri uri)? authorizationLauncher,
  }) : _dio =
           dio ??
           (Dio()
             ..options.connectTimeout = const Duration(seconds: 3)
             ..options.receiveTimeout = const Duration(seconds: 3)),
       _settingsStore = settingsStore ?? const SanadSettingsStore(),
       _prefs = prefs,
       _portalAuth = portalAuth ?? PortalAuthClient(),
       _colocatedCoupling = colocatedCoupling ?? ColocatedAuthCouplingClient(),
       _callbackBindingFactory = callbackBindingFactory ?? createAuthCallbackBinding,
       _authorizationLauncher = authorizationLauncher ?? _launchPortalAuthorization {
    _setupInterceptors();
  }

  Future<SharedPreferences> _getPrefs() async {
    return _prefs ?? SharedPreferences.getInstance();
  }

  (String?, String?) _readStoredAuthSession(SharedPreferences prefs) {
    final encoded = prefs.getString(_authSessionKey);
    if (encoded != null) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map) {
          final accessToken = decoded['access_token']?.toString();
          final refreshToken = decoded['refresh_token']?.toString();
          if (accessToken?.isNotEmpty == true || refreshToken?.isNotEmpty == true) {
            return (accessToken, refreshToken);
          }
        }
      } on FormatException {
        _logger.warning('Ignoring malformed persisted auth session.');
      }
    }
    return (
      prefs.getString('backend_access_token'),
      prefs.getString('backend_refresh_token'),
    );
  }

  Future<void> _persistAuthPair(
    SharedPreferences prefs, {
    required String accessToken,
    required String? refreshToken,
  }) async {
    await prefs.setString(
      _authSessionKey,
      jsonEncode({'access_token': accessToken, 'refresh_token': refreshToken}),
    );
    try {
      await prefs.setString('backend_access_token', accessToken);
      if (refreshToken == null || refreshToken.isEmpty) {
        await prefs.remove('backend_refresh_token');
      } else {
        await prefs.setString('backend_refresh_token', refreshToken);
      }
    } catch (error) {
      _logger.warning(
        'Failed to update legacy auth mirrors: ${error.runtimeType}',
      );
    }
  }

  void _setupInterceptors() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (DioException error, ErrorInterceptorHandler handler) async {
          if (error.response?.statusCode == 401) {
            if (_backendRefreshToken == null || _backendRefreshToken!.isEmpty) {
              await logout();
              return handler.next(error);
            }
            final alreadyRetried = error.requestOptions.extra['auth_refresh_retried'] == true;
            if (alreadyRetried) {
              await logout();
              return handler.next(error);
            }

            _logger.info('401 detected. Attempting to refresh token...');
            final refreshResult = await refreshAccessToken();
            if (refreshResult.isSuccess) {
              final opts = error.requestOptions;
              opts.headers['Authorization'] = 'Bearer ${refreshResult.accessToken}';
              opts.extra['auth_refresh_retried'] = true;
              try {
                final retriedResponse = await _dio.fetch(opts);
                return handler.resolve(retriedResponse);
              } catch (_) {
                return handler.next(error);
              }
            }
            if (refreshResult.isTerminal) {
              await logout();
            }
          }
          return handler.next(error);
        },
      ),
    );
  }

  Future<void> init({String? fallbackDeviceId}) async {
    final prefs = await _getPrefs();

    if (AppPlatform.isDesktop) {
      try {
        final restored = await _settingsStore.withAuthFileLock(() async {
          final authDoc = await _settingsStore.readAuthDocument();
          final String? token = authDoc['access_token'];
          final String? refreshToken = authDoc['refresh_token'];
          final String? hardwareId = authDoc['hardware_id']?.toString();
          if (token == null && hardwareId == null) return false;

          _logger.info('Restored auth from auth.json');
          _backendAccessToken = token;
          _backendRefreshToken = refreshToken;
          _hardwareId = hardwareId;
          if (token != null) {
            await prefs.setString('backend_access_token', token);
          }
          if (refreshToken != null) {
            await prefs.setString('backend_refresh_token', refreshToken);
          }
          if (hardwareId != null) {
            await prefs.setString('hardware_id', hardwareId);
          }
          await _syncAuthToFileUnlocked();
          return true;
        });
        if (restored) {
          if (_backendAccessToken != null) {
            await fetchProfile();
            _emitAccessToken();
          }
          return;
        }
      } catch (e) {
        _logger.warning(
          'Failed to load auth from file on desktop, using SharedPreferences: $e',
        );
      }
    }

    final storedSession = _readStoredAuthSession(prefs);
    _backendAccessToken = storedSession.$1;
    _backendRefreshToken = storedSession.$2;
    _hardwareId = AppPlatform.isDesktop ? fallbackDeviceId : prefs.getString('hardware_id') ?? fallbackDeviceId;

    if (_backendAccessToken != null) {
      if (AppPlatform.isDesktop) {
        await _syncAuthToFile();
      }
      await fetchProfile();
      _emitAccessToken();
    }
  }

  /// Reconciles native desktop memory with the shared auth document.
  /// Incoming exchange notifications call this method; it never emits another
  /// exchange notification, preventing an event loop between client and daemon.
  Future<void> synchronizeDesktopAuthFile() async {
    if (!AppPlatform.isDesktop) return;
    await _settingsStore.withAuthFileLock(_synchronizeDesktopAuthFileUnlocked);
  }

  Future<void> _synchronizeDesktopAuthFileUnlocked() async {
    final authDoc = await _settingsStore.readAuthDocument();
    final nextAccessToken = authDoc['access_token']?.toString();
    final nextRefreshToken = authDoc['refresh_token']?.toString();
    final nextHardwareId = authDoc['hardware_id']?.toString();
    final accessChanged = nextAccessToken != _backendAccessToken;
    final refreshChanged = nextRefreshToken != _backendRefreshToken;

    if (!accessChanged && !refreshChanged) {
      if (nextHardwareId != null && nextHardwareId.isNotEmpty) {
        _hardwareId = nextHardwareId;
      }
      return;
    }

    _backendAccessToken = nextAccessToken?.isNotEmpty == true ? nextAccessToken : null;
    _backendRefreshToken = nextRefreshToken?.isNotEmpty == true ? nextRefreshToken : null;
    if (nextHardwareId != null && nextHardwareId.isNotEmpty) {
      _hardwareId = nextHardwareId;
    }

    final prefs = await _getPrefs();
    if (_backendAccessToken == null) {
      await prefs.remove(_authSessionKey);
      await prefs.remove('backend_access_token');
      await prefs.remove('backend_refresh_token');
      username = null;
      displayName = null;
      email = null;
      userId = null;
      userCredits = 0.0;
      totalCredits = 0.0;
    } else {
      await _persistAuthPair(
        prefs,
        accessToken: _backendAccessToken!,
        refreshToken: _backendRefreshToken,
      );
      if (accessChanged) {
        await fetchProfile();
      }
    }
    _emitAccessToken();
  }

  Future<void> _syncAuthToFile() async {
    if (!AppPlatform.isDesktop) return;
    await _settingsStore.withAuthFileLock(_syncAuthToFileUnlocked);
  }

  Future<void> _syncAuthToFileUnlocked() async {
    if (!AppPlatform.isDesktop) return;
    try {
      final existing = await _settingsStore.readAuthDocument();
      final next = Map<String, dynamic>.from(existing);
      if (_backendAccessToken != null) {
        next['access_token'] = _backendAccessToken;
      }
      if (_backendRefreshToken != null) {
        next['refresh_token'] = _backendRefreshToken;
      }
      if (_hardwareId != null) next['hardware_id'] = _hardwareId;
      await _settingsStore.saveAuthDocument(next);
    } catch (e) {
      _logger.warning('Failed to sync auth to file: $e');
    }
  }

  Future<void> syncExternalSession(String accessToken) async {
    if (_backendAccessToken == accessToken && isAuthenticated) return;

    final prefs = await _getPrefs();
    _backendAccessToken = accessToken;
    _backendRefreshToken = _readStoredAuthSession(prefs).$2;
    await fetchProfile();
    _emitAccessToken();
  }

  Future<void> cancelLogin() async {
    _loginAttempt += 1;
    final callback = _activeLoginCallback;
    _activeLoginCallback = null;
    _setLoginChallenge(null);
    await callback?.cancel();
    final enrollment = _activeColocatedEnrollment;
    _activeColocatedEnrollment = null;
    if (enrollment != null) {
      await _colocatedCoupling.cancel();
    } else {
      try {
        await _colocatedCoupling.cancel();
      } catch (_) {
        // An absent optional Local Agent has no enrollment to invalidate.
      }
    }
    _logger.info('Login flow cancelled by user.');
  }

  Future<void> login({void Function()? onCompleting}) async {
    final attempt = ++_loginAttempt;
    _isPolling = true;
    try {
      // Plan 23: a single unified portal-driven flow for all platforms. The
      // portal decides whether a user_code is needed (CLI/headless only).
      await _loginViaPortal(attempt: attempt, onCompleting: onCompleting);
    } on AuthLoginCancelledException {
      return;
    } catch (e) {
      _logger.severe('Login failed: $e');
      if (kIsWeb) {
        WebAuthPopupService.instance.closePopup();
      }
      rethrow;
    } finally {
      if (attempt == _loginAttempt) {
        _isPolling = false;
        _setLoginChallenge(null);
      }
      if (kIsWeb) {
        WebAuthPopupService.instance.dispose();
      } else if (!AppPlatform.isMobile) {
        try {
          await closeInAppWebView();
        } catch (e) {
          _logger.warning('Failed to close in-app webview: $e');
        }
      }
    }
  }

  Future<void> _loginViaPortal({
    required int attempt,
    void Function()? onCompleting,
  }) async {
    final callback = await _callbackBindingFactory();
    if (attempt != _loginAttempt) {
      await callback.dispose();
      throw const AuthLoginCancelledException();
    }
    _activeLoginCallback = callback;
    try {
      final enrollment = await _colocatedCoupling.start();
      _activeColocatedEnrollment = enrollment;
      _ensureActiveLoginAttempt(attempt);
      final random = Random.secure();
      final verifierBytes = List<int>.generate(64, (_) => random.nextInt(256));
      final verifier = base64Url.encode(verifierBytes).replaceAll('=', '');
      final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');

      final transaction = await _portalAuth.createClientTransaction(
        clientId: callback.clientId,
        redirectUri: callback.redirectUri,
        codeChallenge: challenge,
        enrollmentRequestId: enrollment?.requestId,
      );
      _setLoginChallenge(
        AuthLoginChallenge(
          userCode: '',
          authUrl: transaction.authorizationUrl,
          expiresIn: transaction.expiresIn,
        ),
      );

      final launched = await _authorizationLauncher(
        Uri.parse(transaction.authorizationUrl),
      );
      if (!launched) {
        throw StateError(
          kIsWeb ? 'Popup was blocked. Allow popups and try again.' : 'Could not open the system browser.',
        );
      }

      final result = await callback.waitForResult(
        Duration(seconds: transaction.expiresIn),
      );
      _ensureActiveLoginAttempt(attempt);
      if (result.state != transaction.transactionId) {
        throw StateError('Authentication callback state mismatch.');
      }
      final tokens = await _portalAuth.redeemAuthorizationCode(
        clientId: callback.clientId,
        redirectUri: callback.redirectUri,
        code: result.code,
        codeVerifier: verifier,
      );
      _ensureActiveLoginAttempt(attempt);

      Future<void> persistLogin() async {
        _backendAccessToken = tokens.accessToken;
        _backendRefreshToken = tokens.refreshToken;
        final prefs = await _getPrefs();
        await _persistAuthPair(
          prefs,
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
        );
        await _syncAuthToFileUnlocked();
      }

      if (AppPlatform.isDesktop) {
        await _settingsStore.withAuthFileLock(persistLogin);
      } else {
        await persistLogin();
      }
      if (enrollment != null) {
        onCompleting?.call();
        await _colocatedCoupling.waitForCompletion(enrollment);
        if (identical(_activeColocatedEnrollment, enrollment)) {
          _activeColocatedEnrollment = null;
        }
      }
      _emitAuthenticationExchange();
      await fetchProfile();
      _emitAccessToken();
      _setLoginChallenge(null);
    } catch (_) {
      final enrollment = _activeColocatedEnrollment;
      if (enrollment != null && attempt == _loginAttempt) {
        _activeColocatedEnrollment = null;
        await _colocatedCoupling.cancel();
      }
      rethrow;
    } finally {
      if (identical(_activeLoginCallback, callback)) {
        _activeLoginCallback = null;
      }
      await callback.dispose();
    }
  }

  void _ensureActiveLoginAttempt(int attempt) {
    if (attempt != _loginAttempt) {
      throw const AuthLoginCancelledException();
    }
  }

  void _setLoginChallenge(AuthLoginChallenge? challenge) {
    _loginChallenge = challenge;
    if (!_loginChallengeController.isClosed) {
      _loginChallengeController.add(challenge);
    }
  }

  Future<void> logout() async {
    var refreshToken = _backendRefreshToken;
    var accessToken = _backendAccessToken;

    if (AppPlatform.isDesktop) {
      try {
        await _settingsStore.withAuthFileLock(() async {
          final existing = await _settingsStore.readAuthDocument();
          accessToken = existing['access_token']?.toString() ?? accessToken;
          refreshToken = existing['refresh_token']?.toString() ?? refreshToken;
          final next = Map<String, dynamic>.from(existing)
            ..remove('access_token')
            ..remove('refresh_token')
            ..remove('device_token')
            ..remove('pairing_token')
            ..remove('pending_device_token')
            ..[_pendingAgentLogoutKey] = true;
          await _settingsStore.saveAuthDocument(next);
        });
        _emitAuthenticationExchange();
      } catch (error) {
        _logger.warning(
          'Desktop logout file cleanup failed: ${error.runtimeType}',
        );
      }
    }

    _backendAccessToken = null;
    _backendRefreshToken = null;
    userCredits = 0.0;
    username = null;
    displayName = null;
    email = null;
    userId = null;

    final prefs = await _getPrefs();
    await prefs.remove(_authSessionKey);
    await prefs.remove('backend_access_token');
    await prefs.remove('backend_refresh_token');
    _emitAccessToken();

    if (AppPlatform.isDesktop) {
      unawaited(_colocatedCoupling.logoutAgent());
    }
    if (refreshToken != null || accessToken != null) {
      unawaited(
        _portalAuth.logout(
          accessToken: accessToken,
          refreshToken: refreshToken,
        ),
      );
    }
  }

  Future<AuthRefreshResult> refreshAccessToken() async {
    if (_refreshFuture != null) {
      return _refreshFuture!;
    }

    _refreshFuture = _refreshAccessTokenInternal();
    try {
      return await _refreshFuture!;
    } finally {
      _refreshFuture = null;
    }
  }

  Future<AuthRefreshResult> _refreshAccessTokenInternal() async {
    if (!AppPlatform.isDesktop) {
      return _refreshAccessTokenWithCurrentCredentials();
    }
    final accessBeforeLock = _backendAccessToken;
    final refreshBeforeLock = _backendRefreshToken;
    try {
      return await _settingsStore.withAuthFileLock(
        () => _refreshAccessTokenWithCurrentCredentials(
          accessBeforeLock: accessBeforeLock,
          refreshBeforeLock: refreshBeforeLock,
        ),
      );
    } on AuthFileLockTimeout {
      _logger.warning('Timed out waiting for another authentication mutation.');
      return const AuthRefreshResult.transientUnavailable();
    } catch (error) {
      _logger.warning(
        'Desktop authentication lock unavailable: ${error.runtimeType}',
      );
      return const AuthRefreshResult.transientUnavailable();
    }
  }

  Future<AuthRefreshResult> _refreshAccessTokenWithCurrentCredentials({
    String? accessBeforeLock,
    String? refreshBeforeLock,
  }) async {
    if (AppPlatform.isDesktop) {
      try {
        final authDoc = await _settingsStore.readAuthDocument();
        final fileAccessToken = authDoc['access_token']?.toString();
        final fileRefreshToken = authDoc['refresh_token']?.toString();
        final filePairChanged =
            fileAccessToken != null && (fileAccessToken != accessBeforeLock || fileRefreshToken != refreshBeforeLock);
        if (filePairChanged) {
          _logger.info(
            'Detected updated access token in auth.json. Adopting it.',
          );
          _backendAccessToken = fileAccessToken;
          if (fileRefreshToken != null && fileRefreshToken.isNotEmpty) {
            _backendRefreshToken = fileRefreshToken;
          }
          final prefs = await _getPrefs();
          await _persistAuthPair(
            prefs,
            accessToken: _backendAccessToken!,
            refreshToken: _backendRefreshToken,
          );
          _emitAccessToken();
          return AuthRefreshResult.success(_backendAccessToken!);
        }
      } catch (error) {
        _logger.warning(
          'Failed to synchronize desktop auth before refresh: ${error.runtimeType}',
        );
      }
    }

    if (_backendRefreshToken == null || _backendRefreshToken!.isEmpty) {
      _logger.warning('No refresh credential is available.');
      return const AuthRefreshResult.terminalRejected();
    }

    try {
      _logger.info('Refreshing access token via portal...');
      final result = await _portalAuth.refresh(
        refreshToken: _backendRefreshToken!,
      );
      final nextRefreshToken = result.refreshToken?.isNotEmpty == true ? result.refreshToken! : _backendRefreshToken!;

      final prefs = await _getPrefs();
      await _persistAuthPair(
        prefs,
        accessToken: result.accessToken,
        refreshToken: nextRefreshToken,
      );
      _backendAccessToken = result.accessToken;
      _backendRefreshToken = nextRefreshToken;

      await _syncAuthToFileUnlocked();
      _emitAuthenticationExchange();
      _logger.info('Token refreshed successfully');
      _emitAccessToken();
      return AuthRefreshResult.success(result.accessToken);
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        _logger.info('Portal rejected the refresh credential.');
        return const AuthRefreshResult.terminalRejected();
      }
      _logger.warning(
        'Portal refresh temporarily unavailable type=${error.type.name} status=${error.response?.statusCode}',
      );
      return const AuthRefreshResult.transientUnavailable();
    } catch (error) {
      _logger.warning(
        'Portal refresh temporarily unavailable type=${error.runtimeType}',
      );
      return const AuthRefreshResult.transientUnavailable();
    }
  }

  Future<void> fetchCredits() async {
    if (!isAuthenticated) return;
    try {
      final backendUrl = AppConfig.backendUrl;
      final response = await _dio.get(
        '$backendUrl/api/user/credits',
        options: Options(
          headers: {'Authorization': 'Bearer $_backendAccessToken'},
        ),
      );
      final data = response.data;

      if (data != null) {
        userCredits = (data['remaining_credits'] as num).toDouble();
        totalCredits = (data['total_credits'] as num).toDouble();
        _logger.info(
          'Credits updated. Remaining: $userCredits, Total: $totalCredits',
        );
      }
    } catch (e) {
      _logger.warning('Failed to fetch credits: $e');
    }
  }

  Future<void> fetchProfile() async {
    if (!isAuthenticated) return;
    try {
      final backendUrl = AppConfig.backendUrl;
      final response = await _dio.get(
        '$backendUrl/api/user/profile',
        options: Options(
          headers: {'Authorization': 'Bearer $_backendAccessToken'},
        ),
      );
      final data = response.data;

      final user = data['user'];
      if (user is Map) {
        final profileUsername = user['username']?.toString().trim() ?? '';
        if (profileUsername.isNotEmpty) {
          username = profileUsername;
          displayName = resolveUserDisplayName(
            username: profileUsername,
            displayName: user['display_name'],
          );
        }
        email = user['email']?.toString();
        userId = user['id']?.toString();
      }

      if (data['credits'] != null) {
        userCredits = (data['credits']['remaining_credits'] as num).toDouble();
        totalCredits = (data['credits']['total_credits'] as num).toDouble();
        _logger.info('Profile Loaded. Credits: $userCredits / $totalCredits');
      }
    } catch (error) {
      _logger.warning('Failed to fetch profile: ${error.runtimeType}');
    }
  }

  void _emitAccessToken() {
    if (!_accessTokenController.isClosed) {
      _accessTokenController.add(_backendAccessToken);
    }
  }

  void _emitAuthenticationExchange() {
    if (AppPlatform.isDesktop && !_authenticationExchangeController.isClosed) {
      _authenticationExchangeController.add(null);
    }
  }

  void dispose() {
    unawaited(_accessTokenController.close());
    unawaited(_authenticationExchangeController.close());
    unawaited(_loginChallengeController.close());
  }
}
