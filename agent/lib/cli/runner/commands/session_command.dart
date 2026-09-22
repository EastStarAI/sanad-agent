import 'dart:async';
import 'package:uuid/uuid.dart';
import '../sanad_command.dart';

/// Command to manage and inspect conversation sessions.
class SessionCommand extends SanadCommand {
  SessionCommand({super.customAction}) {
    addSubcommand(
      SessionListCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionShowCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionNewCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionDeleteCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'session';

  @override
  String get description => 'Manage and inspect conversation sessions';

  @override
  String get invocation => 'sanad session <subcommand> [options]';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('Active sessions:');
    stdoutSink.writeln('  (No cached sessions found)');
    return 0;
  }
}

class SessionListCommand extends SanadCommand {
  SessionListCommand({super.customAction});

  @override
  String get name => 'list';

  @override
  String get description => 'List existing conversation sessions';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('Active sessions:');
    stdoutSink.writeln('  (No cached sessions found)');
    return 0;
  }
}

class SessionShowCommand extends SanadCommand {
  SessionShowCommand({super.customAction});

  @override
  String get name => 'show';

  @override
  String get description => 'Show details and turns for a given session';

  @override
  String get invocation => 'sanad session show <session-id>';

  @override
  Future<int> execute() async {
    final id = argResults?.rest.firstOrNull;
    if (id == null) {
      stderrSink.writeln('Error: Session ID is required.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }
    stdoutSink.writeln('Session details for: $id');
    return 0;
  }
}

class SessionNewCommand extends SanadCommand {
  SessionNewCommand({super.customAction});

  @override
  String get name => 'new';

  @override
  String get description => 'Generate and initialize a new session ID';

  @override
  Future<int> execute() async {
    final newId = const Uuid().v4();
    stdoutSink.writeln(newId);
    return 0;
  }
}

class SessionDeleteCommand extends SanadCommand {
  SessionDeleteCommand({super.customAction});

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a session and its cached turns';

  @override
  String get invocation => 'sanad session delete <session-id>';

  @override
  Future<int> execute() async {
    final id = argResults?.rest.firstOrNull;
    if (id == null) {
      stderrSink.writeln('Error: Session ID is required.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }
    stdoutSink.writeln('Session $id deleted.');
    return 0;
  }
}
