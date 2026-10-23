// Shared fixture for the Task 139 schedule protocol suites.
//
// Every value is hermetic: a temporary Sanad Home, a standalone agent-state
// database, a real `CronScheduler` (the only writer), and a fake `AuthManager`
// for the canonical envelope. Nothing here reaches the network, the user's Home,
// or a live daemon.

import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/schedule_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/schedule_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

class _FakeAuthManager implements AuthManager {
  @override
  String? get hardwareId => 'test-device-id';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One hermetic schedule-protocol runtime: handlers wired over a real scheduler.
class ScheduleProtocolHarness {
  ScheduleProtocolHarness._({
    required this.root,
    required this.sessionManager,
    required this.scheduler,
    required this.bridge,
    required this.broadcasts,
  });

  final Directory root;
  final SessionManager sessionManager;
  final CronScheduler scheduler;
  final SanadProtocolBridge bridge;

  /// Every `schedule.changed` / notice event a handler published to the family.
  final List<CanonicalEvent> broadcasts;

  late final ScheduleCommandHandler commands = ScheduleCommandHandler(
    scheduler: scheduler,
    sessionManager: sessionManager,
    bridge: bridge,
    broadcastFamilyEvent: broadcasts.add,
  );

  late final ScheduleQueryHandler queries = ScheduleQueryHandler(
    scheduler: scheduler,
    sessionManager: sessionManager,
    bridge: bridge,
  );

  static Future<ScheduleProtocolHarness> start() async {
    final root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-schedule-protocol-')
          .resolveSymbolicLinksSync(),
    );
    setSanadHomeOverride(root.path);
    setSanadStateHomeOverride(root.path);

    final getIt = GetIt.instance;
    await getIt.reset();
    getIt.registerSingleton<AuthManager>(_FakeAuthManager());

    final sessionManager = SessionManager();
    final scheduler = CronScheduler(sessionManager: sessionManager);
    return ScheduleProtocolHarness._(
      root: root,
      sessionManager: sessionManager,
      scheduler: scheduler,
      bridge: SanadProtocolBridge(),
      broadcasts: [],
    );
  }

  Future<void> dispose() async {
    await scheduler.dispose();
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    await GetIt.instance.reset();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  }

  /// A canonical command event with the transport-stamped authority.
  CanonicalEvent event(
    String type,
    Map<String, dynamic> payload, {
    CommandAuthority authority = CommandAuthority.owner,
    String? requestId = 'req-1',
  }) {
    return CanonicalEvent(
      type: type,
      payload: {
        'request_id': ?requestId,
        CommandAuthority.payloadKey: authority.value,
        ...payload,
      },
    );
  }

  /// Dispatches one event through the owning handler's `handle()` entry point.
  Future<Map<String, dynamic>> send(CanonicalEvent event) async {
    Map<String, dynamic>? envelope;
    Future<void> emit(Map<String, dynamic> value) async {
      envelope = value;
    }

    switch (event.type) {
      case CanonicalEventTypes.scheduleCreate:
      case CanonicalEventTypes.scheduleUpdate:
      case CanonicalEventTypes.schedulePause:
      case CanonicalEventTypes.scheduleResume:
      case CanonicalEventTypes.scheduleRunNow:
      case CanonicalEventTypes.scheduleDelete:
        await commands.handle(event, emit);
      case CanonicalEventTypes.scheduleList:
      case CanonicalEventTypes.schedulePreview:
      case CanonicalEventTypes.scheduleRuns:
        await queries.handle(event, emit);
      default:
        fail('No schedule handler owns ${event.type}');
    }
    return envelope!;
  }

  /// The payload of a canonical envelope.
  Map<String, dynamic> payloadOf(Map<String, dynamic> envelope) =>
      Map<String, dynamic>.from(envelope['payload'] as Map);

  /// The protocol error code of an error envelope, or null.
  String? codeOf(Map<String, dynamic> envelope) {
    if (envelope['event'] != 'error') return null;
    return payloadOf(envelope)['code'] as String?;
  }

  /// Counts the schedules currently stored on the device.
  int get storedScheduleCount => scheduler.listSchedules().length;

  /// Seeds a model-owned schedule whose owning conversation need not exist.
  ///
  /// Tests use it to reach the orphaned state (`session_id` names a conversation
  /// that was deleted) without exercising the delete path.
  ScheduledTaskRecord seedModelSchedule({
    required String id,
    required String sessionId,
    String task = 'Model-owned schedule',
    String? name,
    ScheduleConversationMode conversationMode =
        ScheduleConversationMode.continuous,
  }) {
    final now = DateTime.now().toUtc();
    sessionManager.db.saveScheduledTask(
      id,
      task,
      now.add(const Duration(hours: 1)),
      sessionId,
      kind: ScheduleKind.daily.name,
      atTime: '09:00',
      zone: 'Z',
      updatedAt: now,
      name: name,
      ownerKind: ScheduleOwnerKind.model.wireName,
      conversationMode: conversationMode.wireName,
      runSessionId: sessionId,
    );
    return scheduler.getSchedule(id)!;
  }

  /// Seeds a terminal run row through the recorder (the only run writer).
  String seedRun({
    required String scheduleId,
    required ScheduledTaskRunStatus status,
    ScheduledTaskRunTrigger trigger = ScheduledTaskRunTrigger.scheduled,
    DateTime? runAt,
    String? sessionId,
    String? messageId,
    String? error,
  }) {
    final recorder = scheduler.runRecorder;
    final runId = recorder.startRun(
      scheduleId: scheduleId,
      runAt: runAt ?? DateTime.now().toUtc(),
      trigger: trigger,
    );
    if (sessionId != null && messageId != null) {
      recorder.attachUserMessage(
        runId,
        sessionId: sessionId,
        messageId: messageId,
      );
    }
    if (status.isTerminal) {
      recorder.completeRun(runId, status: status, error: error);
    }
    return runId;
  }
}
