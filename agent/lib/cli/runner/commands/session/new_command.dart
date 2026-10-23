import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../sanad_command.dart';

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
