// Spawned by mcp_stdio_environment_test.dart with a real sentinel credential
// in this process's environment. Connects one STDIO MCP server through the
// production path; the "server" only records its own environment.
import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';

Future<void> main(List<String> args) async {
  final output = File(args.single);
  runZonedGuarded(() {
    unawaited(
      McpRuntimeManager().connectToClient(
        McpServerConfig(
          name: 'env-probe',
          transport: McpTransportType.stdio,
          command: '/bin/sh',
          args: ['-c', 'env > "${output.path}"; cat > /dev/null'],
        ),
        resolvedEnvironment: const {'MCP_CONFIGURED_VALUE': 'configured'},
      ),
    );
  }, (_, _) {});
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!(output.existsSync() && output.lengthSync() > 0)) {
    if (DateTime.now().isAfter(deadline)) exit(2);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  exit(0);
}
