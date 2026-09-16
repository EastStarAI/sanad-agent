import 'dart:async';
import '../sanad_command.dart';

/// Command to remove session tokens and de-authenticate device.
class LogoutCommand extends SanadCommand {
  final FutureOr<int> Function()? onLogout;

  LogoutCommand({this.onLogout, super.customAction});

  @override
  String get name => 'logout';

  @override
  String get description => 'Remove session tokens and de-authenticate device';

  @override
  String get invocation => 'sanad logout';

  @override
  Future<int> execute() async {
    if (onLogout != null) {
      return await onLogout!();
    }
    return 0;
  }
}
