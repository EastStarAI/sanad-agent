import 'dart:io';
import 'package:path/path.dart' as p;

String? _sanadHomeOverride;
String? _sanadStateHomeOverride;

void setSanadHomeOverride(String? path) {
  _sanadHomeOverride = path;
}

void setSanadStateHomeOverride(String? path) {
  _sanadStateHomeOverride = path;
}

/// Returns the path to the Sanad home directory.
/// Priority:
/// 1. Manual override via setSanadHomeOverride()
/// 2. SANAD_HOME environment variable (used directly)
/// 3. Default user home + /.sanad/
String getSanadHome() {
  if (_sanadHomeOverride != null) {
    return _sanadHomeOverride!;
  }

  final String? envHome = Platform.environment['SANAD_HOME'];
  if (envHome != null && envHome.isNotEmpty) {
    return envHome;
  }

  final String? home = Platform.isWindows
      ? Platform.environment['USERPROFILE']
      : Platform.environment['HOME'];

  if (home == null) {
    throw Exception("Could not determine home directory.");
  }

  return p.join(home, '.sanad');
}

/// Returns the writable runtime-state directory.
///
/// Development worktrees can override this with SANAD_STATE_HOME while still
/// sharing the normal SANAD_HOME identity and provider configuration. Normal
/// installs keep the historical behavior and store state in SANAD_HOME.
String getSanadStateHome() {
  if (_sanadStateHomeOverride != null) {
    return _sanadStateHomeOverride!;
  }

  final envHome = Platform.environment['SANAD_STATE_HOME'];
  if (envHome != null && envHome.isNotEmpty) {
    return envHome;
  }

  return getSanadHome();
}

/// Returns the path to the environment configuration file (.env).
/// The .env file is always loaded from SANAD_HOME.
String getEnvPath() {
  return p.join(getSanadHome(), '.env');
}

/// Dynamically reads the version from pubspec.yaml if running from source,
/// or falls back to the production release constant if compiled.
String loadAgentVersion() {
  // 1. Try to find and parse pubspec.yaml relative to Platform.script
  try {
    final scriptUri = Platform.script;
    if (scriptUri.isScheme('file')) {
      var dir = Directory(p.dirname(scriptUri.toFilePath()));
      for (var i = 0; i < 5; i++) {
        final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
        if (pubspec.existsSync()) {
          final content = pubspec.readAsStringSync();
          final match = RegExp(
            r'^version:\s*([^\s#]+)',
            multiLine: true,
          ).firstMatch(content);
          if (match != null && match.groupCount >= 1) {
            return match.group(1)!;
          }
        }
        if (dir.path == dir.parent.path) break;
        dir = dir.parent;
      }
    }
  } catch (_) {}

  // 2. Fallback to checking the current directory
  try {
    final pubspec = File('pubspec.yaml');
    if (pubspec.existsSync()) {
      final content = pubspec.readAsStringSync();
      final match = RegExp(
        r'^version:\s*([^\s#]+)',
        multiLine: true,
      ).firstMatch(content);
      if (match != null && match.groupCount >= 1) {
        return match.group(1)!;
      }
    }
  } catch (_) {}

  // 3. Native builds receive the release contract version at compile time.
  return const String.fromEnvironment(
    'SANAD_AGENT_VERSION',
    defaultValue: '1.0.0',
  );
}
