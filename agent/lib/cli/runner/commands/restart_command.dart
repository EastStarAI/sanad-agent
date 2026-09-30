import 'dart:async';
import '../../../core/setup/service_manager.dart';
import '../sanad_command.dart';

/// Shorthand root command to restart the background system daemon service.
class RestartCommand extends SanadCommand {
  final FutureOr<int> Function()? onRestart;

  RestartCommand({this.onRestart, super.customAction});

  @override
  String get name => 'restart';

  @override
  String get description => 'Restart the background system daemon service';

  @override
  String get invocation => 'sanad restart';

  @override
  Future<int> execute() async {
    if (onRestart != null) {
      return await onRestart!();
    }
    final result = await ServiceManager.restart();
    return result.success ? 0 : 1;
  }
}
