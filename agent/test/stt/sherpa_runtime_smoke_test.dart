import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:sanad_stt_sherpa/sanad_stt_sherpa.dart';
import 'package:test/test.dart';

/// The packaged sherpa-onnx runtime must load from the archive a released Agent
/// installs, not only from the pub cache a developer machine happens to have.
///
/// The loader is given exactly one directory and appends its own per-platform
/// path to it, so this test points `initBindings` at
/// `native/<tag>/sherpa/` and proves the archive's layout is the layout the
/// engine expects. `initBindings` resolves every exported symbol eagerly, so a
/// missing or truncated library fails here rather than at the first session.
///
/// Release staging and the PR native-dictation lane set
/// `SANAD_SHERPA_REQUIRE_NATIVE=1`; a developer checkout without a packaged
/// runtime skips. A build that links the stand-in engine has nothing to load and
/// asserts only that it says so.
void main() {
  final required = Platform.environment['SANAD_SHERPA_REQUIRE_NATIVE'] == '1';
  final target = SttNativeTarget.tryCurrent();

  test('the packaged sherpa runtime loads for this CPU architecture', () {
    if (!sherpaEngineAvailable) {
      // The Linux arm64 Agent is built without the engine; the stub must be the
      // reason, not a platform guess.
      expect(sherpaNativeSourceDirectory(), isNull);
      markTestSkipped('this build links the whisper-only engine stand-in');
      return;
    }
    if (target == null) {
      if (required) {
        fail(
          'SANAD_SHERPA_REQUIRE_NATIVE=1 but ${Abi.current()} has no runtime '
          'target',
        );
      }
      markTestSkipped('no native dictation runtime target for this ABI');
      return;
    }

    // `SANAD_STT_RUNTIME_DIR` is the staged payload a release job just built;
    // without it the staged directories a PR lane produces and then the
    // checkout's own `native/<tag>/sherpa/` are tried.
    final staged = Platform.environment['SANAD_STT_RUNTIME_DIR']?.trim();
    final candidates = <String>[
      if (staged != null && staged.isNotEmpty) staged,
      '${Directory.current.path}/../dist/native/${target.nativeDirectory}'
          '/${target.sherpaNativeSubdirectory}',
      '${Directory.current.path}/../dist-native/native/'
          '${target.nativeDirectory}/${target.sherpaNativeSubdirectory}',
      '${Directory.current.path}/native/${target.nativeDirectory}'
          '/${target.sherpaNativeSubdirectory}',
    ];
    final directory = candidates.firstWhere(
      (path) => File('$path/${target.sherpaLibraries.first}').existsSync(),
      orElse: () => candidates.first,
    );
    final probe = File('$directory/${target.sherpaLibraries.first}');
    if (!probe.existsSync()) {
      if (required) {
        fail(
          'SANAD_SHERPA_REQUIRE_NATIVE=1 but no packaged sherpa runtime was '
          'found at ${probe.path}',
        );
      }
      markTestSkipped('no packaged sherpa runtime in this checkout');
      return;
    }

    final info = inspectNativeLibraryFile(probe.path);
    expect(
      info.isRecognized,
      isTrue,
      reason: '${probe.path} is not a recognizable native library',
    );
    expect(
      info.supports(target.cpu),
      isTrue,
      reason:
          '${probe.path} holds ${info.cpus.map((cpu) => cpu.name).join('+')} '
          'but this process needs ${target.cpu.name}',
    );

    // The real proof: the engine opens the packaged library and resolves every
    // symbol it binds. No model is opened and no audio is decoded.
    expect(
      () => sherpaInitBindings(directory),
      returnsNormally,
      reason: 'the packaged runtime at $directory did not load',
    );
  });
}
