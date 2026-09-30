import 'dart:async';
import '../sanad_command.dart';

/// Command to inspect and manage background schedules and cron tasks.
class ScheduleCommand extends SanadCommand {
  ScheduleCommand({super.customAction}) {
    addSubcommand(
      ScheduleListCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'schedule';

  @override
  String get description =>
      'Inspect and manage background schedules and cron tasks';

  @override
  String get invocation => 'sanad schedule <subcommand> [options]';

  @override
  Future<int> execute() async {
    printUsage();
    return 0;
  }
}

class ScheduleListCommand extends SanadCommand {
  ScheduleListCommand({super.customAction});

  @override
  String get name => 'list';

  @override
  String get description => 'List active cron jobs and schedules';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('Active Scheduled Tasks:');
    stdoutSink.writeln('  (No active scheduled tasks)');
    return 0;
  }
}
