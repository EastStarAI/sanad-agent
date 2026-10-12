import 'dart:io';

import 'package:sanad_agent/core/setup/windows_launcher_bundle.dart';

Future<void> main(List<String> arguments) async {
  final values = _parse(arguments);
  final agent = File(values.$1);
  final launcher = File(values.$2);
  if (!agent.existsSync() || !launcher.existsSync()) {
    stderr.writeln('Agent and launcher files must exist.');
    exitCode = 2;
    return;
  }

  await WindowsLauncherBundle.embed(agent: agent, launcher: launcher);
  stdout.writeln('Embedded ${await launcher.length()} launcher bytes.');
}

(String, String) _parse(List<String> arguments) {
  String? agent;
  String? launcher;
  for (var index = 0; index < arguments.length; index++) {
    switch (arguments[index]) {
      case '--agent':
        agent = index + 1 < arguments.length ? arguments[++index] : null;
      case '--launcher':
        launcher = index + 1 < arguments.length ? arguments[++index] : null;
      default:
        _usage();
    }
  }
  if (agent == null || launcher == null) _usage();
  return (agent, launcher);
}

Never _usage() {
  stderr.writeln(
    'Usage: package_windows_launcher.dart --agent PATH --launcher PATH',
  );
  exit(2);
}
