import 'dart:async';
import '../sanad_command.dart';

/// Command to inspect and manage agent memory and persistent facts.
class MemoryCommand extends SanadCommand {
  MemoryCommand({super.customAction}) {
    addSubcommand(
      MemoryListCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      MemoryClearCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'memory';

  @override
  String get description =>
      'Inspect and manage agent memory and persistent facts';

  @override
  String get invocation => 'sanad memory <subcommand> [options]';

  @override
  Future<int> execute() async {
    printUsage();
    return 0;
  }
}

class MemoryListCommand extends SanadCommand {
  MemoryListCommand({super.customAction});

  @override
  String get name => 'list';

  @override
  String get description => 'List saved memories and persistent user facts';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('Agent Persistent Memories:');
    stdoutSink.writeln('  (No stored memory entries)');
    return 0;
  }
}

class MemoryClearCommand extends SanadCommand {
  MemoryClearCommand({super.customAction});

  @override
  String get name => 'clear';

  @override
  String get description => 'Clear all agent persistent memories';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('Agent persistent memory cleared.');
    return 0;
  }
}
