import 'dart:async';
import 'dart:io';
import '../../../core/constants.dart';
import '../sanad_command.dart';

/// Command to show current agent version and architecture.
class VersionCommand extends SanadCommand {
  final StringSink? output;

  VersionCommand({this.output, super.customAction});

  @override
  String get name => 'version';

  @override
  String get description => 'Show current agent version and architecture';

  @override
  String get invocation => 'sanad version';

  @override
  Future<int> execute() async {
    printVersion(output: output);
    return 0;
  }
}

/// Helper function to format and print version output.
void printVersion({String? versionOverride, StringSink? output}) {
  final sink = output ?? stdout;
  final version = versionOverride ?? loadAgentVersion();
  sink.writeln('Sanad Agent');
  sink.writeln('Version: $version');
  sink.writeln(
    'Platform: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
  );
}
