import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:sanad_client/utils/app_platform.dart';

import 'auth_callback_contract.dart';

const _desktopCallbackSuccessPage = r'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="icon" href="data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyBpZD0iTGF5ZXJfMiIgZGF0YS1uYW1lPSJMYXllciAyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYuMTUgMTY2LjQzIj4KICA8ZGVmcz4KICAgIDxzdHlsZT4KICAgICAgLmNscy0xIHsKICAgICAgICBmaWxsOiAjNjBhNWZhOwogICAgICAgIHN0cm9rZS13aWR0aDogMHB4OwogICAgICB9CiAgICA8L3N0eWxlPgogIDwvZGVmcz4KICA8ZyBpZD0iTGF5ZXJfMS0yIiBkYXRhLW5hbWU9IkxheWVyIDEiPgogICAgPGc+CiAgICAgIDxnPgogICAgICAgIDxwYXRoIGNsYXNzPSJjbHMtMSIgZD0ibTc4Ljg5LDk4LjgzaC0xOC42NGwtMi43Niw4LjQ1aC0xOC40bDIwLjQ1LTU1LjkxaDIwLjIxbDIwLjM3LDU1LjkxaC0xOC40OGwtMi43Ni04LjQ1Wm0tNC4yNi0xMy4xOWwtNS4wNS0xNS41Ni01LjA1LDE1LjU2aDEwLjExWiIvPgogICAgICAgIDxwYXRoIGNsYXNzPSJjbHMtMSIgZD0ibTEyMS42MSw1MS4zN3Y1NS45MWgtMTcuNTN2LTU1LjkxaDE3LjUzWiIvPgogICAgICA8L2c+CiAgICAgIDxwYXRoIGNsYXNzPSJjbHMtMSIgZD0ibTI1NC41MSwxMS4wNWMtNC42NS40OS04Ljc0LDIuMzgtMTIuMyw1LjMtNy42NSw2LjI5LTExLjI3LDE0LjU1LTExLjMzLDI0LjM3LS4wNywxMS44OCwwLDkuMzcuMDEsMjEuMzYsMCwyLjQ0LS42LDQuODctMS44Nyw2Ljk1LTIuMTgsMy41Ny01LjMsNS43LTkuNjEsNS40My00LjU3LS4yOC03LjU4LTIuODktOS4wMi03LjExLS42MS0xLjc2LS44My0zLjczLS44NC01LjYxLS4wNy0xMS44OS0uMDUtMjMuNzgsMC0zNS42NywwLTEuMjgtLjM1LTEuNy0xLjY2LTEuNTktNS44LjUtMTAuNjgsMi45LTE0LjYsNy4xNC00LjcxLDUuMDktNi43MywxMS4yOS02Ljg2LDE4LjEzLS4wOCw0LjA4LS4wMyw4LjE2LS4wNCwxMi4yNCwwLDIuNDktLjU1LDQuODUtMS44LDcuMDEtNC4yMyw3LjMyLTE0LjM0LDcuNDMtMTguMzkuNjMtMS40MS0yLjM4LTItNC45Mi0yLTcuNjIsMC03Ljc2LjA0LTE1LjUzLjA0LTIzLjI5LDAtNC4zLS4wNC04LjYxLS4wNS0xMi45MSwwLS44LS4wOS0xLjM2LTEuMTctMS4yMy00LjczLjU2LTguOTMsMi4zLTEyLjQ2LDUuNS02Ljg1LDYuMTktMTAuMDcsMTMuOTktMTAuMTksMjMuMTYtLjE0LDkuOTMtLjAyLDE5Ljg3LS41NCwyOS43OC0uNSw5LjU5LTIuODksMTguODItNy4xNCwyNy41Mi02Ljc0LDEzLjgyLTE3LjIyLDIzLjY2LTMxLjU1LDI5LjItMTIuNzgsNC45My0yNS42Myw0LjE0LTM4LjI4LS42LTE1LjM0LTUuNzUtMjYuNDktMTYuMjQtMzMuNzUtMzAuODMtMy41MS03LjA1LTUuNTctMTQuMzYtNi4xMy0yMS45MSwwLS4wMiwwLS4wNSwwLS4wOC0uMDctMS4zMS0uMS0yLjY1LS4xLTMuOTgsMC0xLjc5LjA2LTMuNTguMTctNS4zNCwxLjkzLTMwLjE4LDIwLjEyLTU1Ljk0LDQ1LjkxLTY4LjZ0MCwwYzcuODEtMy44NCwxNi4zMS02LjQ3LDI1LjI3LTcuNjctMy42MS0uNDgtNy4yOS0uNzItMTEuMDItLjcyQzM4LjM0LDAsMS43NSwzNS41My4wNiw4MGMtLjAxLjQtLjAyLjgtLjA0LDEuMjEtLjAyLjY3LS4wMiwxLjM0LS4wMiwyLjAxLDAsLjA5LDAsLjE4LDAsLjI3LDAsLjI1LDAsLjQ5LDAsLjc0LDAsMCwwLDAsMCwwLDAsLjc0LjAyLDEuNDcuMDUsMi4yMS4wMS4zNi4wMy43MS4wNSwxLjA3LjAyLjM2LjA0LjcxLjA2LDEuMDYuMDYuOTguMTQsMS45Ni4yNCwyLjkzLjA0LjM3LjA4LjczLjEyLDEuMS4xNiwxLjQ1LjM2LDIuOS42LDQuMzMuMjgsMS43NS42MiwzLjUxLDEsNS4yOSw0LjgsMjEuOTksMTcuNjEsMzguOTQsMzYuMjksNTEuMywxMy42Myw5LjAyLDI4LjQ2LDEzLjAyLDQzLjczLDEyLjkxLjM2LDAsLjcxLDAsMS4wNywwLDYuMDksMCwxMi4wMi0uNjUsMTcuNzMtMS44OS0uMjUtLjAxLS41LS4wMi0uNzUtLjA0LDIuNzgtLjU3LDUuNTctMS4yNyw4LjM1LTIuMDcsMTAuOS0zLjE2LDE4LjQyLTcuMzIsMjUuODctMTMuMnMxNC41MS0xMy40MiwyMC4wOC0yMS41N2M2LjA0LTguODQsOS42OC0xNi4zNCwxMy41Mi0yNS4zOCwwLDAsMTUuNDcsNS4wOSwyNy41OC00LjYzLDEuMjMtLjk5LDItMi40NSwyLjk5LTMuNjkuMDguMDUuMTcuMDkuMjMuMTUuNDMuNDUuODUuOTEsMS4yOCwxLjM2LDcuMjYsNy41OSwxNi4wMSwxMS43MSwyNi42NCwxMC45OSw5LjEyLS42MSwxNi43Ny00LjM3LDIyLjQ4LTExLjYyLDQuODQtNi4xMyw2Ljc2LTEzLjI5LDYuODUtMjAuOTguMDgtNS43Ny4wMi0xMS41My4wMy0xNy4zLjAxLTE5LjQyLjAzLTI0LjU4LjA0LTQ0LDAtMS42Ny0uMDEtMS42Ni0xLjYzLTEuNVoiLz4KICAgIDwvZz4KICA8L2c+Cjwvc3ZnPg==" type="image/svg+xml">
  <title>Authentication Successful - Sanad Portal</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-color: #1e1e1e;
      --card-bg: rgba(23, 23, 23, 0.75);
      --card-border: rgba(45, 45, 45, 0.8);
      --primary-color: #60a5fa;
      --on-primary-color: #0a0a0a;
      --accent-success: #00e676;
      --text-primary: #ffffff;
      --text-secondary: #8f9cae;
      --glow-color: rgba(0, 230, 118, 0.12);
      --background-glow-strong: rgba(96, 165, 250, 0.55);
      --background-glow-soft: rgba(96, 165, 250, 0.28);
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Outfit', sans-serif; -webkit-font-smoothing: antialiased; }
    body { background-color: var(--bg-color); color: var(--text-primary); min-height: 100vh; display: flex; align-items: center; justify-content: center; overflow: hidden; position: relative; }
    .background-glow { position: absolute; width: 100%; height: 100%; top: 0; left: 0; z-index: 1; overflow: hidden; }
    .orb { position: absolute; border-radius: 50%; filter: blur(120px); opacity: 0.3; animation: float 20s infinite alternate ease-in-out; }
    .orb-1 { width: 500px; height: 500px; background: radial-gradient(circle, var(--background-glow-strong) 0%, rgba(30,30,30,0) 70%); top: -10%; left: -10%; animation-duration: 25s; }
    .orb-2 { width: 600px; height: 600px; background: radial-gradient(circle, var(--background-glow-soft) 0%, rgba(30,30,30,0) 70%); bottom: -20%; right: -10%; animation-duration: 30s; }
    @keyframes float { 0% { transform: translate(0, 0) scale(1); } 100% { transform: translate(80px, 50px) scale(1.1); } }
    .success-container { position: relative; z-index: 2; width: 100%; max-width: 440px; padding: 50px 40px; background: var(--card-bg); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border: 1px solid var(--card-border); border-radius: 24px; box-shadow: 0 20px 50px rgba(0, 0, 0, 0.5), 0 0 40px var(--glow-color); text-align: center; animation: fadeIn 0.8s cubic-bezier(0.16, 1, 0.3, 1) forwards; opacity: 0; transform: translateY(20px); }
    @keyframes fadeIn { to { opacity: 1; transform: translateY(0); } }
    .success-icon-wrapper { width: 80px; height: 80px; margin: 0 auto 30px; border-radius: 50%; background: rgba(0, 230, 118, 0.1); border: 2px solid rgba(0, 230, 118, 0.2); display: flex; align-items: center; justify-content: center; box-shadow: 0 0 20px rgba(0, 230, 118, 0.2); position: relative; }
    .success-icon-wrapper svg { width: 40px; height: 40px; color: var(--accent-success); }
    .success-icon-wrapper svg path { stroke-dasharray: 100; stroke-dashoffset: 100; animation: dash 1s ease-in-out forwards 0.3s; }
    @keyframes dash { to { stroke-dashoffset: 0; } }
    .title { font-family: 'Georgia', serif; font-size: 28px; font-weight: 400; letter-spacing: -0.5px; margin-bottom: 16px; background: linear-gradient(to right, #ffffff, #b4c6ef); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
    .message { font-size: 15px; color: var(--text-secondary); line-height: 1.6; margin-bottom: 30px; }
    .action-hint { font-size: 13px; color: var(--primary-color); background: rgba(96, 165, 250, 0.08); border: 1px solid rgba(96, 165, 250, 0.15); padding: 10px 16px; border-radius: 10px; display: inline-block; font-weight: 500; margin-top: 15px; }
    .action-btn { font-size: 15px; color: var(--on-primary-color); background: linear-gradient(135deg, var(--accent-success), var(--primary-color)); border: none; padding: 14px 28px; border-radius: 12px; display: inline-block; font-weight: 600; text-decoration: none; box-shadow: 0 4px 15px rgba(0, 230, 118, 0.2); transition: all 0.3s ease; cursor: pointer; margin-top: 10px; }
    .action-btn:hover { transform: translateY(-2px); box-shadow: 0 6px 20px rgba(0, 230, 118, 0.4); }
    .return-section { display: flex; flex-direction: column; align-items: center; gap: 6px; }
    .footer-info { text-align: center; margin-top: 35px; font-size: 11px; color: rgba(255, 255, 255, 0.2); letter-spacing: 0.5px; }
    .hidden { display: none !important; }
  </style>
</head>
<body>
  <div class="background-glow">
    <div class="orb orb-1"></div>
    <div class="orb orb-2"></div>
  </div>
  <div class="success-container">
    <div class="success-icon-wrapper">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
        <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/>
        <path d="M22 4L12 14.01l-3-3"/>
      </svg>
    </div>
    <h1 class="title">Authentication Complete</h1>
    <p class="message">You have successfully signed in. A one-time authorization code is being returned to the Sanad app.</p>
    <div class="return-section">
      <a class="action-btn" href="sanad://success">Return to Sanad App</a>
      <span id="auto-hint" class="action-hint">Returning you to the Sanad app…</span>
      <span id="manual-hint" class="action-hint hidden">You can safely close this browser window now</span>
    </div>
    <div class="footer-info">Sanad Portal • Secure Sync Completed</div>
  </div>
  <script>
    setTimeout(function () {
      try { window.close(); } catch (e) { /* browser fallback */ }
      document.getElementById('auto-hint').classList.add('hidden');
      document.getElementById('manual-hint').classList.remove('hidden');
    }, 600);
  </script>
</body>
</html>''';

Future<AuthCallbackBinding> createPlatformAuthCallbackBinding() async {
  if (AppPlatform.isDesktop) {
    return createDesktopLoopbackAuthCallbackBinding();
  }
  if (AppPlatform.isMobile) {
    return _MobileClaimedLinkBinding.create();
  }
  throw UnsupportedError('Interactive authentication is unsupported here.');
}

Future<AuthCallbackBinding> createDesktopLoopbackAuthCallbackBinding() => _DesktopLoopbackBinding.create();

class _DesktopLoopbackBinding implements AuthCallbackBinding {
  _DesktopLoopbackBinding._(this._server);

  final HttpServer _server;
  final Completer<AuthCallbackResult> _result = Completer<AuthCallbackResult>();
  StreamSubscription<HttpRequest>? _subscription;

  static Future<_DesktopLoopbackBinding> create() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final binding = _DesktopLoopbackBinding._(server);
    binding._subscription = server.listen(binding._handle);
    return binding;
  }

  @override
  String get clientId => 'sanad_flutter_desktop';

  @override
  String get redirectUri => 'http://127.0.0.1:${_server.port}/oauth/callback';

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/oauth/callback') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final code = request.uri.queryParameters['code'];
    final state = request.uri.queryParameters['state'];
    if (code == null || state == null || _result.isCompleted) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('Referrer-Policy', 'no-referrer')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..headers.set(
        'Content-Security-Policy',
        "default-src 'none'; "
            'img-src data:; '
            "style-src 'unsafe-inline' https://fonts.googleapis.com; "
            'font-src https://fonts.gstatic.com; '
            "script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
      )
      ..write(_desktopCallbackSuccessPage);
    await request.response.close();
    _result.complete(AuthCallbackResult(code: code, state: state));
  }

  @override
  Future<AuthCallbackResult> waitForResult(Duration timeout) => _result.future.timeout(timeout);

  @override
  Future<void> cancel() async {
    if (!_result.isCompleted) {
      _result.completeError(const AuthLoginCancelledException());
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _server.close(force: true);
  }
}

bool isExpectedMobileAuthCallback(Uri candidate, Uri expected) =>
    candidate.scheme == expected.scheme &&
    candidate.host == expected.host &&
    candidate.port == expected.port &&
    candidate.path == expected.path &&
    candidate.userInfo.isEmpty &&
    candidate.fragment.isEmpty;

bool shouldUseDevelopmentIosAuth({
  required bool isIos,
  required bool isDebug,
  required String environment,
  required String redirect,
}) => isIos && isDebug && environment == 'dev' && redirect.isNotEmpty;

bool isValidMobileAuthRedirect(
  Uri redirect, {
  required bool allowDevelopmentCustomScheme,
}) {
  if (redirect.userInfo.isNotEmpty || redirect.hasQuery || redirect.hasFragment || redirect.path.isEmpty) {
    return false;
  }
  if (redirect.scheme == 'https') {
    return redirect.host.isNotEmpty;
  }
  return allowDevelopmentCustomScheme &&
      redirect.scheme == 'sanad' &&
      redirect.host == 'oauth' &&
      redirect.path == '/ios-development';
}

class _MobileClaimedLinkBinding implements AuthCallbackBinding {
  _MobileClaimedLinkBinding._(
    this._expectedRedirect,
    this._links,
    this._usesDevelopmentCustomScheme,
  );

  static const _iosRedirect = String.fromEnvironment(
    'SANAD_IOS_AUTH_REDIRECT_URI',
  );
  static const _iosDevelopmentRedirect = String.fromEnvironment(
    'SANAD_IOS_DEVELOPMENT_AUTH_REDIRECT_URI',
  );
  static const _environment = String.fromEnvironment(
    'ENVIRONMENT',
    defaultValue: 'prod',
  );
  static const _androidRedirect = String.fromEnvironment(
    'SANAD_ANDROID_AUTH_REDIRECT_URI',
  );

  final Uri _expectedRedirect;
  final AppLinks _links;
  final bool _usesDevelopmentCustomScheme;
  final Completer<AuthCallbackResult> _result = Completer<AuthCallbackResult>();
  StreamSubscription<Uri>? _subscription;

  static Future<_MobileClaimedLinkBinding> create() async {
    final useDevelopmentCustomScheme = shouldUseDevelopmentIosAuth(
      isIos: AppPlatform.isIOS,
      isDebug: kDebugMode,
      environment: _environment,
      redirect: _iosDevelopmentRedirect,
    );
    final configured = AppPlatform.isAndroid
        ? _androidRedirect
        : useDevelopmentCustomScheme
        ? _iosDevelopmentRedirect
        : _iosRedirect;
    if (configured.isEmpty) {
      throw StateError('Mobile authentication redirect is not configured.');
    }
    final expected = Uri.parse(configured);
    if (!isValidMobileAuthRedirect(
      expected,
      allowDevelopmentCustomScheme: useDevelopmentCustomScheme,
    )) {
      throw StateError(
        useDevelopmentCustomScheme
            ? 'Development iOS authentication redirect is invalid.'
            : 'Mobile authentication redirect must be an exact HTTPS origin path.',
      );
    }

    final binding = _MobileClaimedLinkBinding._(
      expected,
      AppLinks(),
      useDevelopmentCustomScheme,
    );
    // Subscribe before opening the browser. app_links emits both the initial
    // cold-start URI and later warm-link events through this stream.
    binding._subscription = binding._links.uriLinkStream.listen(
      binding._handle,
      onError: (Object _, StackTrace __) {
        if (!binding._result.isCompleted) {
          binding._result.completeError(
            StateError('Authentication callback delivery failed.'),
          );
        }
      },
    );
    return binding;
  }

  @override
  String get clientId => AppPlatform.isAndroid
      ? 'sanad_flutter_android'
      : _usesDevelopmentCustomScheme
      ? 'sanad_flutter_ios_development'
      : 'sanad_flutter_ios';

  @override
  String get redirectUri => _expectedRedirect.toString();

  void _handle(Uri candidate) {
    if (_result.isCompleted || !isExpectedMobileAuthCallback(candidate, _expectedRedirect)) {
      return;
    }
    final code = candidate.queryParameters['code'];
    final state = candidate.queryParameters['state'];
    if (code == null || code.isEmpty || state == null || state.isEmpty) {
      return;
    }
    _result.complete(AuthCallbackResult(code: code, state: state));
  }

  @override
  Future<AuthCallbackResult> waitForResult(Duration timeout) => _result.future.timeout(timeout);

  @override
  Future<void> cancel() async {
    if (!_result.isCompleted) {
      _result.completeError(const AuthLoginCancelledException());
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
  }
}
