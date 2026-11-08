import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:test/test.dart';

/// The daemon must tell the difference between "the native runtime is being
/// built right now" and "it was never installed": the first one is a transient
/// state the UI shows as preparing, the second one asks the developer to act.
void main() {
  late Directory home;
  late Directory workdir;
  late Directory previous;

  String platformDir() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'linux';
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('native-readiness-home-');
    workdir = Directory.systemTemp.createTempSync('native-readiness-cwd-');
    // The loader searches `$cwd/native/<platform>/`, so the working directory is
    // the simplest way to model a checkout without the native runtime.
    (Directory('${workdir.path}/native/${platformDir()}')
          ..createSync(recursive: true));
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

  test('a stale marker expires instead of sticking forever', () {
    final marker = File(
      '${workdir.path}/native/${platformDir()}/.stt-preparing',
    )..writeAsStringSync('crashed build');
    marker.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 2)),
    );

    expect(service().readiness().reason, 'native_runtime_missing');
  });
}
