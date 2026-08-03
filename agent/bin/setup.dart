import 'package:sanad_agent/core/setup/env_template.dart';
import 'package:sanad_agent/core/setup/cli_provider_setup.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

/// Entry point for `sanad setup`.
///
/// Subcommands:
///   sanad setup             Interactive provider setup wizard.
///   sanad setup list        List all supported providers and their state.
///   sanad setup status      Show provider readiness and active model.
///   sanad setup remove `<id>` Remove a single provider's settings.
Future<void> main(List<String> args) async {
  print('');
  print('┌─────────────────────────────────────────────────────────┐');
  print('│             ⚕ Sanad Agent Setup Wizard                   │');
  print('├─────────────────────────────────────────────────────────┤');
  print('│  Configure your AI Model & API Provider                 │');
  print('└─────────────────────────────────────────────────────────┘');
  print('');

  await SanadHomeBootstrap.prepareAll();
  if (!SanadHomeBootstrap.identity().fileExists('.env')) {
    await SanadHomeBootstrap.identity().writeConfigText(
      '.env',
      defaultEnvContent,
    );
  }

  final services = CliProviderServices();
  final cli = CliProviderSetup(services);

  if (args.isEmpty) {
    await cli.runWizard();
    print('');
    print('To start chatting, run:');
    print('  sanad chat');
    print('');
    return;
  }

  final sub = args.first.toLowerCase();
  switch (sub) {
    case 'list':
    case 'providers':
      cli.listProviders();
      break;
    case 'status':
      cli.status();
      break;
    case 'remove':
      if (args.length < 2) {
        print('Usage: sanad setup remove <provider_id>');
        print('Example: sanad setup remove openai');
        return;
      }
      await cli.removeProvider(args[1]);
      break;
    case 'help':
    case '-h':
      _printHelp();
      break;
    default:
      print('Unknown setup subcommand: "$sub"\n');
      _printHelp();
  }
}

void _printHelp() {
  print('Usage: sanad setup [subcommand]\n');
  print('Subcommands:');
  print('  (none)          Interactive provider setup wizard');
  print('  list            List all supported providers and their state');
  print('  status          Show provider readiness and active model');
  print('  remove <id>     Remove a single provider\'s settings');
  print('  help            Show this help\n');
  print('Examples:');
  print('  sanad setup');
  print('  sanad setup list');
  print('  sanad setup remove openai');
}
