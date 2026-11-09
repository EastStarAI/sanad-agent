import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:sanad_agent/infrastructure/stt/whispercpp_bindings.dart';
import 'package:test/test.dart';

import '../../tool/stt_native_runtime.dart';

/// The native dictation runtime must load in a real process of the architecture
/// that built it, and never be advertised from a directory holding the other
/// slice.
///
/// PR CI builds whisper.cpp for the runner (`ubuntu-24.04`, `macos-26`,
/// `macos-15-intel`, `windows-2025`) and sets `SANAD_STT_REQUIRE_NATIVE=1`, so a
/// missing or foreign-architecture runtime fails there instead of silently
/// skipping. A developer checkout without the build skips.
void main() {
  final required = Platform.environment['SANAD_STT_REQUIRE_NATIVE'] == '1';
  final target = SttNativeTarget.tryCurrent();
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;

  test('the packaged native runtime loads for this CPU architecture', () {
    if (target == null) {
      if (required) {
        fail(
          'SANAD_STT_REQUIRE_NATIVE=1 but ${Abi.current()} has no runtime target',
        );
      }
      markTestSkipped('no native dictation runtime target for this ABI');
      return;
    }

    // `SANAD_WHISPER_LIBRARY` is the production override the daemon itself
    // honours, so pointing the smoke at another directory proves that the
    // packaged layout — not only the checkout — loads in a real process.
    final override = Platform.environment['SANAD_WHISPER_LIBRARY']?.trim();
    final explicit = override != null && override.isNotEmpty;
    final path = explicit ? override : WhisperCppLibrary.defaultLibraryPath;
    if (!File(path).existsSync()) {
      if (required) {
        fail(
          'SANAD_STT_REQUIRE_NATIVE=1 but no runtime was found at $path',
        );
      }
      markTestSkipped('native runtime is not built in this checkout: $path');
      return;
    }

    final info = inspectNativeLibraryFile(path);
    expect(
      info.isRecognized,
      isTrue,
      reason: '$path is not a recognizable native library',
    );
    expect(
      info.supports(target.cpu),
      isTrue,
      reason:
          '$path holds ${info.cpus.map((cpu) => cpu.name).join('+')} but this '
          'process needs ${target.cpu.name}',
    );
    if (Platform.isMacOS && required) {
      // A runtime built by the current scripts records the shipped Client's
      // macOS floor. The assertion is scoped to the build lanes: an older
      // developer build predates the deployment-target flag and is reported by
      // `tool/ensure_native_stt.dart --verify` instead of failing every test run.
      final minimum = info.minimumMacOsVersion;
      expect(minimum, isNotNull, reason: '$path records no deployment target');
      expect(
        compareVersions(minimum!, target.macosDeploymentTarget!),
        lessThanOrEqualTo(0),
        reason: '$path needs macOS $minimum',
      );
    }

    if (explicit) {
      final normalized = path.replaceAll('\\', '/');
      expect(
        normalized,
        contains('/native/${target.nativeDirectory}/'),
        reason: 'the override must point inside a packaged native/<tag> layout',
      );
    } else {
      expect(
        nativeLibraryCandidates(
          target: target,
          executableDirectory: executableDirectory,
          workingDirectory: Directory.current.path,
        ),
        contains(path),
      );
    }
    expect(WhisperCppLibrary.platformDir, target.nativeDirectory);
    if (!explicit) {
      expect(WhisperCppLibrary.isAvailable, isTrue);
    }

    // Opening the shim loads its whisper/ggml siblings through the self-relative
    // rpath and resolves the three exported functions, which is the real loader
    // proof for this architecture. No model is opened and no audio is decoded.
    final library = WhisperCppLibrary.open(path);
    expect(library.library, isNotNull);
  });
}
