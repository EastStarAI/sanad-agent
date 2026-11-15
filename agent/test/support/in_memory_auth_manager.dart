/// Minimal `AuthManager` for tests that only need the daemon `hardware_id`.
///
/// Canonical envelope construction and capability projection read exactly one
/// value from the auth owner, so a full manager would pull credentials and the
/// operating-system vault into a unit test that has nothing to do with either.
library;

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/di.dart';

class InMemoryAuthManager implements AuthManager {
  InMemoryAuthManager({this.hardwareId = 'test-device-id'});

  @override
  final String? hardwareId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Registers [InMemoryAuthManager] as the process `AuthManager`.
void registerInMemoryAuthManager({String hardwareId = 'test-device-id'}) {
  if (getIt.isRegistered<AuthManager>()) {
    getIt.unregister<AuthManager>();
  }
  getIt.registerSingleton<AuthManager>(
    InMemoryAuthManager(hardwareId: hardwareId),
  );
}
