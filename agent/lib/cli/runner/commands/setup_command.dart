import 'dart:async';
import '../../../core/setup/cli_provider_setup.dart';
import '../sanad_command.dart';

/// Command to configure AI providers and API keys.
class SetupCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onSetup;

  SetupCommand({this.onSetup, super.customAction}) {
    // The bare command keeps the injected interactive entry point; every
    // subcommand owns its own implementation so `--json` reaches
    // `CliProviderSetup` (issue 339 review 2).
    addSubcommand(
      SetupListCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SetupStatusCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SetupRemoveCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Configure your AI provider and API keys (subcommands: list, status, remove)';

  @override
  String get invocation => 'sanad setup [subcommand]';

  @override
  Future<int> execute() async {
    if (onSetup != null) {
      return await onSetup!(const []);
    }
    final cli = CliProviderSetup(CliProviderServices());
    await cli.runWizard();
    return 0;
  }
}

class SetupListCommand extends SanadCommand {
  SetupListCommand({super.customAction});

  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['providers'];

  @override
  String get description =>
      'List all supported providers and their configuration status';

  @override
  Future<int> execute() async {
    final cli = CliProviderSetup(CliProviderServices());
    cli.listProviders(out: stdoutSink, json: json);
    return 0;
  }
}

class SetupStatusCommand extends SanadCommand {
  SetupStatusCommand({super.customAction});

  @override
  String get name => 'status';

  @override
  String get description => 'Show provider readiness and active model';

  @override
  Future<int> execute() async {
    final cli = CliProviderSetup(CliProviderServices());
    cli.status(out: stdoutSink, json: json);
    return 0;
  }
}

class SetupRemoveCommand extends SanadCommand {
  SetupRemoveCommand({super.customAction});

  @override
  String get name => 'remove';

  @override
  String get description =>
      'Remove configuration and keys for a single provider';

  @override
  String get invocation => 'sanad setup remove <provider-id>';

  @override
  Future<int> execute() async {
    final rest = argResults?.rest ?? const [];
    if (rest.isEmpty) {
      return 1;
    }
    final cli = CliProviderSetup(CliProviderServices());
    await cli.removeProvider(rest.first);
    return 0;
  }
}
