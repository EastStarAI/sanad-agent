/// Typed, bounded, and sanitized platform trust diagnostics shared by the
/// Agent updater and the Client bootstrap installer.
library;

import 'dart:io';

/// The stage at which a downloaded release artifact was rejected.
///
/// Every stage is fail-closed: an untrusted result is never accepted for
/// installation, whatever the stage.
enum PlatformTrustStage {
  /// The manifest artifact metadata violated the shared trust policy.
  metadataValidation('metadata_validation'),

  /// The code signature itself is missing, invalid, or modified
  /// (`codesign` exit status 1).
  codesignVerification('codesign_verification'),

  /// The signature is valid but does not satisfy the exact Apple-anchored
  /// publisher requirement (`codesign` exit status 3).
  publisherRequirement('publisher_requirement'),

  /// The Windows Authenticode status was not `Valid`.
  authenticodeSignature('authenticode_signature'),

  /// The platform verifier could not run (missing tool or launch failure).
  verifierUnavailable('verifier_unavailable'),

  /// A caller-supplied boolean verifier rejected the artifact without detail.
  platformVerifier('platform_verifier');

  const PlatformTrustStage(this.wireName);

  final String wireName;
}

/// Result of a platform trust verification.
class PlatformTrustResult {
  const PlatformTrustResult.trusted()
    : isTrusted = true,
      stage = null,
      exitCode = null,
      detail = null;

  const PlatformTrustResult.untrusted({
    required PlatformTrustStage this.stage,
    this.exitCode,
    this.detail,
  }) : isTrusted = false;

  final bool isTrusted;
  final PlatformTrustStage? stage;
  final int? exitCode;

  /// Sanitized, single-line, bounded verifier output. Producers must pass raw
  /// tool output through [sanitizePlatformVerifierOutput] before storing it.
  final String? detail;

  /// One-line diagnostic such as `stage=publisher_requirement: exit=3: ...`.
  String get summary {
    if (isTrusted) return 'trusted';
    final detail = this.detail?.trim();
    return [
      'stage=${stage!.wireName}',
      if (exitCode != null) 'exit=$exitCode',
      if (detail != null && detail.isNotEmpty) detail,
    ].join(': ');
  }

  @override
  String toString() => 'PlatformTrustResult($summary)';
}

/// Maximum length of a sanitized verifier diagnostic.
const platformVerifierDetailMaxLength = 500;

/// Removes private local paths, control sequences, and excess length from raw
/// platform verifier output.
///
/// [filePath] (the staged artifact) becomes `<artifact>`; the current user's
/// home and temporary directories become `<home>` and `<temp>`; any remaining
/// per-user directory segment becomes `<user>`. [environment] defaults to the
/// process environment and is injectable for tests.
String sanitizePlatformVerifierOutput(
  String raw, {
  String? filePath,
  Map<String, String>? environment,
}) {
  var text = raw
      .replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ');

  final artifact = filePath?.trim() ?? '';
  if (artifact.isNotEmpty) {
    // codesign may print the resolved form of macOS /var and /tmp symlinks.
    for (final candidate in {'/private$artifact', artifact}) {
      text = text.replaceAll(candidate, '<artifact>');
    }
  }

  final env = environment ?? _processEnvironment();
  final privateRoots = <String, String>{
    for (final key in const ['TMPDIR', 'TEMP', 'TMP'])
      if (_usableRoot(env[key])) _trimSeparator(env[key]!): '<temp>',
    for (final key in const ['HOME', 'USERPROFILE'])
      if (_usableRoot(env[key])) _trimSeparator(env[key]!): '<home>',
  };
  // Longest first so a temp directory inside home is not half-replaced.
  final ordered = privateRoots.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final root in ordered) {
    final replacement = privateRoots[root]!;
    text = text.replaceAll('/private$root', replacement);
    text = text.replaceAll(root, replacement);
  }

  text = text
      .replaceAll(RegExp(r'(/private)?/var/folders/[^\s:]+'), '<temp>')
      .replaceAll(RegExp(r'/Users/[^/\s:]+'), '/Users/<user>')
      .replaceAll(RegExp(r'/home/[^/\s:]+'), '/home/<user>')
      .replaceAllMapped(
        RegExp(r'([A-Za-z]):\\Users\\[^\\\s:]+'),
        (match) => '${match.group(1)}:\\Users\\<user>',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  if (text.length > platformVerifierDetailMaxLength) {
    final runes = text.runes.take(platformVerifierDetailMaxLength - 3);
    text = '${String.fromCharCodes(runes)}...';
  }
  return text;
}

bool _usableRoot(String? value) {
  final trimmed = value?.trim() ?? '';
  // Never treat a filesystem root or a bare drive as a private prefix.
  return trimmed.length > 3;
}

String _trimSeparator(String value) {
  final trimmed = value.trim();
  return trimmed.endsWith('/') || trimmed.endsWith(r'\')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

Map<String, String> _processEnvironment() {
  try {
    return Platform.environment;
  } catch (_) {
    return const {};
  }
}

/// Official installer endpoints and recovery commands.
///
/// These are the only hosts recovery guidance may name. The POSIX command
/// downloads the script before running it so the user can inspect it.
abstract final class OfficialAgentInstaller {
  static const posixScriptUrl = 'https://sanad.eaststarai.com/install.sh';
  static const windowsScriptUrl = 'https://sanad.eaststarai.com/install.ps1';

  /// A recovery command that reinstalls the verified Agent without starting a
  /// new interactive sign-in. Existing authentication is retained.
  static String recoveryCommand(String operatingSystem) =>
      operatingSystem == 'windows'
      ? '$_windowsInvocation -NoLogin'
      : 'curl -fsSL $posixScriptUrl -o install.sh && bash install.sh --no-login';

  /// The Add device command. The installer reads [token] and passes it to the
  /// Agent through stdin; the token is quoted for its shell and never logged.
  static String pairingCommand(String operatingSystem, String token) =>
      operatingSystem == 'windows'
      ? '$_windowsInvocation -PairingToken ${_quotePowerShell(token)}'
      : 'curl -fsSL $posixScriptUrl | bash -s -- --pairing-token ${_quotePosix(token)}';

  static const _windowsInvocation =
      '& ([scriptblock]::Create((irm $windowsScriptUrl)))';

  static String _quotePosix(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static String _quotePowerShell(String value) =>
      "'${value.replaceAll("'", "''")}'";
}
