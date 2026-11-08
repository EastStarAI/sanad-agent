import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:test/test.dart';

import '../support/native_binary_fixture.dart';

/// The daemon must tell the difference between "the native runtime is being
/// built right now" and "it was never installed": the first one is a transient
/// state the UI shows as preparing, the second one asks the developer to act.
///
/// It must also refuse to call a runtime ready when the directory holds the
/// other CPU architecture: that build loads nowhere, so reporting it as ready
/// only moves the failure into the first dictation session.
void main() {
  late Directory home;
  late Directory workdir;
  late Directory previous;

  String platformDir() =>
      SttNativeTarget.tryCurrent()?.nativeDirectory ?? 'macos';

  setUp(() {
    home = Directory.systemTemp.createTempSync('native-readiness-home-');
    workdir = Directory.systemTemp.createTempSync('native-readiness-cwd-');
    // The loader searches `$cwd/native/<tag>/`, so the working directory is the
    // simplest way to model a checkout without the native runtime.
    Directory('${workdir.path}/native/${platformDir()}')
        .createSync(recursive: true);
    previous = Directory.current;
    Directory.current = workdir;
  });

  tearDown(() {
    Directory.current = previous;
    for (final dir in [home, workdir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  DictationService service() {
    File('${home.path}/config.yaml').writeAsStringSync(
      'stt:\n  model_id: egy-whisper-turbo-ggml-q8\n',
    );
    return DictationService(sanadHome: home.path, platformSupported: true);
  }

  test('a missing native runtime is reported as such', () {
    final readiness = service().readiness();
    expect(readiness.reason, 'native_runtime_missing');
    // The device *can* dictate; only the engine is not on disk yet. Keeping
    // `isSupported` true is what keeps the mic button visible.
    expect(readiness.isSupported, isTrue);
    expect(readiness.isReady, isFalse);
  });

  test('an in-flight build is reported as preparing', () {
    File(
      '${workdir.path}/native/${platformDir()}/.stt-preparing',
    ).writeAsStringSync(DateTime.now().toUtc().toIso8601String());

    expect(service().readiness().reason, 'native_runtime_preparing');
    expect(service().readiness().isSupported, isTrue);
  });

  test('the marker the install tool writes in the native root is seen', () {
    // `tool/ensure_native_stt.dart` writes `native/.stt-preparing` before the
    // architecture directory exists, so readiness has to look there too.
    File(
      '${workdir.path}/native/$sttPreparingMarkerName',
    ).writeAsStringSync(DateTime.now().toUtc().toIso8601String());

    expect(service().readiness().reason, 'native_runtime_preparing');
  });

  test('a stale marker expires instead of sticking forever', () {
    final marker = File(
      '${workdir.path}/native/${platformDir()}/.stt-preparing',
    )..writeAsStringSync('crashed build');
    marker.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 2)),
    );

    expect(service().readiness().reason, 'native_runtime_missing');
  });

  test('a foreign-architecture build is not reported as available', () {
    final target = SttNativeTarget.tryCurrent();
    if (target == null) {
      markTestSkipped('no native dictation runtime target for this ABI');
      return;
    }
    final otherCpu = target.cpu == SttNativeCpu.x64
        ? SttNativeCpu.arm64
        : SttNativeCpu.x64;
    File(
      '${workdir.path}/native/${target.nativeDirectory}/${target.shimFileName}',
    ).writeAsBytesSync(nativeBinaryFor(target.os, otherCpu));

    expect(service().readiness().reason, 'native_runtime_missing');
  });
}
