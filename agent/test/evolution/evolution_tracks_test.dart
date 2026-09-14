import 'dart:io';
import 'package:test/test.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/curator.dart';
import 'package:sanad_agent/capabilities/tools/delegate_task_tool.dart';
import 'package:sanad_agent/capabilities/tools/schedule_task_tool.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/engine/adapters/mock_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:get_it/get_it.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('sanad_evolution_test_');
    setSanadHomeOverride(tempDir.path);

    // Clear DI and setup again for test
    if (GetIt.I.isRegistered<SessionManager>()) {
      await GetIt.I.reset();
    }
    setupDI();

    // These evolution/tooling tests exercise sub-agent behavior with the
    // injected mock adapter, not the provider-runtime routing stack. Unregister
    // AgentRuntimeService so AgentRunner falls back to the mocked LLMAdapter
    // instead of requiring a default provider instance.
    if (GetIt.I.isRegistered<AgentRuntimeService>()) {
      GetIt.I.unregister<AgentRuntimeService>();
    }

    // Override LLMAdapter with Mock for tests
    getIt.allowReassignment = true;
    getIt.registerLazySingleton<LLMAdapter>(() => MockLLMAdapter());
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    await GetIt.I.reset();
  });

  group('DelegateTaskTool Tests', () {
    test('execute spawns a sub-agent and returns response', () async {
      final tool = DelegateTaskTool();
      final result = await tool.execute({
        'task': 'Say hello',
        'role': 'Greeter',
      });

      expect(result, contains('Sub-agent result:'));
      expect(result, contains('I am a mock AI'));
      expect(result, contains('Say hello'));
    });

    test('execute returns error for null or empty task', () async {
      final tool = DelegateTaskTool();
      final resultNull = await tool.execute({});
      expect(resultNull, contains('Error: "task" parameter is required'));

      final resultEmpty = await tool.execute({'task': '   '});
      expect(resultEmpty, contains('Error: "task" parameter is required'));
    });

    test('execute returns error for invalid role type', () async {
      final tool = DelegateTaskTool();
      final result = await tool.execute({'task': 'Say hello', 'role': 123});
      expect(
        result,
        contains('Error: "role" parameter, if provided, must be a string'),
      );
    });
  });

  group('CronScheduler Tests', () {
    test('scheduleTask triggers event after delay', () async {
      final scheduler = getIt<CronScheduler>();
      final event = scheduler.eventStream.firstWhere(
        (event) => event.type == 'cron' && event.message.content == 'Test Task',
      );

      scheduler.scheduleTask(
        DateTime.now().add(const Duration(milliseconds: 1)),
        'Test Task',
      );

      expect(
        (await event.timeout(
          const Duration(milliseconds: 250),
        )).message.content,
        'Test Task',
      );
    });
  });

  group('ScheduleTaskTool Tests', () {
    test('execute schedules a task in CronScheduler', () async {
      final tool = ScheduleTaskTool();
      final result = await tool.execute({
        'task': 'Auto Task',
        'time': 'in 1 seconds',
      });

      expect(result, contains('Task scheduled successfully'));

      // This test owns command-to-scheduler registration. Timer delivery is
      // covered separately by CronScheduler, so do not wait one real second.
      final scheduler = getIt<CronScheduler>();
      final scheduled = scheduler.activeTasks.singleWhere(
        (task) => task.task == 'Auto Task',
      );
      expect(scheduled.time.isAfter(DateTime.now()), isTrue);
      scheduled.timer.cancel();
    });

    test('execute returns error for null or empty task', () async {
      final tool = ScheduleTaskTool();

      final resultNull = await tool.execute({'time': 'in 1 seconds'});
      expect(resultNull, contains('Error: "task" parameter is required'));

      final resultEmpty = await tool.execute({
        'task': '  ',
        'time': 'in 1 seconds',
      });
      expect(resultEmpty, contains('Error: "task" parameter is required'));
    });

    test('execute returns error for null or empty time', () async {
      final tool = ScheduleTaskTool();

      final resultNull = await tool.execute({'task': 'Some Task'});
      expect(resultNull, contains('Error: "time" parameter is required'));

      final resultEmpty = await tool.execute({'task': 'Some Task', 'time': ''});
      expect(resultEmpty, contains('Error: "time" parameter is required'));
    });
  });

  group('Curator Tests', () {
    test('collectStats summarizes session data', () async {
      final sessionManager = getIt<SessionManager>();
      final curator = Curator(sessionManager: sessionManager);

      // Create some dummy sessions
      final s1 = sessionManager.createSession('model-a');
      sessionManager.saveSessionHistory(s1.sessionId, [
        Message(role: MessageRole.user, content: 'hi'),
        Message(role: MessageRole.assistant, content: 'hello'),
      ]);

      final s2 = sessionManager.createSession('model-b');
      sessionManager.saveSessionHistory(s2.sessionId, [
        Message(role: MessageRole.user, content: 'bye'),
      ]);

      // Just check if it runs without error for now as it mostly logs
      await curator.collectStats();

      // We check if sessions are actually in DB via sessionManager
      final allSessions = sessionManager.getAllSessions();
      expect(allSessions.length, equals(2));
    });
  });
}
