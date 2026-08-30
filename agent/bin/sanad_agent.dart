import 'dart:async';
import 'dart:io';
import 'package:sanad_agent/capabilities/skills/bundled_skill_manager.dart';
import 'package:sanad_agent/core/app_config.dart';
import 'package:sanad_agent/core/hot_restart_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/setup/env_template.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'cli.dart' as cli;
import 'daemon.dart' as daemon;
import 'setup.dart' as setup;
import 'login.dart' as login_cmd;
import 'service.dart' as service_cmd;

final String version = loadAgentVersion();

void main(List<String> arguments) async {
  if (_handleDaemonHelpOrInvalidArguments(arguments)) return;

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
  try {
    final result = BundledSkillManager().reconcileSync();
    if (!result.fastPath &&
        (result.installed + result.updated + result.removed) > 0) {
      stdout.writeln(
        'Bundled skills synchronized: '
        '${result.installed} installed, ${result.updated} updated, '
        '${result.removed} removed.',
      );
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

  if (isChild) {
    // Strip out the internal child process flag and execute normally
    final cleanArgs = List<String>.from(arguments)..remove('--child-process');
    await _executeCommand(cleanArgs);
    return;
  }

  // Standard execution if hot restart is disabled
  await _executeCommand(arguments);
}

bool _handleDaemonHelpOrInvalidArguments(List<String> arguments) {
  if (arguments.isEmpty ||
      !const {'daemon', 'start'}.contains(arguments.first.toLowerCase())) {
    return false;
  }
  final remaining = arguments.sublist(1);
  final visible = remaining
      .where((value) => value != '--child-process')
      .toList();
  if (visible.length == 1 &&
      const {'help', '-h', '--help'}.contains(visible.single)) {
    print('Usage: sanad daemon');
    print('Starts the supervised Sanad Agent daemon.');
    return true;
  }
  if (visible.isNotEmpty) {
    stderr.writeln('Unknown daemon argument: ${visible.first}');
    stderr.writeln('Usage: sanad daemon');
    exitCode = 64;
    return true;
  }
  return false;
}

Future<void> _executeCommand(List<String> arguments) async {
  if (arguments.isEmpty) {
    // Default fallback: Run the interactive CLI chat
    await cli.main([]);
    return;
  }

  final command = arguments.first.toLowerCase();
  final remainingArgs = arguments.sublist(1);

  switch (command) {
    case 'chat':
    case 'cli':
      await cli.main(remainingArgs);
      break;

    case 'daemon':
    case 'start':
      await daemon.main(remainingArgs);
      break;

    case 'setup':
      await setup.main(remainingArgs);
      break;

    case 'login':
      await login_cmd.main(remainingArgs);
      break;

    case 'logout':
      await login_cmd.runLogout();
      break;

    case 'service':
      await service_cmd.main(remainingArgs);
      break;

    case 'restart':
      await service_cmd.main(['restart']);
      break;

    case 'version':
    case '-v':
    case '--version':
      print('Sanad Agent');
      print('Version: $version');
      print(
        'Platform: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
      );
      break;

    case 'help':
    case '-h':
    case '--help':
      _printHelp();
      break;

    case 'update':
      await _runUpdater();
      break;

    default:
      print('Unknown command: "$command"\n');
      _printHelp();
      exit(1);
  }
}

void _printHelp() {
  print('=== ⚕ Sanad Agent CLI ===');
  print('Usage: sanad <command> [arguments]\n');
  print('Commands:');
  print(
    '  chat, cli         Launch the interactive CLI reasoning assistant (Default)',
  );
  print('  daemon, start     Launch the background daemon platform');
  print(
    '  setup             Configure your AI provider and API keys (subcommands: list, status, remove)',
  );
  print(
    '  login             Authenticate using Web Login or Device Token (--portal skips the token prompt)',
  );
  print('  logout            Remove session tokens and de-authenticate device');
  print(
    '  service           Manage background system daemon service (install/uninstall/status/restart)',
  );
  print('  restart           Restart the background system daemon service');
  print('  version, -v       Show current agent version and architecture');
  print('  update            Check and download the latest native release');
  print('  help, -h          Show this help dialog\n');
  print('Examples:');
  print('  sanad daemon');
  print('  sanad login');
  print('  sanad login --status');
  print('  sanad service install');
  print('  sanad restart');
  print('  sanad chat');
}

Future<void> _runUpdater() async {
  print('=== Sanad CLI Updater ===');
  final service = AgentUpdateService(
    currentVersion: version,
    executablePath: Platform.resolvedExecutable,
    isSourceManaged: AppConfig.isSourceRun,
  );
  final result = await service.update();
  print(result.message ?? result.status.wireName);
  if (result.availableVersion != null) {
    print('Available Version: ${result.availableVersion}');
  }
  if (Platform.isWindows && result.stagedPath != null) {
    await service.scheduleWindowsReplacement(result);
    await Process.run(Platform.resolvedExecutable, ['service', 'stop']);
    print('The verified update will be applied after Sanad exits.');
  }
  if (!result.isSuccess) exitCode = 1;
}
