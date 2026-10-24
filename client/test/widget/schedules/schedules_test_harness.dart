import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_preview.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../helpers/fake_conversation_repository.dart';
import '../../helpers/fake_device_repository.dart';
import '../../helpers/pump_app.dart';

/// A scripted [SchedulesClient] for the Schedules widget suites (Task 139 C1–C4).
///
/// It records every call the surfaces make, answers from mutable fixtures, and
/// can gate a read so a test can observe the loading presentation. No test
/// reaches a socket.
class FakeSchedulesClient implements SchedulesClient {
  List<Schedule> schedules = <Schedule>[];
  Map<String, List<ScheduleRun>> runsBySchedule = <String, List<ScheduleRun>>{};
  SchedulePreview previewResult = const SchedulePreview(valid: true);
  ScheduleException? listError;
  ScheduleException? previewError;
  ScheduleException? actionError;

  Completer<void>? listGate;
  Completer<void>? previewGate;

  final List<String> listCalls = <String>[];
  final List<String> runsCalls = <String>[];
  final List<String?> runsCursors = <String?>[];
  final List<ScheduleDefinitionInput> previewCalls = <ScheduleDefinitionInput>[];
  final List<ScheduleDraft> createCalls = <ScheduleDraft>[];
  final List<ScheduleUpdate> updateCalls = <ScheduleUpdate>[];
  final List<String> pauseCalls = <String>[];
  final List<String> resumeCalls = <String>[];
  final List<String> runNowCalls = <String>[];
  final List<String> deleteCalls = <String>[];

  final StreamController<void> changesController = StreamController<void>.broadcast();
  final StreamController<ScheduleRunFailureNotice> failuresController =
      StreamController<ScheduleRunFailureNotice>.broadcast();

  /// The bounded page a `schedule.runs` answer carries; a test that wants a
  /// second page sets [nextRunCursor].
  String? nextRunCursor;
  bool hasMoreRuns = false;

  /// The rows a cursor page carries; the first page is [runsBySchedule].
  List<ScheduleRun> nextPageRuns = <ScheduleRun>[];

  @override
  Future<SchedulesSnapshot> list(DeviceConfig device) async {
    listCalls.add(device.id);
    await listGate?.future;
    final error = listError;
    if (error != null) throw error;
    return SchedulesSnapshot(schedules: List<Schedule>.of(schedules));
  }

  @override
  Future<ScheduleRunsPage> runs(
    DeviceConfig device, {
    required String scheduleId,
    int? limit,
    String? cursor,
  }) async {
    runsCalls.add(scheduleId);
    runsCursors.add(cursor);
    final all = cursor == null
        ? runsBySchedule[scheduleId] ?? const <ScheduleRun>[]
        : nextPageRuns;
    return ScheduleRunsPage(
      scheduleId: scheduleId,
      runs: all,
      hasMore: hasMoreRuns,
      nextCursor: hasMoreRuns ? nextRunCursor ?? 'cursor-2' : null,
    );
  }

  @override
  Future<SchedulePreview> preview(DeviceConfig device, ScheduleDefinitionInput definition) async {
    previewCalls.add(definition);
    await previewGate?.future;
    final error = previewError;
    if (error != null) throw error;
    return previewResult;
  }

  @override
  Future<Schedule> create(DeviceConfig device, ScheduleDraft draft) async {
    createCalls.add(draft);
    final error = actionError;
    if (error != null) throw error;
    return scheduleFixture(id: 'task_created');
  }

  @override
  Future<Schedule> update(DeviceConfig device, ScheduleUpdate update) async {
    updateCalls.add(update);
    final error = actionError;
    if (error != null) throw error;
    return scheduleFixture(id: update.id);
  }

  @override
  Future<Schedule> pause(DeviceConfig device, String scheduleId) async {
    pauseCalls.add(scheduleId);
    final error = actionError;
    if (error != null) throw error;
    return scheduleFixture(id: scheduleId, enabled: false);
  }

  @override
  Future<Schedule> resume(DeviceConfig device, String scheduleId) async {
    resumeCalls.add(scheduleId);
    final error = actionError;
    if (error != null) throw error;
    return scheduleFixture(id: scheduleId, enabled: true);
  }

  @override
  Future<ScheduleRunAcceptance> runNow(DeviceConfig device, String scheduleId) async {
    runNowCalls.add(scheduleId);
    final error = actionError;
    if (error != null) throw error;
    return ScheduleRunAcceptance(scheduleId: scheduleId, runId: 'run_manual');
  }

  @override
  Future<void> delete(DeviceConfig device, String scheduleId) async {
    deleteCalls.add(scheduleId);
    final error = actionError;
    if (error != null) throw error;
  }

  @override
  Stream<void> changes(DeviceConfig device) => changesController.stream;

  @override
  Stream<ScheduleRunFailureNotice> runFailures(DeviceConfig device) => failuresController.stream;

  Future<void> dispose() async {
    await changesController.close();
    await failuresController.close();
  }
}

