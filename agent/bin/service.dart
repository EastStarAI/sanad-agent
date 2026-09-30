import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/setup/service_health_verifier.dart';
import 'package:sanad_agent/core/setup/service_manager.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || _isHelp(args)) {
    _printUsage();
    return;
  }
  final command = args.first.toLowerCase();
  if (command == 'status' && args.length == 1) {
    _printStatus(await ServiceManager.getStatus());
    return;
  }

  ServiceHealthExpectation? healthExpectation;
  if (command == 'install') {
    try {
      healthExpectation = _parseHealthExpectation(args.sublist(1));
    } on FormatException catch (error) {
      stderr.writeln(error.message);
      _printUsage();
      exitCode = 1;
      return;
    }
  } else if (args.length != 1) {
    stderr.writeln('This service action does not accept options.');
    _printUsage();
    exitCode = 1;
    return;
  }

  final operation = switch (command) {
    'install' => () => ServiceManager.install(
      healthExpectation: healthExpectation,
    ),
    'uninstall' => ServiceManager.uninstall,
    'start' => ServiceManager.start,
    'stop' => ServiceManager.stop,
    'restart' => ServiceManager.restart,
    _ => null,
  };
  if (operation == null) {
    stderr.writeln('Unknown service command: "$command"');
    _printUsage();
    exitCode = 1;
    return;
  }
  stdout.writeln(
    '${_operationVerb(command)} Sanad Agent background service...',
  );
  final result = await operation();

  if (!result.success) {
    stderr.writeln(
      'Service operation failed: ${result.error ?? result.status.error ?? 'unknown error'}',
    );
    _printStatus(result.status);
    exitCode = 1;
    return;
  }
  stdout.writeln('Service operation completed successfully.');
  _printStatus(result.status);
}

ServiceHealthExpectation? _parseHealthExpectation(List<String> args) {
  if (args.isEmpty) return null;
  String? expectedVersion;
  var requireCloud = false;
  var timeout = const Duration(seconds: 60);
  for (var index = 0; index < args.length; index++) {
    switch (args[index]) {
      case '--expected-version':
        if (++index >= args.length || args[index].trim().isEmpty) {
          throw const FormatException('--expected-version requires a value.');
        }
        expectedVersion = args[index].trim();
      case '--require-cloud':
        requireCloud = true;
      case '--health-timeout':
        if (++index >= args.length) {
          throw const FormatException('--health-timeout requires seconds.');
        }
        final seconds = int.tryParse(args[index]);
        if (seconds == null || seconds < 1 || seconds > 300) {
          throw const FormatException(
            '--health-timeout must be between 1 and 300 seconds.',
          );
        }
        timeout = Duration(seconds: seconds);
      default:
        throw FormatException('Unknown service install option: ${args[index]}');
    }
  }
  if (expectedVersion == null) {
    throw const FormatException(
      '--expected-version is required when install health options are used.',
    );
  }
  return ServiceHealthExpectation(
    expectedVersion: expectedVersion,
    requireCloudRegistration: requireCloud,
    timeout: timeout,
  );
}

bool _isHelp(List<String> args) =>
    args.length == 1 && const {'help', '-h', '--help'}.contains(args.single);

String _operationVerb(String command) => switch (command) {
  'install' => 'Installing',
  'uninstall' => 'Uninstalling',
  'start' => 'Starting',
  'stop' => 'Stopping',
  'restart' => 'Restarting',
  _ => 'Managing',
};

void _printStatus(ServiceStatus status) {
  stdout.writeln('Sanad Agent Service Status:');
  stdout.writeln('  State:      ${status.state.displayName}');
  stdout.writeln('  Installed:  ${status.installed ? "Yes" : "No"}');
  stdout.writeln('  Enabled:    ${status.enabled ? "Yes" : "No"}');
  stdout.writeln('  Running:    ${status.running ? "Yes" : "No"}');
  stdout.writeln('  Scope:      ${status.scope.wireName}');
  stdout.writeln('  Manager:    ${status.backend}');
  final credentialBackend = _credentialBackend();
  if (credentialBackend != null) {
    stdout.writeln('  Credentials: $credentialBackend');
  }
  if (status.error != null) stdout.writeln('  Error:      ${status.error}');
}

String? _credentialBackend() {
  if (!Platform.isLinux) return null;
  final file = File(p.join(getSanadHome(), 'agent_credential_backend.json'));
  if (!file.existsSync() ||
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
    return null;
  }
  try {
    final value = jsonDecode(file.readAsStringSync());
    return value is Map<String, dynamic> ? value['backend'] as String? : null;
  } catch (_) {
    return 'invalid-metadata';
  }
}

void _printUsage() {
  stdout.writeln('Usage: sanad service <action>\n');
  stdout.writeln('Actions:');
  stdout.writeln('  install      Register and start the agent daemon');
  stdout.writeln(
    '               [--expected-version VERSION] [--require-cloud] [--health-timeout SECONDS]',
  );
  stdout.writeln('  uninstall    Stop and unregister the owned service');
  stdout.writeln('  start        Start the registered service');
  stdout.writeln('  stop         Stop the running service');
  stdout.writeln('  restart      Restart the registered service');
  stdout.writeln(
    '  status       Show typed service and credential-backend status',
  );
}
