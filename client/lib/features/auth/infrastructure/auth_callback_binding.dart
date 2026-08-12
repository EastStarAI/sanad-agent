import 'auth_callback_contract.dart';
import 'auth_callback_binding_stub.dart'
    if (dart.library.io) 'auth_callback_binding_native.dart'
    if (dart.library.html) 'auth_callback_binding_web.dart';

export 'auth_callback_contract.dart';

Future<AuthCallbackBinding> createAuthCallbackBinding() => createPlatformAuthCallbackBinding();
