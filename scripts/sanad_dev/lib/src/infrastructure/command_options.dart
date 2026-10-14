const defaultSanadDevClientConfig = 'config/prod.json';

enum SanadDevSetupStage {
  fvm,
  flutterSdk,
  agentDependencies,
  clientDependencies,
  userCommand,
}

enum SanadDevSetupStageStatus { success, skipped, failed }

class SanadDevSetupStageResult {
  const SanadDevSetupStageResult(this.stage, this.status, {this.message});

  final SanadDevSetupStage stage;
  final SanadDevSetupStageStatus status;
  final String? message;
}

enum SanadDevComponentTarget { all, agent, client }

class SanadDevComponentCommand {
  const SanadDevComponentCommand({
    required this.command,
    required this.target,
    required this.device,
    required this.deviceWasSpecified,
    required this.force,
  });

  final String command;
  final SanadDevComponentTarget target;
  final String? device;
  final bool deviceWasSpecified;
  final bool force;
}

SanadDevComponentCommand parseSanadDevComponentCommand(List<String> args) {
  if (args.isEmpty) {
    throw const FormatException('A sanad-dev command is required.');
  }
  final command = args.first.toLowerCase();
  if (command != 'run' && command != 'stop') {
    throw FormatException(
      'Component command parsing does not support "$command".',
    );
  }

  var target = SanadDevComponentTarget.all;
  if (args.length > 1 && !args[1].startsWith('-')) {
    target = switch (args[1].toLowerCase()) {
      'all' => SanadDevComponentTarget.all,
      'agent' => SanadDevComponentTarget.agent,
      'client' => SanadDevComponentTarget.client,
      final value => throw FormatException(
        'Unknown $command target: $value. Supported targets: all, agent, client.',
      ),
    };
  }

  String? device;
  var deviceWasSpecified = false;
  var force = false;
  for (var index = 1; index < args.length; index++) {
    final argument = args[index];
    if (argument == '--force') {
      force = true;
      continue;
    }
    if (argument == '-d' || argument == '--device') {
      deviceWasSpecified = true;
      if (index + 1 >= args.length || args[index + 1].startsWith('-')) {
        throw FormatException('$argument requires a Flutter device id.');
      }
      device = args[++index];
      continue;
    }
    if (argument.startsWith('--device=')) {
      deviceWasSpecified = true;
      device = argument.substring('--device='.length);
      if (device.isEmpty) {
        throw const FormatException('--device requires a Flutter device id.');
      }
    }
  }

  if (command == 'run' && force) {
    throw const FormatException('--force is supported only by stop agent/all.');
  }
  if (command == 'run' &&
      target == SanadDevComponentTarget.agent &&
      deviceWasSpecified) {
    throw const FormatException(
      'run agent does not accept -d/--device because it starts no Flutter client.',
    );
  }
  if (command == 'stop') {
    if (target != SanadDevComponentTarget.client && deviceWasSpecified) {
      throw FormatException(
        'stop ${target.name} does not accept -d/--device. Use stop client -d <id>.',
      );
    }
    if (target == SanadDevComponentTarget.client && force) {
      throw const FormatException(
        'stop client does not accept --force; client shutdown already uses bounded cleanup.',
      );
    }
  }

  return SanadDevComponentCommand(
    command: command,
    target: target,
    device: device,
    deviceWasSpecified: deviceWasSpecified,
    force: force,
  );
}
