import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:sanad_agent/infrastructure/stt/whispercpp_bindings.dart';
import 'package:test/test.dart';

import '../../tool/stt_native_runtime.dart';

/// The tool and `tool/build_whispercpp.sh` are two halves of one argument
/// contract. A mismatch here is invisible on Apple Silicon (`arm64` happens to
/// equal the CMake spelling) and fatal on Intel, so it is asserted directly.
///
/// The script's plan mode runs the same validation and the same architecture
/// mapping as a real build and then exits before touching a compiler or the
/// filesystem, which keeps this test host-independent.
void main() {
  final windows = Platform.isWindows;
  final bash = windows
      ? null
      : Process.runSync('bash', ['--version']).exitCode == 0;

  test('the tool builds the vector the POSIX script accepts', () {
    if (windows || bash != true) {
      markTestSkipped('bash is required to exercise the POSIX builder script');
      return;
    }
    final target = SttNativeTarget.tryCurrent();
    if (target == null) {
      markTestSkipped('this host has no native dictation target');
      return;
    }

    final arguments = sttPosixBuilderArguments(
      target: target,
      whisperSource: Directory.current.path,
      outputDirectory: 'native/.plan-only',
    );
    final result = Process.runSync(
      'bash',
      arguments,
      environment: {'SANAD_BUILD_PLAN_ONLY': '1'},
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    final plan = <String, String>{
      for (final line in LineSplitter().convert(result.stdout as String))
        if (line.contains('=')) line.split('=').first: line.split('=').last,
    };
    expect(plan['build_plan_arch'], target.cpuName);
    expect(plan['build_plan_out'], 'native/.plan-only');
    // The CMake spelling is the script's job: `x64` must arrive as `x86_64`.
    if (target.os == SttNativeOs.macos) {
      expect(
        plan['build_plan_cmake_arch'],
        target.cpu == SttNativeCpu.x64 ? 'x86_64' : 'arm64',
      );
      expect(
        plan['build_plan_deploy_target'],
        SttNativeTarget.macosMinimumDeploymentTarget,
      );
    } else {
      expect(plan['build_plan_metal'], 'OFF');
    }
  });

  test('the script refuses the other architecture', () {
    if (windows || bash != true) {
      markTestSkipped('bash is required to exercise the POSIX builder script');
      return;
    }
    final target = SttNativeTarget.tryCurrent();
    if (target == null) {
      markTestSkipped('this host has no native dictation target');
      return;
    }
    final other = target.cpu == SttNativeCpu.x64 ? 'arm64' : 'x64';
    final result = Process.runSync('bash', [
      'tool/build_whispercpp.sh',
      Directory.current.path,
      'native/.plan-only',
      other,
      SttNativeTarget.macosMinimumDeploymentTarget,
    ], environment: {'SANAD_BUILD_PLAN_ONLY': '1'});

    expect(result.exitCode, isNot(0));
    expect(result.stderr as String, contains('Refusing to build $other'));
  });

  test('the script rejects the CMake spelling on macOS', () {
    if (windows || bash != true) {
      markTestSkipped('bash is required to exercise the POSIX builder script');
      return;
    }
    if (!Platform.isMacOS) {
      // Linux takes no architecture argument at all, so there is nothing to
      // reject there.
      markTestSkipped('only the macOS path maps a tag-style architecture');
      return;
    }

    final result = Process.runSync('bash', [
      'tool/build_whispercpp.sh',
      Directory.current.path,
      'native/.plan-only',
      'x86_64',
      SttNativeTarget.macosMinimumDeploymentTarget,
    ], environment: {'SANAD_BUILD_PLAN_ONLY': '1'});

    expect(result.exitCode, isNot(0));
    expect(result.stderr as String, contains('x86_64'));
  });

  test('the POSIX builder links every shipped Linux library self-relatively', () {
    // The shim's own rpath is not enough: glibc resolves `libwhisper.so.1`'s
    // DT_NEEDED through that library's RUNPATH, so an arm64 install shipped a
    // runtime that could not find its ggml siblings. Every library the script
    // copies out of the build tree has to carry `$ORIGIN`, and a restored build
    // cache must not be reused without it.
    final script = File('tool/build_whispercpp.sh').readAsStringSync();
    expect(script, contains(r"-Wl,-rpath,'$ORIGIN'"));
    expect(script, contains(r"-DCMAKE_INSTALL_RPATH='$ORIGIN'"));
    expect(script, contains('-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON'));

    // A cached tree is only relinked when its link command is re-run, and the
    // Makefile generator compares timestamps only, so the guard has to discard a
    // tree that does not record the contract before cmake configures.
    final guard = script.lastIndexOf(r'CMAKE_INSTALL_RPATH:STRING=$ORIGIN');
    final configure = script.lastIndexOf('cmake -B build');
    expect(guard, isNonNegative);
    expect(configure, isNonNegative);
    expect(
      guard,
      lessThan(configure),
      reason: 'the stale-cache guard must run before cmake configures',
    );
  });

  test('the Windows vector carries the tag-style architecture', () {
    final arguments = sttWindowsBuilderArguments(
      target: SttNativeTarget.windowsX64,
      whisperSource: r'C:\src\whisper.cpp',
      outputDirectory: r'native\windows-x64.tmp',
    );

    expect(arguments, [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      'tool/build_whispercpp.ps1',
      r'C:\src\whisper.cpp',
      r'native\windows-x64.tmp',
      '-Arch',
      'x64',
    ]);
    expect(arguments, isNot(contains('x86_64')));
  });

  test('the Windows builder discards a CMake cache for another platform', () {
    // A restored CI cache (or a developer's earlier build) can carry a
    // CMakeCache configured without the requested platform, and CMake then
    // refuses to reconfigure instead of reusing the tree. The builder must
    // discard such a tree itself, because no workflow key can guarantee it.
    final script = File('tool/build_whispercpp.ps1').readAsStringSync();
    expect(script, contains('CMAKE_GENERATOR_PLATFORM'));
    expect(
      script,
      contains(r'Remove-Item -Recurse -Force -LiteralPath $buildDir'),
    );
    final guard = script.indexOf('CMAKE_GENERATOR_PLATFORM');
    final configure = script.indexOf(r'cmake -B build');
    expect(guard, isNonNegative);
    expect(
      guard,
      lessThan(configure),
      reason: 'the stale-cache guard must run before cmake configures',
    );
  });

  test('the Windows builder stages exactly the DLLs the loader preloads', () {
    // The loader registers each sibling DLL before opening the shim, because
    // Windows does not search the shim's directory for its imports. If the
    // builder stops staging one of these, the load fails at runtime instead.
    final script = File('tool/build_whispercpp.ps1').readAsStringSync();
    for (final name in WhisperCppLibrary.windowsRuntimeLibraries) {
      expect(script, contains(name), reason: '$name must be staged');
    }
    // Order is the dependency graph: ggml.dll and whisper.dll import
    // ggml-base, so preloading them first reintroduces the same error 126.
    final libraries = WhisperCppLibrary.windowsRuntimeLibraries;
    expect(
      libraries.indexOf('ggml-base.dll'),
      lessThan(libraries.indexOf('ggml.dll')),
    );
    expect(
      libraries.indexOf('ggml-base.dll'),
      lessThan(libraries.indexOf('whisper.dll')),
    );
    expect(
      libraries.indexOf('ggml.dll'),
      lessThan(libraries.indexOf('whisper.dll')),
    );
  });

  test('the shim exports every symbol the FFI bindings look up', () {
    // POSIX exports these by default; MSVC exports nothing without a marker, so
    // an unmarked shim builds and stages cleanly on Windows and then fails to
    // load with "procedure could not be found" (error 127).
    final source = File('native/whispercpp/sanad_whisper.c').readAsStringSync();
    expect(source, contains('__declspec(dllexport)'));
    for (final symbol in [
      'sanad_whisper_load',
      'sanad_whisper_free',
      'sanad_whisper_run',
      'sanad_whisper_system_info',
    ]) {
      expect(
        RegExp('SANAD_WHISPER_EXPORT[^;]*\\b$symbol\\b').hasMatch(source),
        isTrue,
        reason: '$symbol must be exported explicitly',
      );
    }
  });
}
