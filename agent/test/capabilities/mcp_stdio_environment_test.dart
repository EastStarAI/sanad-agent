import 'dart:io';

import 'package:test/test.dart';

/// The parent process carries a real credential in its environment. A STDIO
/// MCP server must see only the allowlist and its own configured values.
void main() {
  const sentinel = 'sk-mcp-isolation-sentinel-000000000000';

  test(
    'a STDIO MCP child never inherits the daemon environment',
    () async {
      final dir = Directory.systemTemp.createTempSync('sanad-mcp-env');
      addTearDown(() => dir.deleteSync(recursive: true));
      final output = '${dir.path}/mcp-env.txt';
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/env_probe/mcp_stdio_env_probe.dart', output],
        environment: {
          ...Platform.environment,
          'SANAD_HOME': Directory('${dir.path}/home').path,
          'SANAD_STATE_HOME': Directory('${dir.path}/state').path,
          'OPENAI_API_KEY': sentinel,
          'SANAD_UNRELATED_DAEMON_VALUE': sentinel,
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final env = File(output).readAsStringSync();
      expect(env, isNot(contains(sentinel)));
      expect(env, contains('MCP_CONFIGURED_VALUE=configured'));
      expect(RegExp(r'^PATH=', multiLine: true).hasMatch(env), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: Platform.isWindows ? 'uses /bin/sh' : false,
  );
}
