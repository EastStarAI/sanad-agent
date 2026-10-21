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
