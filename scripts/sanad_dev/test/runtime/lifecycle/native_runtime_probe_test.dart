import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

/// The native runner layout is `native/<platform>-<architecture>/`. The probe
/// must look there, and must not spawn an installer when the slice is present:
/// an unqualified probe never saw the qualified directory, so every `run`
/// started a background build behind an already-working runtime.
void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sanad-dev-native-probe-',
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  String shimName() {
    if (Platform.isMacOS) return 'libsanad_whisper.dylib';
    if (Platform.isWindows) return 'sanad_whisper.dll';
    return 'libsanad_whisper.so';
  }

  group('native runtime tag', () {
    test('every supported pair resolves to a qualified directory', () {
      for (final os in ['macos', 'linux', 'windows']) {
        for (final architecture in ['arm64', 'x64']) {
          expect(
            sanad_dev.nativeRuntimeTag(
              operatingSystem: os,
              architecture: architecture,
            ),
            '$os-$architecture',
          );
        }
      }
    });

    test('an unknown host pair stays unqualified instead of guessing', () {
      expect(
        sanad_dev.nativeRuntimeTag(
          operatingSystem: 'freebsd',
          architecture: 'arm64',
        ),
        isNull,
      );
      expect(
        sanad_dev.nativeRuntimeTag(
          operatingSystem: 'macos',
          architecture: 'mips',
        ),
        isNull,
      );
    });
  });

  group('prepare probe', () {
    test('a qualified runtime means nothing is started', () async {
      final tag = sanad_dev.nativeRuntimeTag();
      final directory = Directory('${temporaryDirectory.path}/native/$tag');
      await directory.create(recursive: true);
      await File('${directory.path}/${shimName()}').writeAsString('stub');

      final started = <String>[];
      final launched = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        starter: (command, workingDirectory) async => started.add(command),
      );

      expect(launched, isFalse);
      expect(started, isEmpty);
    });

    test('a missing qualified runtime starts the installer once', () async {
      final started = <String>[];
      final launched = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        starter: (command, workingDirectory) async {
          started.add(command);
          expect(workingDirectory, temporaryDirectory.path);
        },
      );

      expect(launched, isTrue);
      expect(started.single, contains('ensure_native_stt.dart'));
    });

    test('a failing installer never throws at the caller', () async {
      // Dictation is the only thing a missing runtime takes away: the launcher
      // still starts the daemon and the Client, and readiness reports the reason.
      final launched = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        starter: (command, workingDirectory) async {
          throw const ProcessException('fvm', ['dart']);
        },
      );

      expect(launched, isFalse);
    });

    test('the unqualified macOS directory is only a bounded legacy alias',
        () async {
      // A foreign architecture's unqualified slice must never be treated as this
      // host's runtime: only Apple Silicon ever shipped one.
      final tag = sanad_dev.nativeRuntimeTag();
      final legacy = Directory('${temporaryDirectory.path}/native/macos');
      await legacy.create(recursive: true);
      await File('${legacy.path}/${shimName()}').writeAsString('stub');

      var startedCount = 0;
      await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        starter: (command, workingDirectory) async => startedCount++,
      );

      if (tag == 'macos-arm64') {
        expect(startedCount, 0);
      } else {
        expect(startedCount, 1);
      }
    });
  });
}