DeviceConfig deviceFixture({String id = 'device-1', bool isOnline = true, String name = 'Laptop'}) =>
    DeviceConfig(id: id, name: name, hardwareId: 'hw-$id', isOnline: isOnline);

/// One row of `schedule.list` shaped the way the Agent projects it.
Schedule scheduleFixture({
  String id = 'task_1',
  String? name = 'Morning brief',
  String task = 'Summarise the open items.',
  ScheduleKind kind = ScheduleKind.daily,
  String? atTime = '09:00',
  int? intervalMinutes,
  List<ScheduleWeekday> weekdays = const <ScheduleWeekday>[],
  int? monthDay,
  String zone = '+03:00',
  DateTime? nextRunAt,
  String? nextRunAtOffset,
  bool enabled = true,
  ScheduleOwnerKind ownerKind = ScheduleOwnerKind.user,
  String? ownerSessionId = 'session-1',
  String? ownerSessionTitle = 'Morning brief runs',
  ScheduleConversationMode conversationMode = ScheduleConversationMode.continuous,
  String? workspaceId,
  String? providerInstanceId = 'provider-1',
  String? model = 'gpt-4o',
  DateTime? lastRunAt,
  ScheduleLastOutcome? lastOutcome,
  int consecutiveFailures = 0,
}) => Schedule(
  id: id,
  name: name,
  task: task,
  kind: kind,
  intervalMinutes: intervalMinutes,
  atTime: atTime,
  weekdays: weekdays,
  monthDay: monthDay,
  zone: zone,
  nextRunAt: nextRunAt ?? DateTime.utc(2026, 10, 25, 6),
  nextRunAtOffset: nextRunAtOffset,
  enabled: enabled,
  ownerKind: ownerKind,
  ownerSessionId: ownerSessionId,
  ownerSessionTitle: ownerSessionTitle,
  conversationMode: conversationMode,
  workspaceId: workspaceId,
  providerInstanceId: providerInstanceId,
  model: model,
  lastRunAt: lastRunAt,
  lastOutcome: lastOutcome,
  consecutiveFailures: consecutiveFailures,
);

/// One row of `schedule.runs`.
ScheduleRun runFixture({
  String id = 'run_1',
  ScheduleRunStatus status = ScheduleRunStatus.succeeded,
  ScheduleRunTrigger trigger = ScheduleRunTrigger.scheduled,
  int? durationMs = 8400,
  String? error,
  String? sessionId = 'session-1',
  String? messageId = 'msg_1',
  bool hasPosition = true,
  DateTime? runAt,
}) => ScheduleRun(
  id: id,
  runAt: runAt ?? DateTime.utc(2026, 10, 24, 6),
  status: status,
  trigger: trigger,
  durationMs: durationMs,
  error: error,
  sessionId: sessionId,
  messageId: messageId,
  hasPosition: hasPosition,
);

Future<AppLocalizations> l10nFor(String locale) =>
    AppLocalizations.delegate.load(Locale(locale));

/// Registers the fixtures a Schedules surface resolves from DI.
class SchedulesTestEnvironment {
  SchedulesTestEnvironment({FakeSchedulesClient? client, List<DeviceConfig>? devices})
    : client = client ?? FakeSchedulesClient(),
      devices = devices ?? <DeviceConfig>[deviceFixture()];

  final FakeSchedulesClient client;
  final List<DeviceConfig> devices;
  final FakeDeviceRepository _deviceRepository = FakeDeviceRepository();
  final FakeConversationRepository conversationRepository = FakeConversationRepository();
  late final ConversationCacheRepository cacheRepository = ConversationCacheRepository(
    cache: ConversationCacheStore(),
    transport: conversationRepository,
  );

  Future<void> install() async {
    _deviceRepository.seedAgents(devices, activeAgentId: devices.first.id);
    getIt.registerSingleton<IDeviceRepository>(_deviceRepository);
    getIt.registerSingleton<SchedulesClient>(client);
  }

  /// Re-seats the device inventory, for a case that needs an offline device.
  void reseed(List<DeviceConfig> next) {
    devices
      ..clear()
      ..addAll(next);
    _deviceRepository.seedAgents(devices, activeAgentId: devices.first.id);
  }

  Future<void> dispose() async {
    if (getIt.isRegistered<IDeviceRepository>()) await getIt.unregister<IDeviceRepository>();
    if (getIt.isRegistered<SchedulesClient>()) await getIt.unregister<SchedulesClient>();
    await client.dispose();
  }
}

/// Pumps [child] with the app's localization delegates and the conversation
/// cache repository the editor and the run history read.
Future<void> pumpSchedulesSurface(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
  ConversationCacheRepository? cacheRepository,
  FakeConversationRepository? conversationRepository,
}) async {
  await pumpTestApp(
    tester,
    locale: locale,
    conversationCacheRepository: cacheRepository,
    conversationRepository: conversationRepository,
    child: child,
  );
  await tester.pumpAndSettle();
}
