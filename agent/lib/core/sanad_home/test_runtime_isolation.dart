import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants.dart';

/// Whether this isolate is executing inside the Dart test runner.
bool isDartTestRuntime() {
  if (Zone.current[#test.invoker] != null) return true;
  // Suite-level initializers run before the test invoker Zone exists. The VM
  // runner executes those initializers from its generated dart_test kernel.
  final script = Platform.script.toString();
  return script.contains('dart_test.kernel.') && script.endsWith('.dill');
}

/// Refuses, inside the Dart test runtime only, to let [operation] open the
/// Sanad Home root at [path] unless the test isolated its state explicitly
/// (see [hasExplicitSanadStateIsolation]) and [path] is not the OS user's real
/// default Home ([defaultSanadHome]).
///
/// Production processes are never affected. A test that reaches this guard
/// must inject an in-memory owner or select temporary roots with
/// `setSanadHomeOverride`/`setSanadStateHomeOverride` (or `SANAD_STATE_HOME`).
void rejectUnisolatedTestHomeAccess(String operation, {required String path}) {
  if (!isDartTestRuntime()) return;
  if (!hasExplicitSanadStateIsolation()) {
    throw StateError(
      'Refusing to $operation from a Dart test without explicit Sanad state '
      'isolation. Inject an in-memory owner or select temporary roots with '
      'setSanadHomeOverride(), setSanadStateHomeOverride(), or SANAD_STATE_HOME.',
    );
  }
  final realHome = defaultSanadHome();
  if (realHome != null && _canonical(path) == _canonical(realHome)) {
    throw StateError(
      'Refusing to $operation from a Dart test: the selected root is the real '
      'default Sanad Home. Select a temporary root instead.',
    );
  }
}

/// Refuses to run the E2E runtime ([isSanadE2eTestMode]) against anything
/// but temporary roots; a no-op outside E2E mode.
///
/// E2E mode swaps in the deterministic provider and the owner-only file secret
/// store, so a real runtime started with it by mistake would hide the user's
/// OS-vault secrets and write new ones to a file. It therefore requires an
/// explicit `SANAD_STATE_HOME` separate from the selected identity Home, and
/// neither root may be the OS user's real default Home. Throws [StateError]
/// before any Home access when the rule is violated.
void requireSanadE2eTestIsolation() {
  if (!isSanadE2eTestMode()) return;
  final stateHome = Platform.environment['SANAD_STATE_HOME']?.trim() ?? '';
  final identityHome = getSanadHome();
  if (stateHome.isEmpty || _canonical(stateHome) == _canonical(identityHome)) {
    throw StateError(
      'SANAD_E2E_TEST_MODE requires SANAD_STATE_HOME to be isolated from SANAD_HOME.',
    );
  }
  final realHome = defaultSanadHome();
  if (realHome != null &&
      (_canonical(identityHome) == _canonical(realHome) ||
          _canonical(stateHome) == _canonical(realHome))) {
    throw StateError(
      'SANAD_E2E_TEST_MODE refuses the real default Sanad Home; select '
      'temporary SANAD_HOME and SANAD_STATE_HOME roots.',
    );
  }
}

String _canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    final dir = Directory(absolute);
    if (dir.existsSync()) return dir.resolveSymbolicLinksSync();
  } on FileSystemException {
    // Lexical form below.
  }
  return absolute;
}
