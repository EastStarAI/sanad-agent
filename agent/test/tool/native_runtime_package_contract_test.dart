import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:test/test.dart';

import '../../tool/stt_native_archive.dart';

/// The release has to ship the native dictation runtime **with the Agent**, not
/// in a side artifact the manifest ignores (audit D9).
///
/// Three places must agree for that to be true, so each one is asserted here:
/// the release contract that declares the archive, the tool that writes it with
/// the packaged layout, and the installers that place it beside the executable.
void main() {
  // Every source this contract asserts is read in `setUpAll` from a
  // package-resolved root. `dart test` runs several suites in one process, so a
  // suite that models a checkout by changing `Directory.current` would otherwise
  // break these reads while another suite is executing.
  late String repositoryRoot;
  late Map<String, dynamic> contract;
  late List<Map<String, dynamic>> artifacts;
  late String version;

  setUpAll(() async {
    repositoryRoot = await _repositoryRoot();
    contract =
        jsonDecode(
              File(
                '$repositoryRoot/release/release-contract.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    artifacts = (contract['artifacts'] as List).cast<Map<String, dynamic>>();
    version = contract['version'] as String;
  });

  /// A repository file, resolved without trusting the process working directory.
  File repositoryFile(String relative) => File('$repositoryRoot/$relative');

  List<Map<String, dynamic>> runtimesFor(String platform, String architecture) {
    return artifacts
        .where(
          (artifact) =>
              artifact['component'] == 'agent-runtime' &&
              artifact['platform'] == platform &&
              artifact['architecture'] == architecture,
        )
        .toList();
  }

  group('release contract', () {
    test('every packaged Agent platform declares one runtime archive', () {
      final agents = artifacts
          .where((artifact) => artifact['component'] == 'agent')
          .toList();
      expect(agents, isNotEmpty);
      for (final agent in agents) {
        final platform = agent['platform'] as String;
        final architecture = agent['architecture'] as String;
        final runtimes = runtimesFor(platform, architecture);
        expect(
          runtimes,
          hasLength(1),
          reason: 'expected one agent-runtime for $platform-$architecture',
        );
        final runtime = runtimes.single;
        expect(runtime['format'], 'tar.gz');
        expect(runtime['public'], isTrue);
        expect(
          runtime['filename'],
          'sanad-agent-runtime-$version-$platform-$architecture.tar.gz',
        );
        // The declared name carries the release version, so the contract
        // validator accepts it and a version bump rewrites it with everything
        // else.
        expect((runtime['filename'] as String).contains(version), isTrue);
      }
    });

    test('the declared runtime tag is the directory the loader searches', () {
      for (final target in SttNativeTarget.values) {
        final runtimes = runtimesFor(target.os.name, target.cpu.name);
        if (runtimes.isEmpty) continue;
        expect(runtimes, hasLength(1));
        expect(runtimes.single['filename'], contains('-${target.tag}.tar.gz'));
        expect(target.nativeDirectory, target.tag);
      }
    });

    test('the Agent executable stays a single file for the Client installer', () {
      // The Client bootstrap installer selects `component: agent` and expects
      // one downloadable file; declaring the runtime separately is what keeps
      // that contract intact.
      final agents = artifacts.where(
        (artifact) =>
            artifact['component'] == 'agent' && artifact['public'] == true,
      );
      for (final agent in agents) {
        expect(agent['format'], 'executable');
      }
    });
  });

  group('packaged layout', () {
    test('archive members live under native/<tag>/', () {
      const target = SttNativeTarget.macosX64;
      final bytes = buildDeterministicTarGz({
        'native/${target.nativeDirectory}/libsanad_whisper.dylib': List<int>.filled(8, 7),
        'native/${target.nativeDirectory}/libwhisper.1.dylib': List<int>.filled(8, 9),
      });
      final tar = GZipCodec().decode(bytes);
      final names = <String>[];
      var offset = 0;
      while (offset + 512 <= tar.length) {
        final block = tar.sublist(offset, offset + 512);
        final name = utf8
            .decode(block.sublist(0, 100))
            .replaceAll('\u0000', '')
            .trim();
        if (name.isEmpty) break;
        names.add(name);
        final sizeField = utf8
            .decode(block.sublist(124, 136))
            .replaceAll('\u0000', '')
            .trim();
        final size = int.parse(sizeField.isEmpty ? '0' : sizeField, radix: 8);
        offset += 512 + ((size + 511) ~/ 512) * 512;
      }
      expect(names, [
        'native/macos-x64/libsanad_whisper.dylib',
        'native/macos-x64/libwhisper.1.dylib',
      ]);
    });
  });

  group('installers', () {
    test('both installers consume the declared archive', () {
      final posix = repositoryFile('scripts/install.sh').readAsStringSync();
      final windows = repositoryFile('scripts/install.ps1').readAsStringSync();
      for (final script in [posix, windows]) {
        expect(script, contains('agent-runtime'));
        expect(script, contains('native/'));
        expect(script, contains('Native runtime SHA-256 verification failed'));
      }
      expect(posix, contains(r'native/$RUNTIME_TAG'));
      expect(
        posix,
        contains(r'sanad-agent-runtime-*-"$RUNTIME_TAG".tar.gz'),
      );
      expect(windows, contains('native/windows-x64'));
      expect(windows, contains('Native runtime archive contains a file outside'));
    });
  });

  group('pull-request workflow', () {
    test('native dictation proves the published arm64 slice', () {
      final ci = repositoryFile('.github/workflows/ci.yml').readAsStringSync();
      final job = _jobs(ci)['native-stt'];
      expect(job, isNotNull);

      // The release matrix publishes linux-arm64, so the pull-request lane
      // builds that slice on the same runner family instead of trusting an x64
      // host. Losing the lane would publish an artifact no PR ever proved.
      expect(job, contains('ubuntu-24.04-arm'));
      expect(job, contains('./.github/actions/setup-dart'));
      expect(job, contains('DART:'));

      final runtimeLines = const LineSplitter()
          .convert(job!)
          .where(
            (line) =>
                line.contains('ensure_native_stt.dart') ||
                line.contains('native_runtime_smoke_test.dart'),
          )
          .toList();
      expect(runtimeLines, hasLength(7));
      // Only the PowerShell twins may name `fvm dart`: every other line runs on
      // the arm64 lane, which installs no Flutter SDK.
      expect(
        runtimeLines.where((line) => line.trimLeft().startsWith('fvm dart')),
        hasLength(3),
      );
    });
  });

  group('release workflow', () {
    test('stages the runtime into the Agent payload and stays required', () {
      final workflow = repositoryFile('.github/workflows/release.yml').readAsStringSync();
      expect(workflow, contains('SANAD_STT_REQUIRE_NATIVE'));
      expect(workflow, contains('ensure_native_stt.dart --verify'));
      expect(workflow, contains('--stage ../dist'));
      expect(workflow, contains('--archive-name'));
      expect(workflow, contains('--expect-target'));
      expect(
        workflow,
        contains(
          r'ARCHIVE_NAME: sanad-agent-runtime-${{ needs.validate.outputs.artifact_version }}-${{ matrix.platform }}-${{ matrix.architecture }}.tar.gz',
        ),
      );
      // The standalone job that produced an artifact the manifest ignored is
      // gone; a release cannot pass while the runtime is missing.
      expect(workflow, isNot(contains('agent-native-runtime:')));
      expect(workflow, isNot(contains('stt-runtime-')));
      expect(workflow, isNot(contains('continue-on-error')));
    });

    test('the Agent job keeps its budget and a native shell per platform', () {
      final workflow = repositoryFile('.github/workflows/release.yml').readAsStringSync();
      final start = workflow.indexOf('\n  agent:\n');
      final end = workflow.indexOf('\n  client-linux-web:\n');
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final job = workflow.substring(start, end);

      // No measurement justifies raising the job budget, so it stays 35.
      expect(job, contains('timeout-minutes: 35'));
      // Windows has only ever run fvm through PowerShell in this job; the
      // runner's fvm entry point is a .bat shim, and Git-Bash `tee`/`sed`
      // semantics were never verified on that lane.
      expect(job, isNot(contains('tee ')));
    });

    test('the arm64 lane runs the runtime tooling with its own Dart', () {
      final workflow = repositoryFile('.github/workflows/release.yml').readAsStringSync();
      final start = workflow.indexOf('\n  agent:\n');
      final end = workflow.indexOf('\n  client-linux-web:\n');
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final job = workflow.substring(start, end);

      // The Linux arm64 lane has no Flutter SDK, so a runtime step that names
      // `fvm dart` would fail there. Every runtime step that is not Windows-only
      // must select its executable through the job's per-lane `DART`.
      final runtimeLines = const LineSplitter()
          .convert(job)
          .where(
            (line) =>
                line.contains('ensure_native_stt.dart') ||
                line.contains('native_runtime_smoke_test.dart'),
          )
          .toList();
      expect(runtimeLines, hasLength(8));
      // Only the PowerShell twins may name `fvm dart`: every other line runs on
      // the arm64 lane, which installs no Flutter SDK.
      expect(
        runtimeLines.where((line) => line.trimLeft().startsWith('fvm dart')),
        hasLength(4),
      );
      // The lane installs the pinned standalone Dart SDK instead of FVM.
      expect(job, contains('./.github/actions/setup-dart'));
      expect(
        job,
        contains(
          "if: matrix.platform != 'linux' || matrix.architecture != 'arm64'",
        ),
      );
    });

    test('the arm64 lane builds without the Flutter-only engine', () {
      // `sherpa_onnx` declares `environment: flutter`, and the arm64 lane has no
      // Flutter SDK. The lane must therefore swap the engine for the stand-in
      // before `pub get`; without this the whole target stops resolving.
      for (final path in [
        '../.github/workflows/release.yml',
        '../.github/workflows/ci.yml',
      ]) {
        final workflow = File(path).readAsStringSync();
        expect(
          workflow,
          contains(
            'cp tool/pubspec_overrides.no_sherpa.yaml pubspec_overrides.yaml',
          ),
          reason: '$path never selects the whisper-only engine',
        );
      }
      // The overlay and the stand-in exist and are wired to each other.
      final overlay = repositoryFile('agent/tool/pubspec_overrides.no_sherpa.yaml');
      expect(overlay.existsSync(), isTrue);
      expect(overlay.readAsStringSync(), contains('packages/stt_sherpa_stub'));
      final stub = repositoryFile('agent/packages/stt_sherpa_stub/pubspec.yaml');
      expect(stub.readAsStringSync(), contains('name: sanad_stt_sherpa'));
      final stubLibrary = repositoryFile('agent/packages/stt_sherpa_stub/lib/sanad_stt_sherpa.dart');
      expect(
        stubLibrary.readAsStringSync(),
        contains('const bool sherpaEngineAvailable = false;'),
      );
    });

    test('no bash step can execute on a Windows runner', () {
      for (final path in [
        '../.github/workflows/release.yml',
        '../.github/workflows/ci.yml',
      ]) {
        expect(
          windowsBashSteps(File(path).readAsStringSync()),
          isEmpty,
          reason: '$path runs bash on a Windows-capable job',
        );
      }
    });

    test('every Windows-reachable step keeps a pwsh twin', () {
      final release = repositoryFile('.github/workflows/release.yml').readAsStringSync();
      final ci = repositoryFile('.github/workflows/ci.yml').readAsStringSync();

      // The lanes W5 repaired: the same command must exist under both shells,
      // so the guard above can see and keep a Windows twin in place.
      for (final name in [
        'Load the packaged runtime in a real process',
      ]) {
        expect(_namedSteps(release, name), 2, reason: 'release.yml: $name');
      }
      for (final name in [
        'Build the native runtime for this runner',
        'Verify the installed runtime and its manifest entry',
        'Stage and archive the runtime for packaging',
      ]) {
        expect(_namedSteps(ci, name), 2, reason: 'ci.yml: $name');
      }
    });
  });

  // A source checkout prepares dictation through one acquisition tool. The
  // launcher, `sanad-dev setup`, and the daemon's retry all run that tool, so
  // the two sides have to agree on what a finished attempt says and on when a
  // second attempt must not start. Nothing links them at compile time (the
  // launcher must not import the Agent package), so the agreement is asserted
  // here instead of trusted.
  //
  // Sources are read in `setUpAll` from a package-resolved root: `dart test`
  // shares one process across suites, and a suite that models a checkout by
  // changing `Directory.current` would otherwise resolve these paths elsewhere.
  group('development launcher preparation contract', () {
    late String repositoryRoot;
    late String tool;
    late String probe;
    late List<String> wrappers;

    setUpAll(() async {
      repositoryRoot = await _repositoryRoot();
      tool = File('$repositoryRoot/agent/tool/ensure_native_stt.dart')
          .readAsStringSync();
      probe = File(
        '$repositoryRoot/scripts/sanad_dev/lib/src/runtime/lifecycle/'
        'native_runtime_probe.dart',
      ).readAsStringSync();
      wrappers = [
        File('$repositoryRoot/scripts/sanad-dev').readAsStringSync(),
        File('$repositoryRoot/scripts/sanad-dev.ps1').readAsStringSync(),
      ];
    });

    test('the tool prints the machine keys the launcher reads', () {
      for (final key in [
        'native_stt_stage',
        'native_stt_result',
        'native_stt_failure',
      ]) {
        expect(tool, contains(key), reason: 'the tool must print $key');
        expect(probe, contains(key), reason: 'the launcher must read $key');
      }
    });

    test('both refuse a second attempt on the same marker and window', () {
      // The tool claims the marker atomically before it stages anything; the
      // launcher checks the same marker before spawning. One marker, one window,
      // and one claim rule mean neither can consider an attempt finished while
      // the other still sees it running.
      expect(tool, contains('sttClaimPreparation'));
      expect(tool, contains('sttPreparingMarkerName'));
      expect(probe, contains('nativeSttAttemptInFlight'));
      expect(probe, contains('\$nativeSttPreparingMarkerName'));
      expect(probe, contains('nativeSttAttemptMaxAge'));
      expect(probe, contains('Duration(minutes: 30)'));
      expect(
        sttPreparingMarkerMaxAge,
        const Duration(minutes: 30),
        reason: 'the launcher mirrors this window',
      );
    });

    test('no preparation diagnostic is discarded on any platform', () {
      // Windows redirected every word of a failed preparation to the null
      // device, which is exactly the evidence a fresh checkout needs. Every
      // spelling of that redirect is rejected on a *preparation* line, because
      // any one of them silences the only record an attempt leaves. Null devices
      // stay legal elsewhere (a `command -v` probe, a version check).
      const nullDevices = [
        'NUL',
        '> \$null',
        '1> \$null',
        '2> \$null',
        '>/dev/null',
        '1>/dev/null',
        '2>/dev/null',
        '> /dev/null',
      ];
      for (final source in [tool, probe]) {
        for (final device in nullDevices) {
          expect(
            source,
            isNot(contains(device)),
            reason: 'preparation output must reach the durable log ($device)',
          );
        }
      }
      for (final wrapper in wrappers) {
        for (final line in preparationLines(wrapper)) {
          for (final device in nullDevices) {
            expect(
              line,
              isNot(contains(device)),
              reason: 'a preparation stage must never discard its output',
            );
          }
        }
      }
      for (final source in [probe, ...wrappers]) {
        expect(source, contains('.stt-prepare.log'));
      }
    });

    test('the launcher detaches the attempt instead of holding it', () {
      // An attached child either dies with `sanad-dev run` or keeps it alive for
      // the length of a build. The shell owns the log so the attempt outlives
      // the launcher either way.
      expect(probe, contains('ProcessStartMode.detached'));
      expect(
        probe,
        isNot(contains('process.stdout.listen')),
        reason: 'listening to the child is what held the launcher open',
      );
      expect(
        probe,
        isNot(contains('Timer.periodic')),
        reason: 'a poll timer keeps the launcher alive as well',
      );
    });

    test('both sides bound the same durable log', () {
      // The Agent resets the log before its own retry, the launcher before a
      // `run`, and the wrappers before `setup`; one bound keeps them honest.
      expect(sttPreparationLogLimitBytes, 1024 * 1024);
      expect(probe, contains('1024 * 1024'));
      expect(wrappers[0], contains('1048576'));
      expect(wrappers[1], contains('1048576'));
      expect(probe, contains(sttPreparationLogFileName));
      expect(tool, contains('sttClaimPreparation'));
      // Both wrappers read the tool's own key, which is what turns `busy` into
      // "already running" instead of "ready".
      for (final wrapper in wrappers) {
        expect(wrapper, contains('native_stt_result='));
      }
    });

    test('setup waits and run never does', () {
      // An awaited `run` startup would hold the daemon behind a compile; a
      // backgrounded `setup` would end before the checkout was usable.
      expect(wrappers[0], contains('run_dictation_prepare'));
      expect(wrappers[0], contains('run_setup "\$force" true true'));
      expect(wrappers[0], contains('run_setup "\$force" true false'));
      expect(wrappers[1], contains('Invoke-DictationPreparation'));
      expect(wrappers[1], contains('Invoke-Setup \$true \$true'));
      expect(wrappers[1], contains('Invoke-Setup \$true \$false'));
    });
  });
}

int _namedSteps(String workflow, String name) =>
    RegExp('- name: ${RegExp.escape(name)}\\n').allMatches(workflow).length;

/// The repository root, resolved from the package itself.
///
/// `dart test` runs several suites in one process, and a suite that models a
/// checkout by changing `Directory.current` would break every relative path read
/// here. A package URI is resolved from the compiled package config instead, so
/// it does not depend on the working directory at all.
Future<String> _repositoryRoot() async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:sanad_agent/infrastructure/stt/stt_native_platform.dart'),
  );
  if (lib == null) {
    throw StateError('could not resolve the sanad_agent package');
  }
  // `<repo>/agent/lib/infrastructure/stt/stt_native_platform.dart` — five
  // parents up from the file is the repository root.
  return File(lib.toFilePath())
      .parent // stt
      .parent // infrastructure
      .parent // lib
      .parent // agent
      .parent // repository root
      .path;
}

