import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_preview.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';

/// A scripted [SchedulesClient]: it records the calls it receives, can hold a
/// call open to exercise single-flight admission, and can fail like the real
/// client.
class _FakeSchedulesClient implements SchedulesClient {
  final listCalls = <DeviceConfig>[];
  final createCalls = <ScheduleDraft>[];
  final updateCalls = <ScheduleUpdate>[];
  final pauseCalls = <String>[];
  final resumeCalls = <String>[];
  final runNowCalls = <String>[];
  final deleteCalls = <String>[];
  final runsCalls = <({String scheduleId, int? limit, String? cursor})>[];
  final previewCalls = <ScheduleDefinitionInput>[];

  final changesController = StreamController<void>.broadcast();
  final runFailuresController = StreamController<ScheduleRunFailureNotice>.broadcast();

  List<Schedule> schedules = const [];
  List<ScheduleRun> runRows = const [];
  bool hasMoreRuns = false;
  String? nextCursor;

  ScheduleException? listError;
  ScheduleException? runsError;
  ScheduleException? actionError;
  ScheduleException? previewError;
  SchedulePreview previewResult = const SchedulePreview(
    valid: true,
    nextRunAt: null,
    zone: '+03:00',
  );

  Completer<void>? listGate;
  Completer<void>? actionGate;
  Completer<void>? runsGate;
  Completer<void>? previewGate;

  @override
  Future<SchedulesSnapshot> list(DeviceConfig device) async {
    listCalls.add(device);
    await listGate?.future;
    final error = listError;
    if (error != null) throw error;
    return SchedulesSnapshot(schedules: schedules);
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
    await actionGate?.future;
    final error = actionError;
    if (error != null) throw error;
    return _schedule(id: 'task_created');
  }

  @override
  Future<Schedule> update(DeviceConfig device, ScheduleUpdate update) async {
    updateCalls.add(update);
    await actionGate?.future;
    final error = actionError;
    if (error != null) throw error;
    return _schedule(id: update.id);
  }

  @override
  Future<Schedule> pause(DeviceConfig device, String scheduleId) async {
    pauseCalls.add(scheduleId);
    await actionGate?.future;
    final error = actionError;
    if (error != null) throw error;
    return _schedule(id: scheduleId, enabled: false);
  }

  @override
  Future<Schedule> resume(DeviceConfig device, String scheduleId) async {
    resumeCalls.add(scheduleId);
    await actionGate?.future;
    final error = actionError;
    if (error != null) throw error;
    return _schedule(id: scheduleId, enabled: true);
  }

  @override
  Future<ScheduleRunAcceptance> runNow(DeviceConfig device, String scheduleId) async {
    runNowCalls.add(scheduleId);
    await actionGate?.future;
    final error = actionError;
    if (error != null) throw error;
    return ScheduleRunAcceptance(
      scheduleId: scheduleId,
      runId: 'run_manual',
      sessionId: 'sess_2',
      acceptedAt: DateTime.utc(2026, 10, 23, 9),
    );
  }

  @override
  Future<void> delete(DeviceConfig device, String scheduleId) async {
    deleteCalls.add(scheduleId);
    await actionGate?.future;
    final error = actionError;
    if (error != null) throw error;
  }

  @override
  Future<ScheduleRunsPage> runs(
    DeviceConfig device, {
    required String scheduleId,
    int? limit,
    String? cursor,
  }) async {
    runsCalls.add((scheduleId: scheduleId, limit: limit, cursor: cursor));
    await runsGate?.future;
    final error = runsError;
    if (error != null) throw error;
    return ScheduleRunsPage(
      scheduleId: scheduleId,
      runs: runRows,
      hasMore: hasMoreRuns,
      nextCursor: hasMoreRuns ? (nextCursor ?? 'cursor-${runsCalls.length}') : null,
    );
  }

  @override
  Stream<void> changes(DeviceConfig device) => changesController.stream;

  @override
  Stream<ScheduleRunFailureNotice> runFailures(DeviceConfig device) => runFailuresController.stream;
}

