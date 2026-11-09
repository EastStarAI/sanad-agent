import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/sanad_home/installed_home_record.dart';

String? _sanadHomeOverride;
String? _sanadStateHomeOverride;

void setSanadHomeOverride(String? path) {
  _sanadHomeOverride = path;
}

void setSanadStateHomeOverride(String? path) {
  _sanadStateHomeOverride = path;
}

/// The Home selected with [setSanadHomeOverride], if any.
String? get sanadHomeOverride => _sanadHomeOverride;

/// Normalizes a `--home` option value: blank selects nothing, anything else
/// becomes an absolute normalized path resolved against the working directory.
String? normalizeSanadHomeOption(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return p.normalize(p.absolute(trimmed));
}

/// Whether this process runs the deterministic E2E runtime
/// (`SANAD_E2E_TEST_MODE=true`), which test harnesses set together with
/// temporary `SANAD_HOME` and `SANAD_STATE_HOME` roots.
bool isSanadE2eTestMode() =>
    Platform.environment['SANAD_E2E_TEST_MODE']?.trim().toLowerCase() == 'true';

/// Selects [home] as this process's Sanad Home.
///
/// An explicit Home is authoritative and self-contained: identity,
/// credentials, the vault and runtime state all resolve inside it, so an
/// inherited `SANAD_HOME` or `SANAD_STATE_HOME` can never leak another Home's
/// state into the selected one. Entry points call this before any Home access.
///
/// The one exception is the E2E runtime ([isSanadE2eTestMode]): its harness
/// sets `SANAD_STATE_HOME` deliberately, separate from the identity Home, and
/// E2E isolation requires that separation, so an explicitly set
/// `SANAD_STATE_HOME` keeps owning runtime state there.
void selectSanadHome(String home) {
  setSanadHomeOverride(home);
  final stateHome = Platform.environment['SANAD_STATE_HOME']?.trim() ?? '';
  if (isSanadE2eTestMode() && stateHome.isNotEmpty) {
    setSanadStateHomeOverride(null);
    return;
  }
  setSanadStateHomeOverride(home);
}

/// Whether runtime state has been explicitly redirected away from the
/// process's inherited Sanad Home.
///
/// Tests use this signal to prove that an on-disk state database is isolated
/// before it is opened. `SANAD_HOME` alone is intentionally not sufficient:
/// developer test commands commonly inherit the user's real Sanad Home.
bool hasExplicitSanadStateIsolation() {
  if (_sanadHomeOverride != null || _sanadStateHomeOverride != null) {
    return true;
  }
  final stateHome = Platform.environment['SANAD_STATE_HOME'];
  return stateHome != null && stateHome.isNotEmpty;
}

/// Returns the path to the Sanad home directory.
///
/// [resolveSanadHomePath] owns the order: an explicit selection (`--home`),
/// then `SANAD_HOME`, then the Home that recorded this executable's
/// installation, and finally the OS user's `$HOME/.sanad`.
String getSanadHome() {
  final home = resolveSanadHomePath(
    override: _sanadHomeOverride,
    environmentHome: Platform.environment['SANAD_HOME'],
    installedHome: InstalledHomeRecord.current(),
    defaultHome: defaultSanadHome(),
  );
  if (home == null) {
    throw Exception("Could not determine home directory.");
  }
  return home;
}

/// Resolves the active Home from its ordered sources.
///
/// * [override] is the Home this process selected itself (`--home`).
/// * [environmentHome] is an inherited `SANAD_HOME`.
/// * [installedHome] is the Home whose install record sits beside this
///   executable ([InstalledHomeRecord]).
/// * [defaultHome] is the OS user's `$HOME/.sanad`.
///
/// An operator's explicit selection always wins: it is the only source that can
/// address a Home this machine does not otherwise describe. The install record
/// answers before the account default, because an installed Agent belongs to the
/// Home that installed it, and a dedicated service account has `$HOME` equal to
/// that Home: the default would name a second, empty Home and every service
/// command would misreport a healthy unit. A blank value selects nothing.
String? resolveSanadHomePath({
  required String? override,
  required String? environmentHome,
  required String? installedHome,
  required String? defaultHome,
}) {
  for (final candidate in <String?>[
    override,
    environmentHome,
    installedHome,
    defaultHome,
  ]) {
    if (candidate != null && candidate.trim().isNotEmpty) return candidate;
  }
  return null;
}

/// The default Sanad Home of the OS user (`$HOME/.sanad`, or
/// `%USERPROFILE%\.sanad`), ignoring every override; `null` when the user
/// home directory is unknown.
String? defaultSanadHome() {
  final String? home = Platform.isWindows
      ? Platform.environment['USERPROFILE']
      : Platform.environment['HOME'];
  if (home == null) return null;
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
