import 'dart:async';
import '../../../core/setup/cli_provider_setup.dart';
import '../sanad_command.dart';

/// Command to list supported and configured AI providers.
class ProvidersCommand extends SanadCommand {
  ProvidersCommand({super.customAction});

  @override
  String get name => 'providers';

  @override
  String get description => 'List supported and configured AI providers';

  @override
  String get invocation => 'sanad providers';

  @override
  Future<int> execute() async {
    final services = CliProviderServices();
    final cli = CliProviderSetup(services);
    cli.listProviders();
    return 0;
  }
}
