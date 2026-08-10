import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:url_launcher/url_launcher.dart';

enum ClientUpdateStatus {
  checkStarted,
  updateOpened,
  upToDate,
  sourceManaged,
  unsupported,
  networkFailed,
  manifestInvalid,
  artifactUnavailable,
  launchFailed,
}

class ClientUpdateResult {
  const ClientUpdateResult(this.status, {this.message});
  final ClientUpdateStatus status;
  final String? message;
}

abstract class NativeUpdateAdapter {
  Future<void> setFeedUrl(String url);
  Future<void> setScheduledCheckInterval(int seconds);
  Future<void> checkForUpdates();
  void setQuitForUpdateHandler(void Function()? callback);
}

class AutoUpdaterAdapter implements NativeUpdateAdapter {
  _WinSparkleQuitListener? _quitListener;

  @override
  Future<void> setFeedUrl(String url) => autoUpdater.setFeedURL(url);

  @override
  Future<void> setScheduledCheckInterval(int seconds) => autoUpdater.setScheduledCheckInterval(seconds);

  @override
  Future<void> checkForUpdates() => autoUpdater.checkForUpdates();

  @override
  void setQuitForUpdateHandler(void Function()? callback) {
    final previous = _quitListener;
    if (previous != null) autoUpdater.removeListener(previous);
    _quitListener = callback == null ? null : _WinSparkleQuitListener(callback);
    final next = _quitListener;
    if (next != null) autoUpdater.addListener(next);
  }
}

class _WinSparkleQuitListener implements UpdaterListener {
  _WinSparkleQuitListener(this.onBeforeQuitForUpdate);

  final void Function() onBeforeQuitForUpdate;

  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? appcastItem) => onBeforeQuitForUpdate();

  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) {}

  @override
  void onUpdaterError(UpdaterError? error) {}

  @override
  void onUpdaterUpdateAvailable(AppcastItem? appcastItem) {}

  @override
  void onUpdaterUpdateDownloaded(AppcastItem? appcastItem) {}

  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {}
}

class AutoUpdateService {
  static final _logger = Logger('AutoUpdateService');

  AutoUpdateService({FutureOr<void> Function()? beforeQuitForUpdate})
    : _native = AutoUpdaterAdapter(),
      _client = http.Client(),
      _platform = AppPlatform.name,
      _sourceRun = AppConfig.isSourceRun,
      _currentVersion = _packageVersion,
      _launch = _launchExternal,
      _manifestUrl = _defaultManifestUrl,
      _feedUrl = AppConfig.stableAppcastUrl,
      _quit = exit,
      _beforeQuitForUpdate = beforeQuitForUpdate;

  AutoUpdateService.test({
    required NativeUpdateAdapter native,
    required http.Client client,
    required String platform,
    required bool sourceRun,
    required Future<String> Function() currentVersion,
    required Future<bool> Function(Uri uri) launch,
    Uri? manifestUri,
    String feedUrl = 'https://updates.sanad.eaststarai.com/appcast.xml',
    void Function(int code) quit = exit,
    FutureOr<void> Function()? beforeQuitForUpdate,
  }) : _native = native,
       _client = client,
       _platform = platform,
       _sourceRun = sourceRun,
       _currentVersion = currentVersion,
       _launch = launch,
       _manifestUrl = manifestUri ?? _defaultManifestUrl,
       _feedUrl = feedUrl,
       _quit = quit,
       _beforeQuitForUpdate = beforeQuitForUpdate;

  final String _feedUrl;
  static final Uri _defaultManifestUrl = Uri.parse(
    'https://github.com/EastStarAI/sanad-agent/releases/latest/download/release-manifest.json',
  );

  final NativeUpdateAdapter _native;
  final http.Client _client;
  final String _platform;
  final bool _sourceRun;
  final Future<String> Function() _currentVersion;
  final Future<bool> Function(Uri uri) _launch;
  final Uri _manifestUrl;
  final void Function(int code) _quit;
  final FutureOr<void> Function()? _beforeQuitForUpdate;
  bool _isInitialized = false;
  bool _quitForUpdateStarted = false;
  Future<ClientUpdateResult>? _activeCheck;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    if (_sourceRun) {
      _logger.info('Client self-update is disabled for source-managed runs.');
      return;
    }

