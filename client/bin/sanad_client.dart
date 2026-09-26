import 'dart:io';

import 'package:sanad_client/features/client_cli/cli/sanad_client_runner.dart';

Future<void> main(List<String> arguments) async {
  final runner = SanadClientRunner();
  final exitCode = await runner.run(arguments);
  exit(exitCode);
}
