import 'dart:async';
import '../../../core/setup/cli_provider_setup.dart';
import '../sanad_command.dart';

/// Command to configure AI providers and API keys.
class SetupCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onSetup;

  SetupCommand({this.onSetup, super.customAction}) {
    addSubcommand(
      SetupListCommand(
        onSetup: onSetup,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SetupStatusCommand(
        onSetup: onSetup,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SetupRemoveCommand(
        onSetup: onSetup,
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
  final FutureOr<int> Function(List<String> args)? onSetup;

  SetupListCommand({this.onSetup, super.customAction});

  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['providers'];

  @override
  String get description =>
      'List all supported providers and their configuration status';

  @override
  Future<int> execute() async {
    if (onSetup != null) {
      return await onSetup!(['list']);
    }
    final cli = CliProviderSetup(CliProviderServices());
    cli.listProviders();
    return 0;
  }
}

class SetupStatusCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onSetup;

  SetupStatusCommand({this.onSetup, super.customAction});

  @override
  String get name => 'status';

  @override
  String get description => 'Show provider readiness and active model';

  @override
  Future<int> execute() async {
    if (onSetup != null) {
      return await onSetup!(['status']);
    }
    final cli = CliProviderSetup(CliProviderServices());
    cli.status();
    return 0;
  }
}

class SetupRemoveCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onSetup;

  SetupRemoveCommand({this.onSetup, super.customAction});

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
    if (onSetup != null) {
      return await onSetup!(['remove', ...rest]);
    }
    if (rest.isEmpty) {
      return 1;
    }
    final cli = CliProviderSetup(CliProviderServices());
    await cli.removeProvider(rest.first);
    return 0;
  }
}
