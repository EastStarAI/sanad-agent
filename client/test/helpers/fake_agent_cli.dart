import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/daemon/verified_agent_bootstrap_installer.dart';
import 'package:sanad_release_contract/release_contract.dart';

/// Simulates the command-line behavior of released `sanad` executables so
/// daemon-controller tests exercise the real compatibility contract:
///
/// - every release prints `Version: <v>` for `--version`;
/// - `help service install` is read-only everywhere, but lists
///   `--user-scope` only from v1.0.16;
/// - v1.0.0-v1.0.6 ignore `service install --help` and perform a real
///   installation ([realInstallFromHelpProbe] records that hazard);
/// - `service install --user-scope` fails before v1.0.16.
class FakeAgentCli {
  FakeAgentCli(this.version, {this.serviceInstallFailure, this.versionOutput, this.definitionMatches = true});

  /// Version of the executable currently on disk; tests change it when a fake
  /// bootstrap replaces the binary.
  String version;

  /// When set, `service install` fails with this stderr.
  String? serviceInstallFailure;

  /// Overrides the complete `--version` stdout.
  String? versionOutput;

  /// What `service definition` reports for an installed service; null makes
  /// the command unknown, as on releases before it existed.
  bool? definitionMatches;

  final List<List<String>> calls = [];
  bool realInstallFromHelpProbe = false;
  bool serviceInstalled = false;
  bool started = false;
  bool stopped = false;

  ReleaseVersion get _parsed => ReleaseVersion.parse(version);
  bool get _supportsUserScope => _parsed.compareTo(ReleaseVersion.parse('1.0.16')) >= 0;
  bool get _ignoresInstallHelp => _parsed.compareTo(ReleaseVersion.parse('1.0.7')) < 0;
  bool get _hasCommandRunner => _parsed.compareTo(ReleaseVersion.parse('1.0.11')) >= 0;

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add(List.unmodifiable(arguments));
    if (arguments.length == 1 && arguments.single == '--version') {
      return ProcessResult(
        1,
        0,
        versionOutput ?? 'Sanad Agent\nVersion: $version\nPlatform: linux (6.8.0-45-generic #45-Ubuntu SMP)\n',
        '',
      );
    }
    if (arguments.isNotEmpty && arguments.first == 'help') {
      if (!_hasCommandRunner || arguments.length == 1) {
        return ProcessResult(1, 0, 'Sanad Agent\nUsage: sanad <command>\n  service  Manage the service\n', '');
      }
      return ProcessResult(
        1,
        0,
        'Install and register the Sanad Agent background service\n\n'
            'Usage: sanad service install [arguments]\n'
            '-h, --help                Print this usage information.\n'
            '${_supportsUserScope ? '    --user-scope          Explicitly install a user-scoped service\n' : ''}'
            '    --expected-version    Expected daemon version to verify after installation\n',
        '',
      );
    }
    if (arguments.length >= 2 && arguments[0] == 'service' && arguments[1] == 'install') {
      final options = arguments.sublist(2);
      if (options.contains('--help')) {
        if (_ignoresInstallHelp) {
          realInstallFromHelpProbe = true;
          serviceInstalled = true;
          return ProcessResult(1, 0, 'Service installed and registered successfully!', '');
        }
        return ProcessResult(1, 0, 'Usage: sanad service install [arguments]', '');
      }
      if (options.contains('--user-scope') && !_supportsUserScope) {
        return ProcessResult(1, 64, '', 'Could not find an option named "--user-scope".');
      }
      final failure = serviceInstallFailure;
      if (failure != null) return ProcessResult(1, 1, '', failure);
      serviceInstalled = true;
      return ProcessResult(1, 0, 'Service operation completed successfully.', '');
    }
    if (arguments.length == 2 && arguments[0] == 'service' && arguments[1] == 'definition') {
      final matches = definitionMatches;
      if (matches == null) return ProcessResult(1, 64, '', 'Could not find a subcommand named "definition".');
      return ProcessResult(1, 0, '{"platform":"linux","supported":true,"installed":true,"matches":$matches}', '');
    }
    if (arguments.length == 2 && arguments[0] == 'service' && arguments[1] == 'start') {
      started = true;
      return ProcessResult(1, 0, 'Service operation completed successfully.', '');
    }
    if (arguments.length == 2 && arguments[0] == 'service' && arguments[1] == 'stop') {
      started = false;
      stopped = true;
      return ProcessResult(1, 0, 'Service operation completed successfully.', '');
    }
    return ProcessResult(1, 64, '', 'Unknown command');
  }

  /// Health as reported by a started daemon running the on-disk version.
  Future<Map<String, dynamic>?> health() async => started ? {'status': 'ok', 'version': version} : null;
}

/// Bootstrap installer double. It never touches the network; [onInstall]
/// decides the outcome and may mutate the fake executable.
class FakeBootstrapInstaller extends VerifiedAgentBootstrapInstaller {
  FakeBootstrapInstaller({required super.targetPath, required this.onInstall});

  final AgentBootstrapResult Function(String targetVersion) onInstall;
  int installCalls = 0;

  @override
  Future<AgentBootstrapResult> install({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    installCalls++;
    onProgress?.call(1);
    return onInstall(targetVersion);
  }
}

/// Factory for controllers that must never reach the bootstrap installer.
VerifiedAgentBootstrapInstaller noBootstrapExpected(String targetPath) => FakeBootstrapInstaller(
  targetPath: targetPath,
  onInstall: (_) => fail('The verified bootstrap installer must not run in this scenario.'),
);
