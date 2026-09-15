import 'dart:async';
import '../../../core/setup/service_manager.dart';
import '../sanad_command.dart';

/// Command to manage background system daemon service.
class ServiceCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onService;

  ServiceCommand({this.onService, super.customAction}) {
    addSubcommand(
      ServiceInstallCommand(
        onService: onService,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      ServiceUninstallCommand(
        onService: onService,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      ServiceStatusCommand(
        onService: onService,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      ServiceStartCommand(
        onService: onService,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      ServiceStopCommand(
        onService: onService,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      ServiceRestartCommand(
        onService: onService,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'service';

  @override
  String get description =>
      'Manage background system daemon service (install/uninstall/status/restart/start/stop)';

  @override
  String get invocation => 'sanad service <subcommand> [options]';

  @override
  Future<int> execute() async {
    printUsage();
    return 0;
  }
}

class ServiceInstallCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onService;

  ServiceInstallCommand({this.onService, super.customAction}) {
    argParser
      ..addOption(
        'expected-version',
        help: 'Expected daemon version to verify after installation',
      )
      ..addFlag(
        'require-cloud',
        negatable: false,
        help: 'Require cloud gateway readiness',
      )
      ..addOption(
        'health-timeout',
        help: 'Health verification timeout in seconds (1-300)',
      );
  }

  @override
  String get name => 'install';

  @override
  String get description =>
      'Install and register the Sanad Agent background service';

  @override
  Future<int> execute() async {
    final args = <String>[
      'install',
      ...(argResults?.arguments ?? const <String>[]),
    ];
    if (onService != null) {
      return await onService!(args);
    }
    final result = await ServiceManager.install();
    return result.success ? 0 : 1;
  }
}

class ServiceUninstallCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onService;

  ServiceUninstallCommand({this.onService, super.customAction});

  @override
  String get name => 'uninstall';

  @override
  String get description =>
      'Uninstall and unregister the Sanad Agent background service';

  @override
  Future<int> execute() async {
    if (onService != null) {
      return await onService!(['uninstall']);
    }
    final result = await ServiceManager.uninstall();
    return result.success ? 0 : 1;
  }
}

class ServiceStatusCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onService;

  ServiceStatusCommand({this.onService, super.customAction});

  @override
  String get name => 'status';

  @override
  String get description =>
      'Inspect the current status of the background service';

  @override
  Future<int> execute() async {
    if (onService != null) {
      return await onService!(['status']);
    }
    final status = await ServiceManager.getStatus();
    return status.installed ? 0 : 1;
  }
}

class ServiceStartCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onService;

  ServiceStartCommand({this.onService, super.customAction});

  @override
  String get name => 'start';

  @override
  String get description => 'Start the installed background service';

  @override
  Future<int> execute() async {
    if (onService != null) {
      return await onService!(['start']);
    }
    final result = await ServiceManager.start();
    return result.success ? 0 : 1;
  }
}

class ServiceStopCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onService;

  ServiceStopCommand({this.onService, super.customAction});

  @override
  String get name => 'stop';

  @override
  String get description => 'Stop the running background service';

  @override
  Future<int> execute() async {
    if (onService != null) {
      return await onService!(['stop']);
    }
    final result = await ServiceManager.stop();
    return result.success ? 0 : 1;
  }
}

class ServiceRestartCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onService;

  ServiceRestartCommand({this.onService, super.customAction});

  @override
  String get name => 'restart';

  @override
  String get description => 'Restart the running background service';

  @override
  Future<int> execute() async {
    if (onService != null) {
      return await onService!(['restart']);
    }
    final result = await ServiceManager.restart();
    return result.success ? 0 : 1;
  }
}
