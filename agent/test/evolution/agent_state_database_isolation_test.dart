import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
  });

  test('default database fails closed without explicit test isolation', () {
    expect(
      AgentStateDatabase.new,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Refusing to open the inherited Sanad state database'),
        ),
      ),
    );
  });

  test('explicit temporary home permits an isolated on-disk database', () {
    final tempDir = Directory.systemTemp.createTempSync(
      'sanad-agent-state-isolation-',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    setSanadHomeOverride(tempDir.path);

    final state = AgentStateDatabase();
    addTearDown(state.dispose);

    expect(File('${tempDir.path}/state.db').existsSync(), isTrue);
  });

  test('in-memory and explicit-path databases need no global override', () {
    final memory = AgentStateDatabase.inMemory();
    addTearDown(memory.dispose);

    final tempDir = Directory.systemTemp.createTempSync(
      'sanad-agent-explicit-state-',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final explicit = AgentStateDatabase.atPath(tempDir.path);
    addTearDown(explicit.dispose);

    expect(memory.db.select('SELECT 1').single.values.single, 1);
    expect(File('${tempDir.path}/state.db').existsSync(), isTrue);
  });
}
