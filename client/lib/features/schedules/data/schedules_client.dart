import 'dart:async';

import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_preview.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';

/// Client data boundary for the device-owner schedule protocol (Task 139 C6).
///
/// It speaks only the commands and queries of
/// `docs/technical/schedule_control_protocol.md` through the shared
/// [DeviceCommandClient], so a loopback client, a cloud-relayed client, and a
/// web or mobile client run the same code path; no screen selects a transport.
///
/// The wire shapes it owns are closed:
/// - one method per command and query, each naming its own expected event;
/// - the payloads carry only documented fields, so `owner_kind` can never be
///   sent and the Agent's unknown-field gate can never see a Client invention;
/// - `delete` always sends `confirm: true` (the user-facing confirmation is the
///   screen's job);
/// - `runs` passes `limit` and the opaque `cursor` through and never parses the
///   cursor;
/// - a protocol `code` becomes a typed [ScheduleErrorCode] and the Agent's
///   `message` is dropped, so no refusal can reach the UI as server text.
class SchedulesClient {
  SchedulesClient(this._commands);

  final DeviceCommandClient _commands;

  static const String listCommand = 'schedule.list';
  static const String listResultEvent = 'schedule.list_result';
  static const String previewCommand = 'schedule.preview';
  static const String previewResultEvent = 'schedule.preview_result';
  static const String createCommand = 'schedule.create';
  static const String createdEvent = 'schedule.created';
  static const String updateCommand = 'schedule.update';
  static const String updatedEvent = 'schedule.updated';
  static const String pauseCommand = 'schedule.pause';
  static const String resumeCommand = 'schedule.resume';
  static const String runNowCommand = 'schedule.run_now';
  static const String runAcceptedEvent = 'schedule.run_accepted';
  static const String deleteCommand = 'schedule.delete';
  static const String deletedEvent = 'schedule.deleted';
  static const String runsCommand = 'schedule.runs';
  static const String runsResultEvent = 'schedule.runs_result';
  static const String changedEvent = 'schedule.changed';
  static const String runFailedEvent = 'schedule.run_failed';

  /// Every schedule on [device] (`schedule.list`).
  Future<SchedulesSnapshot> list(DeviceConfig device) async {
    final payload = await _request(
      device,
      command: listCommand,
      expectedEvent: listResultEvent,
    );
    return SchedulesSnapshot.fromJson(payload);
  }

  /// The Agent's own answer for a candidate definition (`schedule.preview`).
  ///
  /// An invalid definition is a successful answer carrying `valid: false`; only
  /// a malformed request throws.
  Future<SchedulePreview> preview(DeviceConfig device, ScheduleDefinitionInput definition) async {
    final payload = await _request(
      device,
      command: previewCommand,
      expectedEvent: previewResultEvent,
      payload: definition.toWirePayload(),
    );
    return SchedulePreview.fromJson(payload);
  }

  /// Creates a device-owned schedule (`schedule.create`).
  Future<Schedule> create(DeviceConfig device, ScheduleDraft draft) async {
    final payload = await _request(
      device,
      command: createCommand,
      expectedEvent: createdEvent,
      payload: draft.toCreatePayload(),
    );
    return _row(payload, scheduleId: null);
  }

  /// Applies [update] to its schedule (`schedule.update`).
  Future<Schedule> update(DeviceConfig device, ScheduleUpdate update) async {
    final payload = await _request(
      device,
      command: updateCommand,
      expectedEvent: updatedEvent,
      scheduleId: update.id,
      payload: update.toUpdatePayload(),
    );
    return _row(payload, scheduleId: update.id);
  }

  /// Pauses a schedule without losing its next instant (`schedule.pause`).
  Future<Schedule> pause(DeviceConfig device, String scheduleId) =>
      _updatedRow(device, command: pauseCommand, scheduleId: scheduleId);

  /// Resumes a schedule and re-arms it (`schedule.resume`).
  Future<Schedule> resume(DeviceConfig device, String scheduleId) =>
      _updatedRow(device, command: resumeCommand, scheduleId: scheduleId);

  /// Dispatches a run now, including on a paused schedule (`schedule.run_now`).
  ///
  /// The schedule keeps its `next_run_at`, `last_run_at`, `last_status`, and
  /// `enabled`: this is a manual override, not a resume (S14, S21).
  Future<ScheduleRunAcceptance> runNow(DeviceConfig device, String scheduleId) async {
    final payload = await _request(
      device,
      command: runNowCommand,
      expectedEvent: runAcceptedEvent,
      scheduleId: scheduleId,
      payload: {'id': scheduleId},
    );
    return ScheduleRunAcceptance.fromJson(payload, scheduleId: scheduleId);
  }

