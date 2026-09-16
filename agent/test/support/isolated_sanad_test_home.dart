import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

/// Gives every test in the calling suite separate temporary identity and state
/// roots, overriding any SANAD_HOME/SANAD_STATE_HOME inherited by the runner.
void useIsolatedSanadTestHome() {
  late Directory root;

  setUp(() async {
    await getIt.reset();
    // ignore: invalid_use_of_visible_for_testing_member
    SessionManager.resetForTesting();
    root = await Directory.systemTemp.createTemp('sanad-test-roots-');
    final home = Directory('${root.path}/home')..createSync();
    final stateHome = Directory('${root.path}/state')..createSync();
    setSanadHomeOverride(home.path);
    setSanadStateHomeOverride(stateHome.path);
  });

  tearDown(() async {
    if (getIt.isRegistered<AgentStateDatabase>()) {
      getIt<AgentStateDatabase>().dispose();
    }
    await getIt.reset();
    // ignore: invalid_use_of_visible_for_testing_member
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (await root.exists()) await root.delete(recursive: true);
  });
}
