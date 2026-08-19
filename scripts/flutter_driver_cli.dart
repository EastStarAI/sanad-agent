import 'dart:io';

import 'flutter_driver_cli/cli_runner.dart';

Future<void> main(List<String> args) async {
  final runner = CliRunner(args);
  final exitCode = await runner.run();
  exit(exitCode);
}
