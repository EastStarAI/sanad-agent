import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:sanad_client/utils/app_platform.dart';

import 'auth_callback_contract.dart';

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
      ..write(
        '<!doctype html><title>Sanad</title>'
        'Authentication complete. You may close this window.',
      );
    await request.response.close();
    _result.complete(AuthCallbackResult(code: code, state: state));
  }

  @override
  Future<AuthCallbackResult> waitForResult(Duration timeout) => _result.future.timeout(timeout);

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _server.close(force: true);
  }
}

bool isExpectedMobileAuthCallback(Uri candidate, Uri expected) =>
    candidate.scheme == 'https' &&
    candidate.scheme == expected.scheme &&
    candidate.host == expected.host &&
    candidate.port == expected.port &&
    candidate.path == expected.path &&
    candidate.userInfo.isEmpty &&
    candidate.fragment.isEmpty;

class _MobileClaimedLinkBinding implements AuthCallbackBinding {
  _MobileClaimedLinkBinding._(this._expectedRedirect, this._links);

  static const _iosRedirect = String.fromEnvironment(
    'SANAD_IOS_AUTH_REDIRECT_URI',
  );
  static const _androidRedirect = String.fromEnvironment(
    'SANAD_ANDROID_AUTH_REDIRECT_URI',
  );

  final Uri _expectedRedirect;
  final AppLinks _links;
  final Completer<AuthCallbackResult> _result = Completer<AuthCallbackResult>();
  StreamSubscription<Uri>? _subscription;

  static Future<_MobileClaimedLinkBinding> create() async {
    final configured = AppPlatform.isAndroid ? _androidRedirect : _iosRedirect;
    if (configured.isEmpty) {
      throw StateError(
        'Claimed HTTPS authentication redirect is not configured.',
      );
    }
    final expected = Uri.parse(configured);
    if (expected.scheme != 'https' ||
        expected.host.isEmpty ||
        expected.userInfo.isNotEmpty ||
        expected.hasQuery ||
        expected.hasFragment) {
      throw StateError(
        'Mobile authentication redirect must be an exact HTTPS origin path.',
      );
    }

    final binding = _MobileClaimedLinkBinding._(expected, AppLinks());
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
  String get clientId => AppPlatform.isAndroid ? 'sanad_flutter_android' : 'sanad_flutter_ios';

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
  Future<void> dispose() async {
    await _subscription?.cancel();
  }
}
