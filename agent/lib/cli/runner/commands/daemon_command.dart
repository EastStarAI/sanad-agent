import 'dart:async';
import 'dart:io';
import '../sanad_command.dart';

/// Command to launch the background daemon platform.
class DaemonCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onDaemon;

  DaemonCommand({this.onDaemon, super.customAction}) {
    addCommonOptions(argParser);
    argParser.addFlag(
      'child-process',
      hide: true,
      help: 'Internal child process indicator',
    );
  }

  @override
  String get name => 'daemon';

  @override
  List<String> get aliases => const ['start'];

  @override
  String get description => 'Launch the background daemon platform';

  @override
  String get invocation => 'sanad daemon [options]';

  @override
  Future<int> execute() async {
    final remaining = (argResults?.rest ?? const [])
        .where((arg) => arg != '--child-process')
        .toList();
    if (remaining.isNotEmpty) {
      stderr.writeln('Unknown daemon argument: ${remaining.first}');
      stderr.writeln('Usage: sanad daemon');
      return 64;
    }
    if (onDaemon != null) {
      return await onDaemon!(remaining);
    }
    return 0;
  }
}
