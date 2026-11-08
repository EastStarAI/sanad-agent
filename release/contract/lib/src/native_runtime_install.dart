import 'dart:io';

/// Cross-component contract for the packaged native dictation runtime.
///
/// The `agent-runtime` archive is an optional companion of the Agent payload: a
/// failure to download, verify, or extract it disables **dictation only**. The
/// Agent still installs, updates, and runs, because a user who never dictates
/// must not lose the product to a transient artifact or attestation failure.
///
/// Trust strictness is unchanged: nothing here relaxes verification, and an
/// unverified library is never extracted or loaded. What changes is who pays for
/// a failure — dictation readiness instead of the Agent install.
///
/// The failing component records exactly one machine-readable cause beside the
/// runtime (`<exe dir>/native/.runtime-install-failed`). The daemon reports
/// [readinessReason] while that marker exists, the Client localizes it, and any
/// later successful runtime install clears it. The file is one plain line so the
/// POSIX and PowerShell installers can write it without a JSON writer.
class NativeRuntimeInstall {
  const NativeRuntimeInstall._();

  /// Marker file name inside the native root (`<exe dir>/native`).
  static const String failureMarkerName = '.runtime-install-failed';

  /// The single readiness reason the daemon reports for a failed runtime
  /// install. It is a stable machine code: the precise cause stays in
  /// [failureMarkerName] and the Agent log, and the Client owns the sentence.
  static const String readinessReason = 'native_runtime_install_failed';

  /// A download that never produced a complete archive.
  static const String downloadFailed = 'runtime_download_failed';

  /// Size or SHA-256 did not match the manifest.
  static const String checksumFailed = 'runtime_checksum_failed';

  /// The declared platform trust policy rejected the archive.
  static const String trustFailed = 'runtime_trust_failed';

  /// The archive members were refused before extraction.
  static const String layoutRejected = 'runtime_layout_rejected';

  /// The verified directory could not be swapped into place.
  static const String replaceFailed = 'runtime_replace_failed';

  /// A generic install failure (used by the shell installers, which report the
  /// precise cause in their own output).
  static const String installFailed = 'runtime_install_failed';

  /// Every cause this contract accepts. Anything else is treated as unknown and
  /// is never surfaced as a readiness reason.
  static const List<String> causes = <String>[
    downloadFailed,
    checksumFailed,
    trustFailed,
    layoutRejected,
    replaceFailed,
    installFailed,
  ];

  static bool isKnownCause(String cause) => causes.contains(cause);

  static File markerFile(Directory nativeRoot) =>
      File('${nativeRoot.path}/$failureMarkerName');

  /// The recorded cause, or null when no failure is recorded or the marker is
  /// not a known code.
  static String? read(Directory nativeRoot) {
    try {
      final file = markerFile(nativeRoot);
      if (!file.existsSync()) return null;
      final value = file.readAsStringSync().trim();
      return isKnownCause(value) ? value : null;
    } on Object {
      return null;
    }
  }

  /// Records [cause] for the next readiness report.
  ///
  /// Best effort on purpose: a marker that cannot be written must never turn a
  /// dictation problem into an install failure.
  static Future<void> record(Directory nativeRoot, String cause) async {
    try {
      await nativeRoot.create(recursive: true);
      await markerFile(nativeRoot).writeAsString('$cause\n', flush: true);
    } on Object {
      // Reporting only.
    }
  }

  /// Clears a previous failure after a successful install, or when the release
  /// publishes no runtime at all (that is `native_runtime_missing`, not a
  /// failure).
  static Future<void> clear(Directory nativeRoot) async {
    try {
      final file = markerFile(nativeRoot);
      if (file.existsSync()) await file.delete();
    } on Object {
      // Reporting only.
    }
  }
}
