import 'dart:async';
import '../sanad_command.dart';

/// Command to authenticate using Web Login or Device Token.
class LoginCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onLogin;

  LoginCommand({this.onLogin, super.customAction}) {
    argParser
      ..addFlag(
        'status',
        negatable: false,
        help: 'Show current device authentication and pairing status',
      )
      ..addFlag(
        'cancel-pairing',
        negatable: false,
        help: 'Cancel pending device pairing exchange',
      )
      ..addFlag(
        'token-stdin',
        negatable: false,
        help: 'Read device pairing token securely from stdin',
      )
      ..addFlag(
        'portal',
        negatable: false,
        help: 'Skip token prompt and open authentication portal in browser',
      );
  }

  @override
  String get name => 'login';

  @override
  String get description => 'Authenticate using Web Login or Device Token';

  @override
  String get invocation => 'sanad login [token] [options]';

  @override
  Future<int> execute() async {
    final rawArgs = argResults?.arguments ?? const [];
    if (onLogin != null) {
      return await onLogin!(rawArgs);
    }
    return 0;
  }
}
