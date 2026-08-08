import 'dart:io';
import 'package:flutter/foundation.dart';

import 'public_service_endpoints.dart';

enum AppEnvironment { local, dev, prod, stg }

class AppConfig {
  static const String _rawEnv = String.fromEnvironment(
    'ENVIRONMENT',
    defaultValue: 'prod',
  );

  static AppEnvironment get env {
    switch (_rawEnv) {
      case 'prod':
        return AppEnvironment.prod;
      case 'stg':
        return AppEnvironment.stg;
      case 'local':
        return AppEnvironment.local;
      default:
        return AppEnvironment.dev;
    }
  }

  static bool get isDev => env == AppEnvironment.dev;
  static bool get isProd => env == AppEnvironment.prod;

  /// Returns `true` if the client was run from the source code via flutter tools/IDE
  /// (e.g. `fvm flutter run`), and `false` if it is running as a built/packaged standalone app.
  static bool get isSourceRun {
    if (kDebugMode) return true;

    // Traverse directory tree to look for the repository signature (source code check)
    try {
      final exeFile = File(Platform.resolvedExecutable);
      var dir = exeFile.parent;
      for (var i = 0; i < 12; i++) {
        final agentSource = File(
          '${dir.path}${Platform.pathSeparator}agent${Platform.pathSeparator}bin${Platform.pathSeparator}sanad_agent.dart',
        );
        if (agentSource.existsSync()) {
          return true;
        }

        final nestedAgentSource = File(
          '${dir.path}${Platform.pathSeparator}sanad-agent${Platform.pathSeparator}agent${Platform.pathSeparator}bin${Platform.pathSeparator}sanad_agent.dart',
        );
        if (nestedAgentSource.existsSync()) {
          return true;
        }

        if (dir.path == dir.parent.path) break;
        dir = dir.parent;
      }
    } catch (_) {}
    return false;
  }

  static const String _backendUrlOverride = String.fromEnvironment(
    'BACKEND_URL',
  );
  static String get backendUrl =>
      _backendUrlOverride.trim().isNotEmpty ? _backendUrlOverride : PublicServiceEndpoints.backendFor(_rawEnv);

  /// Plan 23: ``sanad-portal`` is the only public auth surface for the
  /// open-source clients. The client must use ``portalUrl`` for all
  /// authentication (start / status / refresh / logout / cancel). It must not
  /// call ``backendUrl /api/auth/*`` for authentication; ``backendUrl`` is
  /// only used for REST / Socket.IO after the access token is obtained.
  static const String _portalUrlOverride = String.fromEnvironment('PORTAL_URL');
  static String get portalUrl =>
      _portalUrlOverride.trim().isNotEmpty ? _portalUrlOverride : PublicServiceEndpoints.portalFor(_rawEnv);
  static const String localGatewayUrl = String.fromEnvironment(
    'LOCAL_GATEWAY_URL',
    defaultValue: 'http://127.0.0.1:58085',
  );
  static const String stableAppcastUrl = String.fromEnvironment(
    'SANAD_APPCAST_URL',
    defaultValue: 'https://updates.sanad.eaststarai.com/appcast.xml',
  );
  static const String releaseManifestUrl = String.fromEnvironment(
    'SANAD_RELEASE_MANIFEST_URL',
    defaultValue: 'https://github.com/EastStarAI/sanad-agent/releases/latest/download/release-manifest.json',
  );
  static const String releaseArtifactMirrorUrl = String.fromEnvironment(
    'SANAD_RELEASE_ARTIFACT_MIRROR_URL',
  );
  static const bool enableCloudGateway = bool.fromEnvironment(
    'ENABLE_CLOUD_GATEWAY',
    defaultValue: true,
  );
  static const String sanadHome = String.fromEnvironment('SANAD_HOME');
  static const String sanadServiceInstance = String.fromEnvironment(
    'SANAD_SERVICE_INSTANCE',
  );
  static const String sharedPreferencesPrefix = String.fromEnvironment(
    'SANAD_SHARED_PREFERENCES_PREFIX',
  );
  static const String sanadDevWorktreeName = String.fromEnvironment(
    'SANAD_DEV_WORKTREE_NAME',
  );
  static const String sanadDevWorktreeBranch = String.fromEnvironment(
    'SANAD_DEV_WORKTREE_BRANCH',
  );
}