    if (_platform == 'macos' || _platform == 'windows') {
      try {
        await _native.setFeedUrl(_feedUrl);
        await _native.setScheduledCheckInterval(86400);
        if (_platform == 'windows') {
          _native.setQuitForUpdateHandler(quitForUpdate);
        }
        // Sparkle/WinSparkle owns consent-based scheduled checks. Calling the
        // interactive API here would show an "up to date" dialog on every
        // launch; it is reserved for the explicit Settings action.
      } catch (error) {
        _logger.warning(
          'Update feed initialization failed without blocking startup: $error',
        );
      }
    } else if (_platform == 'web') {
      unawaited(_checkWebVersion());
    }
  }

  Future<ClientUpdateResult> checkForUpdates() {
    final active = _activeCheck;
    if (active != null) return active;
    final check = _checkForUpdates();
    _activeCheck = check;
    return check.whenComplete(() => _activeCheck = null);
  }

  /// WinSparkle/Sparkle `before-quit-for-update` handoff.
  ///
  /// Runs a bounded client-owned flush, then exits so the native installer
  /// can replace application files. A timeout still exits because the
  /// installer is already waiting for the process to close.
  void quitForUpdate() {
    if (_quitForUpdateStarted) return;
    _quitForUpdateStarted = true;
    unawaited(_quitForUpdate());
  }

  Future<void> _quitForUpdate() async {
    _logger.info('Updater requested application quit; closing the client.');
    _native.setQuitForUpdateHandler(null);
    try {
      final beforeQuit = _beforeQuitForUpdate;
      if (beforeQuit != null) {
        await Future<void>.sync(beforeQuit).timeout(
          const Duration(seconds: 5),
        );
      }
    } catch (error) {
      _logger.warning('Pre-update shutdown flush finished with errors: $error');
    }
    _quit(0);
  }

  void dispose() {
    if (_platform == 'windows') {
      _native.setQuitForUpdateHandler(null);
    }
    _client.close();
  }

  Future<ClientUpdateResult> _checkForUpdates() async {
    if (_sourceRun) {
      return const ClientUpdateResult(ClientUpdateStatus.sourceManaged);
    }
    if (_platform == 'macos' || _platform == 'windows') {
      try {
        await _native.checkForUpdates();
        return const ClientUpdateResult(ClientUpdateStatus.checkStarted);
      } catch (error) {
        return ClientUpdateResult(
          ClientUpdateStatus.networkFailed,
          message: 'Could not check the signed update feed: $error',
        );
      }
    }
    if (_platform == 'linux') return _checkLinuxManualUpdate();
    if (_platform == 'web') {
      await _checkWebVersion();
      return const ClientUpdateResult(ClientUpdateStatus.checkStarted);
    }
    return const ClientUpdateResult(ClientUpdateStatus.unsupported);
  }

  Future<ClientUpdateResult> _checkLinuxManualUpdate() async {
    ReleaseManifest manifest;
    try {
      final response = await _client.get(
        _manifestUrl,
        headers: const {'User-Agent': 'sanad-client'},
      );
      if (response.statusCode != 200) {
        return ClientUpdateResult(
          ClientUpdateStatus.networkFailed,
          message: 'Release discovery failed with HTTP ${response.statusCode}.',
        );
      }
      manifest = ReleaseManifest.fromJsonString(response.body);
    } on FormatException catch (error) {
      return ClientUpdateResult(
        ClientUpdateStatus.manifestInvalid,
        message: error.message,
      );
    } catch (error) {
      return ClientUpdateResult(
        ClientUpdateStatus.networkFailed,
        message: 'Could not reach the official release manifest: $error',
      );
    }

    final current = ReleaseVersion.parse(await _currentVersion());
    if (manifest.version.compareTo(current) <= 0) {
      return const ClientUpdateResult(ClientUpdateStatus.upToDate);
    }
    final artifact = manifest.findArtifact(
      component: 'client',
      platform: 'linux',
      architecture: 'x64',
      format: 'deb',
      publicOnly: true,
    );
    if (artifact == null) {
      return const ClientUpdateResult(ClientUpdateStatus.artifactUnavailable);
    }
    if (!await _launch(artifact.url)) {
      return const ClientUpdateResult(ClientUpdateStatus.launchFailed);
    }
    return const ClientUpdateResult(ClientUpdateStatus.updateOpened);
  }

  Future<void> _checkWebVersion() async {
    try {
      final response = await _client.get(
        Uri.base.resolve('version.json'),
        headers: const {'Cache-Control': 'no-cache'},
      );
      if (response.statusCode != 200) return;
      final payload = jsonDecode(response.body);
      final published = payload is Map ? payload['version']?.toString() : null;
      final current = await _currentVersion();
      if (published != null && published != current) {
        _logger.info('A newer Web client is available after the next reload.');
      }
    } catch (_) {
      // Best effort and never startup-blocking.
    }
  }

  static Future<String> _packageVersion() async => (await PackageInfo.fromPlatform()).version.split('+').first;

  static Future<bool> _launchExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
}