/// Every line of a wrapper that belongs to native dictation preparation.
///
/// Null-device redirects are legal elsewhere in these scripts (existence probes,
/// version checks); the rule this returns for is that a preparation stage never
/// discards its own output.
List<String> preparationLines(String source) => const LineSplitter()
    .convert(source)
    .where(
      (line) =>
          line.contains('ictation') ||
          line.contains('.stt-prepare') ||
          line.contains('native_stt') ||
          line.contains('ensure_native_stt'),
    )
    .toList();

/// Every `shell: bash` run step in a job that can execute on Windows.
///
/// A job is Windows-capable when its header (everything before `steps:`) names
/// a Windows runner image, so an unguarded step cannot hide behind a job-level
/// matrix. Only runner names count — a `needs:` entry such as `client-windows`
/// does not make an Ubuntu job Windows-capable. A step is acceptable only when
/// its own guard excludes Windows using one of [windowsExclusions]; any other
/// form fails so a new lane has to state its platform boundary explicitly.
List<String> windowsBashSteps(String workflow) {
  final violations = <String>[];
  final windowsRunner = RegExp(r'windows-(?:20\d\d|latest)');
  for (final entry in _jobs(workflow).entries) {
    final stepsAt = entry.value.indexOf('    steps:');
    if (stepsAt < 0) continue;
    final header = entry.value.substring(0, stepsAt);
    if (!windowsRunner.hasMatch(header)) continue;
    for (final step in entry.value.substring(stepsAt).split('      - ').skip(1)) {
      if (!step.contains('shell: bash')) continue;
      final beforeRun = step.split('run:').first;
      if (windowsExclusions.any((form) => beforeRun.contains(form))) continue;
      final name =
          RegExp(r'name: (.+)').firstMatch(step)?.group(1)?.trim() ?? step.trim();
      violations.add('${entry.key}: $name');
    }
  }
  return violations;
}

/// The guard forms this repository uses to keep a step off Windows.
const windowsExclusions = [
  "runner.os != 'Windows'",
  "matrix.platform != 'windows'",
  "runner.os == 'macOS'",
  "runner.os == 'Linux'",
  "matrix.platform == 'macos'",
  "matrix.platform == 'linux'",
];

Map<String, String> _jobs(String workflow) {
  final jobs = <String, String>{};
  String? current;
  final buffer = StringBuffer();
  for (final line in const LineSplitter().convert(workflow)) {
    final job = RegExp(r'^  ([A-Za-z0-9_-]+):$').firstMatch(line);
    if (job != null) {
      if (current != null) jobs[current] = buffer.toString();
      current = job.group(1)!;
      buffer.clear();
      continue;
    }
    if (current != null) buffer.writeln(line);
  }
  if (current != null) jobs[current] = buffer.toString();
  return jobs;
}
