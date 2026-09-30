import 'dart:async';
import '../sanad_command.dart';

/// Command to inspect and manage Model Context Protocol (MCP) servers.
class McpCommand extends SanadCommand {
  McpCommand({super.customAction}) {
    addSubcommand(
      McpListCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'mcp';

  @override
  String get description =>
      'Inspect and manage Model Context Protocol (MCP) servers';

  @override
  String get invocation => 'sanad mcp <subcommand> [options]';

  @override
  Future<int> execute() async {
    printUsage();
    return 0;
  }
}

class McpListCommand extends SanadCommand {
  McpListCommand({super.customAction});

  @override
  String get name => 'list';

  @override
  String get description => 'List configured MCP servers and their status';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('Configured MCP Servers:');
    stdoutSink.writeln(
      '  (No external MCP servers configured in ~/.sanad/mcp/)',
    );
    return 0;
  }
}
