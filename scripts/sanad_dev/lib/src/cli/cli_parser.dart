part of '../../sanad_dev_cli.dart';

class SanadDevCliInvocation {
  const SanadDevCliInvocation({
    required this.command,
    required this.target,
    this.componentCommand,
    required this.follow,
    required this.waitForLogs,
    this.tailCount,
    this.portOverride,
    this.journalAgentPort,
    required this.driverMode,
    required this.cloudEnabled,
    required this.dryRun,
    required this.backgroundMode,
    required this.internalBackgroundMode,
    required this.forceRestart,
    required this.fix,
    required this.restartTimeoutSeconds,
    required this.device,
    required this.configPath,
    this.clientInstanceSlot,
    this.sanadHomePath,
    required this.runtimeSelector,
  });

  final String command;
  final String target;
  final SanadDevComponentCommand? componentCommand;
  final bool follow;
  final bool waitForLogs;
  final int? tailCount;
  final int? portOverride;
  final int? journalAgentPort;
  final bool driverMode;
  final bool cloudEnabled;
  final bool dryRun;
  final bool backgroundMode;
  final bool internalBackgroundMode;
  final bool forceRestart;
  final bool fix;
  final int restartTimeoutSeconds;
  final String device;
  final String configPath;
  final String? clientInstanceSlot;
  final String? sanadHomePath;
  final String runtimeSelector;
}

SanadDevCliInvocation? parseSanadDevInvocation(List<String> args) {
  final command = args[0].toLowerCase();

  SanadDevComponentCommand? componentCommand;
  if (command == 'run' || command == 'stop') {
    try {
      componentCommand = parseSanadDevComponentCommand(args);
    } on FormatException catch (error) {
      stderr.writeln(error.message);
      exitCode = 64;
      return null;
    }
  }
  String target = componentCommand?.target.name ?? 'client';
  if (componentCommand == null && args.length > 1 && !args[1].startsWith('-')) {
    target = args[1].toLowerCase();
  }

  bool follow = false;
  bool waitForLogs = false;
  int? tailCount;
  int? portOverride;
  int? journalAgentPort;
  bool driverMode = false;
  final cloudEnabled = resolveSanadDevCloudEnabled(args);
  bool dryRun = false;
  bool backgroundMode = false;
  bool internalBackgroundMode = false;
  bool forceRestart = false;
  bool fix = false;
  int restartTimeoutSeconds = 60;
  String device = _defaultDesktopDevice();
  String configPath = defaultSanadDevClientConfig;
  String? clientInstanceSlot;
  String? sanadHomePath;
  String runtimeSelector = 'current';

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-f' || arg == '--follow') {
      follow = true;
    } else if (arg == '--wait') {
      waitForLogs = true;
    } else if (arg == '-n' || arg == '--tail') {
      if (i + 1 < args.length) {
        tailCount = int.tryParse(args[i + 1]);
      }
    } else if (arg.startsWith('--tail=')) {
      tailCount = int.tryParse(arg.substring(7));
    } else if (arg == '-p' || arg == '--port') {
      if (i + 1 < args.length) {
        portOverride = int.tryParse(args[i + 1]);
      }
    } else if (arg.startsWith('--port=')) {
      portOverride = int.tryParse(arg.substring(7));
    } else if (arg == '--agent-port' && i + 1 < args.length) {
      journalAgentPort = int.tryParse(args[i + 1]);
    } else if (arg.startsWith('--agent-port=')) {
      journalAgentPort = int.tryParse(arg.substring(13));
    } else if (arg == '--driver') {
      driverMode = true;
    } else if (arg == '--dry-run') {
      dryRun = true;
    } else if (arg == '--background') {
      backgroundMode = true;
    } else if (arg == '--internal-background') {
      internalBackgroundMode = true;
    } else if (arg == '--force') {
      forceRestart = true;
    } else if (arg == '--fix') {
      fix = true;
    } else if (arg == '--timeout' && i + 1 < args.length) {
      restartTimeoutSeconds = int.tryParse(args[i + 1]) ?? -1;
    } else if (arg.startsWith('--timeout=')) {
      restartTimeoutSeconds = int.tryParse(arg.substring(10)) ?? -1;
    } else if ((arg == '-d' || arg == '--device') && i + 1 < args.length) {
      device = args[i + 1];
    } else if (arg.startsWith('--device=')) {
      device = arg.substring(9);
    } else if (arg == '--client-instance' && i + 1 < args.length) {
      clientInstanceSlot = args[i + 1];
    } else if (arg.startsWith('--client-instance=')) {
      clientInstanceSlot = arg.substring(18);
    } else if (arg == '--config' && i + 1 < args.length) {
      configPath = args[i + 1];
    } else if (arg.startsWith('--config=')) {
      configPath = arg.substring(9);
    } else if (arg == '--home' && i + 1 < args.length) {
      sanadHomePath = args[i + 1];
    } else if (arg.startsWith('--home=')) {
      sanadHomePath = arg.substring(7);
    } else if (arg == '--runtime' && i + 1 < args.length) {
      runtimeSelector = args[i + 1].toLowerCase();
    } else if (arg.startsWith('--runtime=')) {
      runtimeSelector = arg.substring(10).toLowerCase();
    }
  }

  return SanadDevCliInvocation(
    command: command,
    target: target,
    componentCommand: componentCommand,
    follow: follow,
    waitForLogs: waitForLogs,
    tailCount: tailCount,
    portOverride: portOverride,
    journalAgentPort: journalAgentPort,
    driverMode: driverMode,
    cloudEnabled: cloudEnabled,
    dryRun: dryRun,
    backgroundMode: backgroundMode,
    internalBackgroundMode: internalBackgroundMode,
    forceRestart: forceRestart,
    fix: fix,
    restartTimeoutSeconds: restartTimeoutSeconds,
    device: device,
    configPath: configPath,
    clientInstanceSlot: clientInstanceSlot,
    sanadHomePath: sanadHomePath,
    runtimeSelector: runtimeSelector,
  );
}
