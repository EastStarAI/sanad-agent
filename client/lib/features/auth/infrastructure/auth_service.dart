import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
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

class AuthService {
  static final _logger = Logger('AuthService');
  static const _authSessionKey = 'backend_auth_session_v1';
  bool _isLoginCancelled = false;
  bool _isPolling = false;
  final Dio _dio;
  final SanadSettingsStore _settingsStore;
  final SharedPreferences? _prefs;
  final PortalAuthClient _portalAuth;
  final _accessTokenController = StreamController<String?>.broadcast();
  final _authenticationExchangeController = StreamController<void>.broadcast();
  final _loginChallengeController = StreamController<AuthLoginChallenge?>.broadcast();
  Future<AuthRefreshResult>? _refreshFuture;

  String? _backendAccessToken;
  String? _backendRefreshToken;
  String? _hardwareId;
  AuthLoginChallenge? _loginChallenge;
  String? _activeAuthSessionId;
  String? _activePollingToken;
  String? username;
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
  }) : _dio =
           dio ??
           (Dio()
             ..options.connectTimeout = const Duration(seconds: 3)
             ..options.receiveTimeout = const Duration(seconds: 3)),
       _settingsStore = settingsStore ?? const SanadSettingsStore(),
       _prefs = prefs,
       _portalAuth = portalAuth ?? PortalAuthClient() {
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
      jsonEncode({
        'access_token': accessToken,
        'refresh_token': refreshToken,
      }),
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

  /// Platform hint passed to the portal. The portal decides the UX based on
  /// this plus [capabilities]. The client never names a flow or provider.
  String get _platformHint {
    if (kIsWeb) return 'web';
    if (AppPlatform.isMobile) return AppPlatform.isAndroid ? 'android' : 'ios';
    if (AppPlatform.isDesktop) return 'desktop';
    return 'cli';
  }

  List<String> get _capabilityHints {
    final caps = <String>['system_browser'];
    if (kIsWeb) caps.add('popup');
    if (AppPlatform.isMobile) caps.add('deep_link');
    return caps;
  }

  Future<void> init({String? fallbackDeviceId}) async {
    final prefs = await _getPrefs();

    if (AppPlatform.isDesktop) {
      try {
        final authDoc = await _settingsStore.readAuthDocument();
        final String? token = authDoc['access_token'];
        final String? refreshToken = authDoc['refresh_token'];
        final String? hardwareId = authDoc['hardware_id']?.toString();

        if (token != null || hardwareId != null) {
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
          await _syncAuthToFile();

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

  void cancelLogin() {
    _isLoginCancelled = true;
    final sessionId = _activeAuthSessionId;
    final pollingToken = _activePollingToken;
    if (sessionId != null && pollingToken != null) {
      unawaited(
        _portalAuth.cancel(
          authSessionId: sessionId,
          pollingToken: pollingToken,
        ),
      );
    }
    _setLoginChallenge(null);
    _logger.info('Login flow cancelled by user.');
  }

  Future<void> login() async {
    _isLoginCancelled = false;
    _isPolling = true;
    try {
      // Plan 23: a single unified portal-driven flow for all platforms. The
      // portal decides whether a user_code is needed (CLI/headless only).
      await _loginViaPortal();
    } catch (e) {
      _logger.severe('Login failed: $e');
      if (kIsWeb) {
        WebAuthPopupService.instance.closePopup();
      }
      rethrow;
    } finally {
      _isPolling = false;
      _activeAuthSessionId = null;
      _activePollingToken = null;
      _setLoginChallenge(null);
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

  Future<void> _loginViaPortal() async {
    _logger.info('Starting portal auth session (platform=$_platformHint)...');
    final start = await _portalAuth.start(
      platform: _platformHint,
      capabilities: _capabilityHints,
    );
    _activeAuthSessionId = start.authSessionId;
    _activePollingToken = start.pollingToken;

    if (start.userCode != null && start.userCode!.isNotEmpty) {
      _setLoginChallenge(
        AuthLoginChallenge(
          userCode: start.userCode!,
          authUrl: start.authUrl,
          expiresIn: start.expiresIn,
        ),
      );
    } else {
      _setLoginChallenge(
        AuthLoginChallenge(
          userCode: '',
          authUrl: start.authUrl,
          expiresIn: start.expiresIn,
        ),
      );
    }
    _logger.info('Portal auth session started.');

    // Open the portal page in the platform-appropriate browser surface. The
    // portal chooses the identity provider inside its own page; the client
    // never passes or knows the provider name.
    if (kIsWeb) {
      final popupService = WebAuthPopupService.instance;
      final opened = popupService.openAuthPopup(start.authUrl);
      if (!opened) {
        throw Exception(
          'Popup blocker detected. Please allow popups for this site to log in.',
        );
      }
      _logger.info('Popup authentication initiated');
    } else {
      final authUri = Uri.parse(start.authUrl);
      final launched = await launchUrl(
        authUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw Exception('Could not launch auth URL: ${start.authUrl}');
      }
    }

    // Poll the portal until the session completes. The private
    // `polling_token` stays inside AuthService; it is never put into URLs,
    // the browser, or storage.
    //
    // NOTE (Plan 23): on Web the success.html page auto-closes itself once
    // the portal has stored the tokens. The popup closing is therefore NOT a
    // reliable cancellation signal — it can fire ~immediately after success
    // but before our next poll returns "completed". The portal's
    // `/auth/status` is the source of truth: we keep polling until it reports
    // `completed`, `expired`, or `cancelled`, or the user explicitly hits the
    // Cancel button (which sets `_isLoginCancelled`).
    final maxAttempts = (start.expiresIn / start.interval).ceil();
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (_isLoginCancelled) {
        throw Exception('Login cancelled by user');
      }
      await Future.delayed(Duration(seconds: start.interval));
      if (_isLoginCancelled) {
        throw Exception('Login cancelled by user');
      }

      final st = await _portalAuth.status(
        authSessionId: start.authSessionId,
        pollingToken: start.pollingToken,
      );
      if (st.status == 'completed') {
        if (st.accessToken == null) {
          throw Exception('Login completed but no access token was returned.');
        }
        _backendAccessToken = st.accessToken;
        _backendRefreshToken = st.refreshToken;
        _logger.info('Login successful.');

        if (kIsWeb) {
          WebAuthPopupService.instance.closePopup();
        }

        final prefs = await _getPrefs();
        await _persistAuthPair(
          prefs,
          accessToken: _backendAccessToken!,
          refreshToken: _backendRefreshToken,
        );
        await _syncAuthToFile();
        _emitAuthenticationExchange();
        await fetchProfile();
        _emitAccessToken();
        _setLoginChallenge(null);
        return;
      } else if (st.status == 'expired' || st.status == 'cancelled') {
        throw Exception('Authentication session ${st.status}');
      }
    }

    throw Exception('Login timed out');
  }

  void _setLoginChallenge(AuthLoginChallenge? challenge) {
    _loginChallenge = challenge;
    if (!_loginChallengeController.isClosed) {
      _loginChallengeController.add(challenge);
    }
  }

  Future<void> logout() async {
    final refreshToken = _backendRefreshToken;
    final accessToken = _backendAccessToken;
    if (refreshToken != null || accessToken != null) {
      unawaited(
        _portalAuth.logout(
          accessToken: accessToken,
          refreshToken: refreshToken,
        ),
      );
    }

    _backendAccessToken = null;
    _backendRefreshToken = null;
    userCredits = 0.0;
    username = null;
    email = null;
    userId = null;

    final prefs = await _getPrefs();
    await prefs.remove(_authSessionKey);
    await prefs.remove('backend_access_token');
    await prefs.remove('backend_refresh_token');

    if (AppPlatform.isDesktop) {
      try {
        final existing = await _settingsStore.readAuthDocument();
        final next = Map<String, dynamic>.from(existing)
          ..remove('access_token')
          ..remove('refresh_token')
          ..remove('device_token')
          ..remove('pairing_token')
          ..remove('pending_device_token');
        await _settingsStore.saveAuthDocument(next);
        _emitAuthenticationExchange();
      } catch (e) {
        _logger.warning('Failed to clean auth file during logout: $e');
      }
    }
    _emitAccessToken();
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
    if (AppPlatform.isDesktop) {
      try {
        final authDoc = await _settingsStore.readAuthDocument();
        final fileAccessToken = authDoc['access_token'] as String?;
        final fileRefreshToken = authDoc['refresh_token'] as String?;
        if (fileAccessToken != null && fileAccessToken != _backendAccessToken) {
          _logger.info(
            'Detected updated access token in auth.json. Adopting it.',
          );
          _backendAccessToken = fileAccessToken;
          if (fileRefreshToken != null && fileRefreshToken.isNotEmpty) {
            _backendRefreshToken = fileRefreshToken;
          }
          final prefs = await _getPrefs();
          await prefs.setString('backend_access_token', _backendAccessToken!);
          if (_backendRefreshToken != null) {
            await prefs.setString(
              'backend_refresh_token',
              _backendRefreshToken!,
            );
          }
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

      await _syncAuthToFile();
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

      if (data['user'] != null) {
        username = data['user']['username'];
        email = data['user']['email'];
        userId = data['user']['id']?.toString();
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