Schedule _schedule({
  String id = 'task_1',
  String? name = 'Morning brief',
  bool enabled = true,
  ScheduleOwnerKind ownerKind = ScheduleOwnerKind.user,
  String? ownerSessionId = 'sess_1',
  int consecutiveFailures = 0,
}) => Schedule(
  id: id,
  name: name,
  task: 'Summarise the open items in this workspace.',
  kind: ScheduleKind.daily,
  atTime: '09:00',
  zone: '+03:00',
  nextRunAt: DateTime.utc(2026, 10, 24, 6),
  enabled: enabled,
  ownerKind: ownerKind,
  ownerSessionId: ownerSessionId,
  ownerSessionTitle: ownerSessionId == null ? null : 'Morning brief runs',
  conversationMode: ScheduleConversationMode.continuous,
  consecutiveFailures: consecutiveFailures,
  createdAt: DateTime.utc(2026, 10, 23, 8, 12),
  updatedAt: DateTime.utc(2026, 10, 23, 8, 12),
);

ScheduleRun _run(String id, {ScheduleRunStatus status = ScheduleRunStatus.succeeded}) => ScheduleRun(
  id: id,
  runAt: DateTime.utc(2026, 10, 23, 9),
  status: status,
  trigger: ScheduleRunTrigger.scheduled,
  durationMs: status == ScheduleRunStatus.running ? null : 41230,
  sessionId: 'sess_1',
  messageId: 'msg_$id',
  hasPosition: true,
);

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeSchedulesClient client;
  late DeviceConfig device;

  SchedulesCubit buildCubit() => SchedulesCubit(client: client, device: () => device);

  setUp(() {
    client = _FakeSchedulesClient();
    device = DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: true);
  });

  group('load', () {
    test('issues nothing until load is called, then admits one read and emits loaded', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);

      expect(cubit.state.status, SchedulesStatus.initial);
      expect(client.listCalls, isEmpty);

      final loading = cubit.load();
      expect(cubit.state.status, SchedulesStatus.loading);
      await loading;

      expect(client.listCalls, hasLength(1));
      expect(cubit.state.status, SchedulesStatus.loaded);
      expect(cubit.state.schedules.single.id, 'task_1');
      expect(cubit.state.showsList, isTrue);
    });

    test('an empty device reports empty rather than an empty loaded list', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.status, SchedulesStatus.empty);
      expect(cubit.state.isEmpty, isTrue);
      expect(cubit.state.showsList, isFalse);
    });

    test('coalesces a burst of loads into the running read and one follow-up', () async {
      client.schedules = [_schedule()];
      final gate = Completer<void>();
      client.listGate = gate;
      final cubit = buildCubit();
      addTearDown(cubit.close);

      final first = cubit.load();
      final second = cubit.load();
      client.listGate = null;
      gate.complete();
      await first;
      await second;
      await _settle();

      expect(client.listCalls, hasLength(2));
      expect(cubit.state.status, SchedulesStatus.loaded);
    });

    test('a refresh over a loaded list keeps the rows visible and reports refreshing', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      final gate = Completer<void>();
      client.listGate = gate;
      final refresh = cubit.load();
      expect(cubit.state.status, SchedulesStatus.loaded);
      expect(cubit.state.refreshing, isTrue);
      expect(cubit.state.showsList, isTrue);

      gate.complete();
      await refresh;
      expect(cubit.state.refreshing, isFalse);
    });
  });

  group('device availability', () {
    test('an offline device short-circuits before any request and shows unavailable', () async {
      device = DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: false);
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);

      await cubit.load();
      final outcome = await cubit.pause('task_1');

      expect(client.listCalls, isEmpty);
      expect(client.pauseCalls, isEmpty);
      expect(cubit.state.status, SchedulesStatus.deviceUnavailable);
      expect(cubit.state.schedules, isEmpty);
      expect(outcome, ScheduleActionOutcome.deviceUnavailable);
    });

    test('a device that is not in the inventory is unavailable, with no request', () async {
      device = DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: true);
      final cubit = SchedulesCubit(client: client, device: () => null);
      addTearDown(cubit.close);

      await cubit.load();

      expect(client.listCalls, isEmpty);
      expect(cubit.state.status, SchedulesStatus.deviceUnavailable);
    });

    test('a socket drop mid-action yields unavailable and no stale list', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.showsList, isTrue);

      client.actionError = const ScheduleException(ScheduleErrorCode.deviceUnavailable, scheduleId: 'task_1');
      final outcome = await cubit.pause('task_1');

      expect(outcome, ScheduleActionOutcome.deviceUnavailable);
      expect(cubit.state.status, SchedulesStatus.deviceUnavailable);
      expect(cubit.state.schedules, isEmpty);
      expect(cubit.state.showsList, isFalse);
      expect(cubit.state.failure?.code, ScheduleErrorCode.deviceUnavailable);
    });

    test('a read that fails with deviceUnavailable clears the previous snapshot', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      client.listError = const ScheduleException(ScheduleErrorCode.deviceUnavailable);
      await cubit.load();

      expect(cubit.state.status, SchedulesStatus.deviceUnavailable);
      expect(cubit.state.schedules, isEmpty);
    });

    test('markDeviceUnavailable drops the snapshot without a request', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      cubit.markDeviceUnavailable();

      expect(cubit.state.status, SchedulesStatus.deviceUnavailable);
      expect(cubit.state.schedules, isEmpty);
      expect(client.listCalls, hasLength(1));
    });
  });

  group('errors', () {
    test('a typed read failure becomes an error state with no rows', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      client.listError = const ScheduleException(ScheduleErrorCode.permissionDenied);
      await cubit.load();

      expect(cubit.state.status, SchedulesStatus.error);
      expect(cubit.state.failure?.code, ScheduleErrorCode.permissionDenied);
      expect(cubit.state.schedules, isEmpty);
    });

    test('each protocol code maps to its typed action failure', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      const codes = {
        'invalid_request': ScheduleErrorCode.invalidRequest,
        'invalid_schedule': ScheduleErrorCode.invalidSchedule,
        'schedule_not_found': ScheduleErrorCode.scheduleNotFound,
        'schedule_expired': ScheduleErrorCode.scheduleExpired,
        'schedule_orphaned': ScheduleErrorCode.scheduleOrphaned,
        'permission_denied': ScheduleErrorCode.permissionDenied,
        'internal_error': ScheduleErrorCode.internalError,
      };

      for (final entry in codes.entries) {
        client.actionError = ScheduleException(
          ScheduleErrorCode.fromWireCode(entry.key),
          scheduleId: 'task_1',
        );
        final outcome = await cubit.resume('task_1');
        expect(outcome, ScheduleActionOutcome.failed, reason: entry.key);
        expect(cubit.state.failure?.code, entry.value, reason: entry.key);
        expect(cubit.state.failure?.scheduleId, 'task_1', reason: entry.key);
        expect(cubit.state.inFlightAction, isNull, reason: entry.key);
      }
    });

    test('an unexpected exception becomes an unknown failure, never Agent text', () async {
      final throwingCubit = SchedulesCubit(client: _ThrowingClient(), device: () => device);
      addTearDown(throwingCubit.close);
      await throwingCubit.load();

      final outcome = await throwingCubit.delete('task_1');

      expect(outcome, ScheduleActionOutcome.failed);
      expect(throwingCubit.state.failure?.code, ScheduleErrorCode.unknown);
      expect(throwingCubit.state.toString(), isNot(contains('boom')));
    });
  });

  group('single-flight', () {
    test('a second identical action while the first is in flight is rejected as busy', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      final gate = Completer<void>();
      client.actionGate = gate;
      final first = cubit.pause('task_1');
      await _settle();
      expect(cubit.state.isActionInFlight(ScheduleActionKind.pause, scheduleId: 'task_1'), isTrue);

      final second = await cubit.pause('task_1');
      expect(second, ScheduleActionOutcome.busy);
      expect(client.pauseCalls, hasLength(1));

      client.actionGate = null;
      gate.complete();
      expect(await first, ScheduleActionOutcome.success);
      expect(client.pauseCalls, hasLength(1));
      expect(cubit.state.inFlightAction, isNull);
    });

    test('a different action on another schedule is admitted', () async {
      client.schedules = [_schedule(), _schedule(id: 'task_2')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      final gate = Completer<void>();
      client.actionGate = gate;
      final first = cubit.pause('task_1');
      await _settle();
      final second = cubit.runNow('task_2');
      await _settle();
      expect(client.runNowCalls, ['task_2']);

      client.actionGate = null;
      gate.complete();
      await first;
      await second;
      expect(client.pauseCalls, ['task_1']);
      expect(cubit.state.lastAcceptedRun?.runId, 'run_manual');
    });
  });

  group('mutations', () {
    test('a successful mutation re-reads the authoritative list', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      expect(client.listCalls, hasLength(1));

      final outcome = await cubit.pause('task_1');

      expect(outcome, ScheduleActionOutcome.success);
      expect(client.pauseCalls, ['task_1']);
      expect(client.listCalls, hasLength(2));
    });

    test('delete closes the open detail of the deleted schedule', () async {
      client.schedules = [_schedule()];
      client.runRows = [_run('run_1')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.openDetail('task_1');
      expect(cubit.state.detail?.scheduleId, 'task_1');
      expect(cubit.state.detail?.runs, hasLength(1));

      client.schedules = const [];
      await cubit.delete('task_1');

      expect(client.deleteCalls, ['task_1']);
      expect(cubit.state.detail, isNull);
    });
  });

  group('schedule.changed', () {
    test('triggers exactly one refresh of the list', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      expect(client.listCalls, hasLength(1));

      client.changesController.add(null);
      await _settle();

      expect(client.listCalls, hasLength(2));
      expect(cubit.state.showsList, isTrue);
    });

    test('refreshes the open detail and its run page, and the payload is never projected', () async {
      client.schedules = [_schedule()];
      client.runRows = [_run('run_1')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.openDetail('task_1');
      expect(client.listCalls, hasLength(1));
      expect(client.runsCalls, hasLength(1));

      client.runRows = [_run('run_1'), _run('run_2')];
      client.changesController.add(null);
      await _settle();

      expect(client.listCalls, hasLength(2));
      expect(client.runsCalls, hasLength(2));
      expect(cubit.state.detail?.runs, hasLength(2));
    });
  });

  group('schedule.run_failed', () {
    test('is forwarded as a typed notice, is never stored, and re-reads the list once', () async {
      client.schedules = [_schedule()];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      final seen = <ScheduleRunFailureNotice>[];
      final subscription = cubit.runFailures.listen(seen.add);
      addTearDown(subscription.cancel);

      client.runFailuresController.add(
        const ScheduleRunFailureNotice(
          scheduleId: 'task_1',
          runId: 'run_3',
          scheduleName: 'Morning brief',
          sessionId: 'sess_1',
          consecutiveFailures: 3,
          suggestPause: true,
        ),
      );
      await _settle();

      expect(seen, hasLength(1));
      expect(seen.single.suggestPause, isTrue);
      expect(cubit.state.toString(), isNot(contains('run_3')));
      // A failed run broadcasts no `schedule.changed`, so the notice is the
      // freshness signal: it asks the Agent for the authoritative list (Task 139
      // F5) without projecting any of its own payload.
      expect(client.listCalls, hasLength(2));
    });

    test('re-reads the open run page only for the schedule it names', () async {
      client.schedules = [_schedule()];
      client.runRows = [_run('run_1')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.openDetail('task_1');
      expect(client.runsCalls, hasLength(1));

      client.runFailuresController.add(
        const ScheduleRunFailureNotice(scheduleId: 'task_9', runId: 'run_9'),
      );
      await _settle();

      expect(client.listCalls, hasLength(2), reason: 'the list is always re-read');
      expect(client.runsCalls, hasLength(1), reason: 'another schedule is not on screen');

      client.runFailuresController.add(
        const ScheduleRunFailureNotice(scheduleId: 'task_1', runId: 'run_2'),
      );
      await _settle();

      expect(client.listCalls, hasLength(3));
      expect(client.runsCalls, hasLength(2), reason: 'the open schedule gained a terminal row');
    });
  });

  group('detail and run history', () {
    test('openDetail reads the first page and loadMoreRuns passes the cursor through', () async {
      client.schedules = [_schedule()];
      client.runRows = [_run('run_1')];
      client.hasMoreRuns = true;
      client.nextCursor = 'cursor_next';
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.openDetail('task_1');

      expect(client.runsCalls.single, (scheduleId: 'task_1', limit: null, cursor: null));
      expect(cubit.state.detail?.hasMoreRuns, isTrue);
      expect(cubit.state.detail?.nextCursor, 'cursor_next');
      expect(cubit.state.detail?.canLoadMoreRuns, isTrue);
      expect(cubit.state.scheduleById('task_1')?.id, 'task_1');
      expect(cubit.state.detail?.schedule?.id, 'task_1');

      client.runRows = [_run('run_2')];
      client.hasMoreRuns = false;
      client.nextCursor = null;
      await cubit.loadMoreRuns();

      expect(client.runsCalls.last, (scheduleId: 'task_1', limit: null, cursor: 'cursor_next'));
      expect(cubit.state.detail?.runs.map((run) => run.id), ['run_1', 'run_2']);
      expect(cubit.state.detail?.hasMoreRuns, isFalse);
      expect(cubit.state.detail?.nextCursor, isNull);
      expect(cubit.state.detail?.canLoadMoreRuns, isFalse);
    });

    test('loadMoreRuns issues nothing when the Agent reported no further page', () async {
      client.schedules = [_schedule()];
      client.runRows = [_run('run_1')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.openDetail('task_1');

      await cubit.loadMoreRuns();

      expect(client.runsCalls, hasLength(1));
    });

    test('a runs refusal becomes a typed detail failure and keeps no partial page', () async {
      client.schedules = [_schedule()];
      client.runRows = [_run('run_1')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      client.runsError = const ScheduleException(ScheduleErrorCode.scheduleNotFound, scheduleId: 'task_1');
      await cubit.openDetail('task_1');

      expect(cubit.state.detail?.failure?.code, ScheduleErrorCode.scheduleNotFound);
      expect(cubit.state.detail?.runs, isEmpty);
      expect(cubit.state.detail?.loadingRuns, isFalse);
    });

    test('a closed detail cannot be written by a late run page', () async {
      client.schedules = [_schedule()];
      client.runRows = [_run('run_1')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();

      final gate = Completer<void>();
      client.runsGate = gate;
      final opening = cubit.openDetail('task_1');
      await _settle();
      cubit.closeDetail();
      client.runsGate = null;
      gate.complete();
      await opening;

      expect(cubit.state.detail, isNull);
    });
  });

  group('conversation marker set', () {
    test('derives owner conversation ids from the same list snapshot', () async {
      client.schedules = [
        _schedule(id: 'task_1', ownerSessionId: 'sess_1'),
        _schedule(id: 'task_2', ownerSessionId: 'sess_1'),
        _schedule(id: 'task_3', ownerSessionId: 'sess_2'),
        _schedule(id: 'task_4', ownerSessionId: null),
      ];
      final cubit = buildCubit();
      addTearDown(cubit.close);

      expect(cubit.state.conversationIdsWithSchedules, isEmpty);
      await cubit.load();

      expect(cubit.state.conversationIdsWithSchedules, {'sess_1', 'sess_2'});
      expect(client.listCalls, hasLength(1));
    });

    test('the set is empty whenever the list is not current', () async {
      client.schedules = [_schedule(id: 'task_1', ownerSessionId: 'sess_1')];
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.conversationIdsWithSchedules, {'sess_1'});

      cubit.markDeviceUnavailable();
      expect(cubit.state.conversationIdsWithSchedules, isEmpty);
    });
  });

  group('preview', () {
    test('emits the Agent answer and drops a superseded candidate', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      final firstGate = Completer<void>();
      client.previewGate = firstGate;
      final first = cubit.preview(const ScheduleDefinitionInput(kind: ScheduleKind.daily, atTime: '09:00'));
      await _settle();

      client.previewResult = const SchedulePreview(valid: true, zone: '+03:00');
      client.previewGate = null;
      final second = cubit.preview(const ScheduleDefinitionInput(kind: ScheduleKind.daily, atTime: '10:00'));
      await second;
      expect(cubit.state.preview?.valid, isTrue);

      client.previewResult = const SchedulePreview(valid: false, errorCode: ScheduleErrorCode.invalidSchedule);
      firstGate.complete();
      await first;

      expect(client.previewCalls, hasLength(2));
      expect(cubit.state.preview?.valid, isTrue, reason: 'the superseded answer must not land');
      expect(cubit.state.previewInFlight, isFalse);
    });

    test('a malformed preview is a typed preview failure and clears the old answer', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);
      await cubit.preview(const ScheduleDefinitionInput(kind: ScheduleKind.daily, atTime: '09:00'));
      expect(cubit.state.preview, isNotNull);

      client.previewError = const ScheduleException(ScheduleErrorCode.invalidRequest);
      await cubit.preview(const ScheduleDefinitionInput(kind: ScheduleKind.daily, atTime: '99:99'));

      expect(cubit.state.preview, isNull);
      expect(cubit.state.previewFailure?.code, ScheduleErrorCode.invalidRequest);
    });

    test('clearPreview drops the answer and an in-flight candidate cannot land', () async {
      final cubit = buildCubit();
      addTearDown(cubit.close);

      final gate = Completer<void>();
      client.previewGate = gate;
      final pending = cubit.preview(const ScheduleDefinitionInput(kind: ScheduleKind.daily, atTime: '09:00'));
      await _settle();
      cubit.clearPreview();
      client.previewGate = null;
      gate.complete();
      await pending;

      expect(cubit.state.preview, isNull);
      expect(cubit.state.previewInFlight, isFalse);
    });

    test('an offline device answers unavailable and issues no preview request', () async {
      device = DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: false);
      final cubit = buildCubit();
      addTearDown(cubit.close);

      await cubit.preview(const ScheduleDefinitionInput(kind: ScheduleKind.daily, atTime: '09:00'));

      expect(client.previewCalls, isEmpty);
      expect(cubit.state.status, SchedulesStatus.deviceUnavailable);
    });
  });

  group('domain helpers used by the surface', () {
    test('an orphaned model row cannot be resumed or run', () {
      final orphaned = _schedule(ownerKind: ScheduleOwnerKind.model, ownerSessionId: null);
      expect(orphaned.isOrphaned, isTrue);
      expect(orphaned.canResume, isFalse);
      expect(orphaned.canRunNow, isFalse);

      final paused = _schedule(enabled: false);
      expect(paused.canResume, isTrue);
      expect(paused.canRunNow, isTrue, reason: 'Run now stays available on a paused row (S21)');
    });

    test('the pause suggestion starts at the third consecutive failure', () {
      expect(_schedule(consecutiveFailures: 2).suggestsPause, isFalse);
      expect(_schedule(consecutiveFailures: 3).suggestsPause, isTrue);
    });
  });
}

/// A client whose every call throws an untyped error.
class _ThrowingClient extends _FakeSchedulesClient {
  @override
  Future<SchedulesSnapshot> list(DeviceConfig device) async => SchedulesSnapshot(schedules: [_schedule()]);

  @override
  Future<void> delete(DeviceConfig device, String scheduleId) async => throw StateError('boom');
}
