import 'dart:io';
import 'package:sanad_agent/capabilities/skills/bundled_skill_manager.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/core/hot_restart_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/setup/env_template.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'daemon.dart' as daemon;
import 'setup.dart' as setup;
import 'login.dart' as login_cmd;
import 'service.dart' as service_cmd;

final String version = loadAgentVersion();

void main(List<String> arguments) async {
  if (_handleEarlyHelpOrInvalidArguments(arguments)) return;

  // A supervised daemon parent must remain a lightweight process owner. Its
  // child prepares the secure Home roots before any daemon dependency is
  // composed, avoiding duplicate full-tree work on every source start.
  final isChild = arguments.contains('--child-process');
  if (shouldDeferSanadHomeBootstrapToChild(arguments: arguments)) {
    await HotRestartManager.run(arguments);
    return;
  }

  // SEC-02: prepare the owner-only roots before configuration access. Files
  // are secured individually by their read/write owners; startup never walks
  // the complete Home tree.
  await SanadHomeBootstrap.prepareAll();
  final machineOutput =
      arguments.contains('--json') ||
      arguments.contains('--quiet') ||
      arguments.contains('-q');
  try {
    final result = BundledSkillManager().reconcileSync();
    if (!result.fastPath &&
        (result.installed + result.updated + result.removed) > 0) {
      final message =
          'Bundled skills synchronized: '
          '${result.installed} installed, ${result.updated} updated, '
          '${result.removed} removed.';
      (machineOutput ? stderr : stdout).writeln(message);
    }
  } catch (_) {
    stderr.writeln(
      'Warning: Bundled skills could not be synchronized; startup will continue.',
    );
  }
  if (!SanadHomeBootstrap.identity().fileExists('.env')) {
    try {
      await SanadHomeBootstrap.identity().writeConfigText(
        '.env',
        defaultEnvContent,
      );
    } catch (e) {
      stderr.writeln(
        'Warning: Failed to automatically initialize .env file: $e',
      );
    }
  }

  final cleanArgs = isChild
      ? (List<String>.from(arguments)..remove('--child-process'))
      : arguments;

  await _executeCommand(cleanArgs);
}

bool _handleEarlyHelpOrInvalidArguments(List<String> arguments) {
  if (SanadCommandRunner.handleEarlyDaemonHelpOrInvalidArguments(arguments)) {
    return true;
  }
  if (arguments.isNotEmpty && arguments.first.toLowerCase() == 'service') {
    final remaining = arguments.sublist(1);
    if (remaining.isEmpty ||
        const {'help', '-h', '--help'}.contains(remaining.first.toLowerCase())) {
      service_cmd.main(remaining);
      return true;
    }
  }
  return false;
}

Future<void> _executeCommand(List<String> arguments) async {
  final runner = SanadCommandRunner(
    onDaemon: (args) async {
      await daemon.main(args);
      return 0;
    },
    onService: service_cmd.main,
    onSetup: (args) async {
      await setup.main(args);
      return 0;
    },
    onLogin: (args) async {
      await login_cmd.main(args);
      return 0;
    },
    onLogout: () async {
      await login_cmd.runLogout();
      return 0;
    },
    onRestart: () => service_cmd.main(['restart']),
  );

  final isDaemon = arguments.contains('daemon');
  final result = await runner.run(arguments);
  if (result != 0 && exitCode == 0) {
    exitCode = result;
  }
  if (result != 0 || !isDaemon) {
    exit(result);
  }
}