  /// Deletes a schedule and its run rows (`schedule.delete`).
  ///
  /// Always sends `confirm: true`; the user-facing confirmation belongs to the
  /// screen that calls this method. A response that does not report the deletion
  /// is treated as a protocol violation rather than as a silent success.
  Future<void> delete(DeviceConfig device, String scheduleId) async {
    final payload = await _request(
      device,
      command: deleteCommand,
      expectedEvent: deletedEvent,
      scheduleId: scheduleId,
      payload: {'id': scheduleId, 'confirm': true},
    );
    if (payload['deleted'] != true) {
      throw ScheduleException(ScheduleErrorCode.unknown, scheduleId: scheduleId, wireCode: 'deleted_absent');
    }
  }

  /// One bounded page of a schedule's run history (`schedule.runs`).
  ///
  /// [limit] and [cursor] travel unchanged. The cursor is opaque: it is minted
  /// by the Agent, bound to this schedule, and never parsed here.
  Future<ScheduleRunsPage> runs(
    DeviceConfig device, {
    required String scheduleId,
    int? limit,
    String? cursor,
  }) async {
    final cursorValue = cursor?.trim();
    final payload = await _request(
      device,
      command: runsCommand,
      expectedEvent: runsResultEvent,
      scheduleId: scheduleId,
      payload: {
        'schedule_id': scheduleId,
        if (limit != null) 'limit': limit,
        if (cursorValue != null && cursorValue.isNotEmpty) 'cursor': cursorValue,
      },
    );
    return ScheduleRunsPage.fromJson(payload, scheduleId: scheduleId);
  }

  /// Mutations of any schedule on [device], made by this or another client
  /// (`schedule.changed`).
  ///
  /// The payload is not projected at all: it announces that an authoritative
  /// snapshot moved, and the owning cubit re-reads instead of trusting the event
  /// as data.
  Stream<void> changes(DeviceConfig device) => _commands
      .events(device)
      .where((event) => event['event'] == changedEvent)
      .map<void>((_) {});

  /// Failed runs on [device] (`schedule.run_failed`), as a typed notice for the
  /// Client's own failure surface.
  ///
  /// The notice is live and carries no error text (protocol §6); a payload
  /// without the identity keys is skipped rather than surfaced half-formed.
  Stream<ScheduleRunFailureNotice> runFailures(DeviceConfig device) => _commands.events(device).where((event) {
    return event['event'] == runFailedEvent;
  }).map((event) {
    final payload = Map<String, dynamic>.from(event['payload'] as Map? ?? const {});
    return ScheduleRunFailureNotice.fromJson(payload);
  }).where((notice) => notice.scheduleId.isNotEmpty && notice.runId.isNotEmpty);

  Future<Schedule> _updatedRow(
    DeviceConfig device, {
    required String command,
    required String scheduleId,
  }) async {
    final payload = await _request(
      device,
      command: command,
      expectedEvent: updatedEvent,
      scheduleId: scheduleId,
      payload: {'id': scheduleId},
    );
    return _row(payload, scheduleId: scheduleId);
  }

  /// The `schedule` object of a single-row response.
  Schedule _row(Map<String, dynamic> payload, {required String? scheduleId}) {
    final row = payload['schedule'];
    if (row is! Map) {
      throw ScheduleException(ScheduleErrorCode.unknown, scheduleId: scheduleId, wireCode: 'schedule_absent');
    }
    final schedule = Schedule.fromJson(Map<String, dynamic>.from(row));
    if (schedule.id.isEmpty) {
      throw ScheduleException(ScheduleErrorCode.unknown, scheduleId: scheduleId, wireCode: 'schedule_id_absent');
    }
    return schedule;
  }

  Future<Map<String, dynamic>> _request(
    DeviceConfig device, {
    required String command,
    required String expectedEvent,
    String? scheduleId,
    Map<String, dynamic> payload = const {},
  }) async {
    try {
      return await _commands.request(
        device: device,
        command: command,
        expectedEvent: expectedEvent,
        payload: payload,
      );
    } on DeviceCommandException catch (error) {
      final code = ScheduleErrorCode.fromWireCode(error.code);
      throw ScheduleException(
        code,
        scheduleId: scheduleId,
        wireCode: code == ScheduleErrorCode.unknown ? error.code : null,
      );
    } on ScheduleException {
      rethrow;
    } on TimeoutException {
      throw ScheduleException(ScheduleErrorCode.deviceUnavailable, scheduleId: scheduleId);
    } on StateError {
      // The shared command client reports "not connected" and a command timeout
      // as StateError; neither ever becomes UI copy.
      throw ScheduleException(ScheduleErrorCode.deviceUnavailable, scheduleId: scheduleId);
    } catch (_) {
      throw ScheduleException(ScheduleErrorCode.deviceUnavailable, scheduleId: scheduleId);
    }
  }
}
