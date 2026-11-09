import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:test/test.dart';

import '../support/native_binary_fixture.dart';

/// The platform tag drives the native directory, the manifest key, and the
/// staged release directory at once, so the mapping is a contract: it must be
/// derived from the running ABI, cover macOS Intel explicitly, and never let a
/// foreign-architecture build look loadable.
void main() {
  group('ABI mapping', () {
    test('maps every architecture the runtime ships for', () {
      expect(SttNativeTarget.fromAbi(Abi.macosArm64).tag, 'macos-arm64');
      expect(SttNativeTarget.fromAbi(Abi.macosX64).tag, 'macos-x64');
      expect(SttNativeTarget.fromAbi(Abi.windowsX64).tag, 'windows-x64');
      expect(SttNativeTarget.fromAbi(Abi.windowsArm64).tag, 'windows-arm64');
      expect(SttNativeTarget.fromAbi(Abi.linuxX64).tag, 'linux-x64');
      expect(SttNativeTarget.fromAbi(Abi.linuxArm64).tag, 'linux-arm64');
    });

    test('does not invent a target for unsupported ABIs', () {
      // Mobile ABIs are the real "no native dictation runtime" case.
      expect(SttNativeTarget.tryFromAbi(Abi.iosArm64), isNull);
      expect(SttNativeTarget.tryFromAbi(Abi.androidArm64), isNull);
      expect(
        () => SttNativeTarget.fromAbi(Abi.iosArm64),
        throwsUnsupportedError,
      );
    });

    test('resolves the running process through Abi.current', () {
      final current = Abi.current();
      final target = SttNativeTarget.tryCurrent();
      expect(target, SttNativeTarget.tryFromAbi(current));
    });

    test('tags are unique and match the supported platform shape', () {
      final tags = SttNativeTarget.values.map((target) => target.tag).toList();
      expect(tags.toSet(), hasLength(tags.length));
      for (final tag in tags) {
        expect(
          RegExp(r'^(macos|windows|linux)-(x64|arm64)$').hasMatch(tag),
          isTrue,
          reason: tag,
        );
      }
    });

    test('the manifest key is the native directory name', () {
      for (final target in SttNativeTarget.values) {
        expect(target.nativeDirectory, target.tag, reason: target.tag);
      }
    });
  });

  group('platform scope', () {
    test('macOS Intel is a supported dictation platform', () {
      // The daemon gate reads this flag; without it an Intel Client advertises
      // `unsupported_platform` even though the runtime can be built.
      expect(SttNativeTarget.macosX64.dictationSupported, isTrue);
      expect(SttNativeTarget.macosArm64.dictationSupported, isTrue);
      for (final target in SttNativeTarget.values) {
        expect(target.dictationSupported, isTrue, reason: target.tag);
      }
    });

    test('Metal stays an Apple Silicon build product', () {
      expect(SttNativeTarget.macosArm64.usesMetal, isTrue);
      expect(
        SttNativeTarget.macosArm64.requiredLibraries,
        contains('libggml-metal.0.dylib'),
      );
      expect(SttNativeTarget.macosX64.usesMetal, isFalse);
      expect(
        SttNativeTarget.macosX64.requiredLibraries,
        isNot(contains('libggml-metal.0.dylib')),
      );
      for (final target in [
        SttNativeTarget.windowsX64,
        SttNativeTarget.windowsArm64,
        SttNativeTarget.linuxX64,
        SttNativeTarget.linuxArm64,
      ]) {
        expect(target.usesMetal, isFalse, reason: target.tag);
      }
    });

    test('macOS Intel uses the dylib family with a CPU-only baseline', () {
      final libraries = SttNativeTarget.macosX64.requiredLibraries;
      expect(libraries.first, 'libsanad_whisper.dylib');
      expect(
        libraries.every((name) => name.endsWith('.dylib')),
        isTrue,
        reason: libraries.join(', '),
      );
      expect(
        libraries,
        [
          'libsanad_whisper.dylib',
          'libwhisper.1.dylib',
          'libggml.0.dylib',
          'libggml-base.0.dylib',
          'libggml-cpu.0.dylib',
          'libggml-blas.0.dylib',
        ],
      );
    });

    test('Apple Silicon keeps its original Metal-enabled file list', () {
      expect(SttNativeTarget.macosArm64.requiredLibraries, [
        'libsanad_whisper.dylib',
        'libwhisper.1.dylib',
        'libggml.0.dylib',
        'libggml-base.0.dylib',
        'libggml-cpu.0.dylib',
        'libggml-blas.0.dylib',
        'libggml-metal.0.dylib',
      ]);
    });

    test('Windows and Linux file lists are unchanged', () {
      expect(SttNativeTarget.windowsX64.requiredLibraries, [
        'sanad_whisper.dll',
        'whisper.dll',
        'ggml.dll',
        'ggml-base.dll',
        'ggml-cpu.dll',
      ]);
      expect(SttNativeTarget.windowsArm64.requiredLibraries, [
        'sanad_whisper.dll',
        'whisper.dll',
        'ggml.dll',
        'ggml-base.dll',
        'ggml-cpu.dll',
      ]);
      expect(SttNativeTarget.linuxX64.requiredLibraries, [
        'libsanad_whisper.so',
        'libwhisper.so.1',
        'libggml.so.0',
        'libggml-base.so.0',
        'libggml-cpu.so.0',
      ]);
      expect(SttNativeTarget.linuxArm64.requiredLibraries, [
        'libsanad_whisper.so',
        'libwhisper.so.1',
        'libggml.so.0',
        'libggml-base.so.0',
        'libggml-cpu.so.0',
      ]);
    });
  });

  group('paths', () {
    test('only Apple Silicon keeps the pre-qualification directory', () {
      expect(SttNativeTarget.macosArm64.legacyNativeDirectory, 'macos');
      expect(
        SttNativeTarget.macosArm64.nativeDirectoryNames,
        ['macos-arm64', 'macos'],
      );
      for (final target in [
        SttNativeTarget.macosX64,
        SttNativeTarget.windowsX64,
        SttNativeTarget.windowsArm64,
        SttNativeTarget.linuxX64,
        SttNativeTarget.linuxArm64,
      ]) {
        // An unqualified directory could hold either architecture on these
        // platforms, so it is never accepted as a fallback.
        expect(target.legacyNativeDirectory, isNull, reason: target.tag);
        expect(target.nativeDirectoryNames, [target.nativeDirectory]);
      }
    });

    test('candidates prefer the executable, then the checkout', () {
      final candidates = nativeLibraryCandidates(
        target: SttNativeTarget.macosX64,
        executableDirectory: '/opt/sanad',
        workingDirectory: '/repo/agent',
      );
      expect(candidates.first, '/opt/sanad/native/macos-x64/libsanad_whisper.dylib');
      expect(candidates, contains('/repo/agent/native/macos-x64/libsanad_whisper.dylib'));
      expect(candidates, contains('/repo/agent/agent/native/macos-x64/libsanad_whisper.dylib'));
      expect(
        candidates.where((path) => path.contains('/native/macos/')),
        isEmpty,
      );
    });

    test('Apple Silicon probes the qualified directory before the legacy one', () {
      final candidates = nativeLibraryCandidates(
        target: SttNativeTarget.macosArm64,
        executableDirectory: '/opt/sanad',
        workingDirectory: '/repo/agent',
      );
      final qualified = candidates.indexWhere(
        (path) => path == '/opt/sanad/native/macos-arm64/libsanad_whisper.dylib',
      );
      final legacy = candidates.indexWhere(
        (path) => path == '/opt/sanad/native/macos/libsanad_whisper.dylib',
      );
      expect(qualified, isNonNegative);
      expect(legacy, greaterThan(qualified));
    });

    test('an explicit override wins over every location', () {
      final candidates = nativeLibraryCandidates(
        target: SttNativeTarget.linuxX64,
        executableDirectory: '/opt/sanad',
        workingDirectory: '/repo/agent',
        overridePath: '/tmp/custom/libsanad_whisper.so',
      );
      expect(candidates, ['/tmp/custom/libsanad_whisper.so']);
    });

    test('a blank override is ignored', () {
      final candidates = nativeLibraryCandidates(
        target: SttNativeTarget.linuxX64,
        executableDirectory: '/opt/sanad',
        workingDirectory: '/repo/agent',
        overridePath: '  ',
      );
      expect(candidates.first, '/opt/sanad/native/linux-x64/libsanad_whisper.so');
    });

    test('the preparing marker is probed at the native root as well', () {
      final markers = preparingMarkerCandidates(
        target: SttNativeTarget.macosX64,
        executableDirectory: '/opt/sanad',
        workingDirectory: '/repo/agent',
      );
      // `tool/ensure_native_stt.dart` writes `native/.stt-preparing` before the
      // architecture directory exists, so readiness must look there.
      expect(markers, contains('/opt/sanad/native/$sttPreparingMarkerName'));
      expect(markers, contains('/repo/agent/native/$sttPreparingMarkerName'));
      expect(
        markers,
        contains(
          '/repo/agent/native/macos-x64/$sttPreparingMarkerName',
        ),
      );
    });
  });

  group('binary inspection', () {
    test('reads both Mach-O architectures and the deployment target', () {
      final x64 = inspectNativeBinary(
        machOThin(cpu: SttNativeCpu.x64, minimumMacOs: '12.0'),
      );
      expect(x64.format, SttNativeBinaryFormat.machO);
      expect(x64.cpus, {SttNativeCpu.x64});
      expect(x64.minimumMacOsVersion, '12.0');

      final arm64 = inspectNativeBinary(
        machOThin(cpu: SttNativeCpu.arm64, minimumMacOs: '14.2'),
      );
      expect(arm64.cpus, {SttNativeCpu.arm64});
      expect(arm64.minimumMacOsVersion, '14.2');
    });

    test('reads every slice of a universal binary', () {
      final info = inspectNativeBinary(
        machOFat([SttNativeCpu.x64, SttNativeCpu.arm64]),
      );
      expect(info.format, SttNativeBinaryFormat.machO);
      expect(info.cpus, unorderedEquals([SttNativeCpu.x64, SttNativeCpu.arm64]));
      expect(info.minimumMacOsVersion, isNull);
    });

    test('reads ELF and PE machine types', () {
      expect(
        inspectNativeBinary(elfBinary(SttNativeCpu.x64)).cpus,
        {SttNativeCpu.x64},
      );
      expect(
        inspectNativeBinary(elfBinary(SttNativeCpu.arm64)).cpus,
        {SttNativeCpu.arm64},
      );
      expect(
        inspectNativeBinary(peBinary(SttNativeCpu.x64)).cpus,
        {SttNativeCpu.x64},
      );
      expect(
        inspectNativeBinary(peBinary(SttNativeCpu.arm64)).cpus,
        {SttNativeCpu.arm64},
      );
    });

    test('an unrecognizable file is never treated as a library', () {
      expect(
        inspectNativeBinary(Uint8List.fromList([0x00, 0x01, 0x02, 0x03]))
            .isRecognized,
        isFalse,
      );
      expect(inspectNativeBinary(Uint8List(0)).isRecognized, isFalse);
    });

    test('a foreign-architecture file does not match the target', () {
      final directory = Directory.systemTemp.createTempSync('stt-native-arch-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/libsanad_whisper.dylib')
        ..writeAsBytesSync(
          machOThin(cpu: SttNativeCpu.arm64, minimumMacOs: '12.0'),
        );
      expect(
        nativeLibraryMatchesTarget(file.path, SttNativeTarget.macosX64),
        isFalse,
      );
      expect(
        nativeLibraryMatchesTarget(file.path, SttNativeTarget.macosArm64),
        isTrue,
      );
    });

    test('a missing file is not loadable', () {
      expect(
        nativeLibraryMatchesTarget(
          '${Directory.systemTemp.path}/definitely-absent-${DateTime.now().microsecondsSinceEpoch}',
          SttNativeTarget.linuxX64,
        ),
        isFalse,
      );
    });
  });

  group('build inputs', () {
    test('macOS passes an explicit CMake architecture', () {
      expect(SttNativeTarget.macosX64.cmakeArchitecture, 'x86_64');
      expect(SttNativeTarget.macosArm64.cmakeArchitecture, 'arm64');
      expect(SttNativeTarget.linuxX64.cmakeArchitecture, isNull);
      expect(SttNativeTarget.windowsX64.cmakeArchitecture, isNull);
    });

    test('macOS builds against the shipped Client floor', () {
      expect(
        SttNativeTarget.macosX64.macosDeploymentTarget,
        SttNativeTarget.macosMinimumDeploymentTarget,
      );
      expect(
        SttNativeTarget.macosArm64.macosDeploymentTarget,
        SttNativeTarget.macosMinimumDeploymentTarget,
      );
      expect(SttNativeTarget.linuxX64.macosDeploymentTarget, isNull);
      expect(SttNativeTarget.windowsX64.macosDeploymentTarget, isNull);
    });
  });
}
