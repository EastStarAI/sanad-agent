import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

import '../sanad_protocol_bridge.dart';
import 'support/agent_event_envelope.dart';
import 'support/schedule_projection.dart';
import 'support/schedule_request.dart';

/// A `schedule.runs` cursor that is malformed or belongs to another schedule.
///
/// A cursor binds the schedule it pages, so a cursor minted for one schedule is
/// never accepted for another (Task 139 §Protocol). Both conditions are
/// `invalid_request`: the request cannot address the page it asked for.
class ScheduleRunsCursorException implements Exception {
  final String message;
  const ScheduleRunsCursorException(this.message);

  @override
  String toString() => message;
}

/// Keyset cursor of one `schedule.runs` page.
///
/// The page order is `(run_at DESC, id DESC)`, so the cursor carries exactly the
/// last returned row's position plus the schedule it belongs to.
class ScheduleRunsCursor {
  static const int currentVersion = 1;

  final String scheduleId;
  final DateTime runAt;
  final String runId;

  const ScheduleRunsCursor({
    required this.scheduleId,
    required this.runAt,
    required this.runId,
  });

  String encode() {
    final bytes = utf8.encode(
      jsonEncode({
        'v': currentVersion,
        's': scheduleId,
        't': runAt.toUtc().toIso8601String(),
        'i': runId,
      }),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static ScheduleRunsCursor decode(String raw, {required String scheduleId}) {
    final normalized = raw.trim();
    if (normalized.isEmpty) {
      throw const ScheduleRunsCursorException(
        'The schedule runs cursor is empty.',
      );
    }
    try {
      final padding = '=' * ((4 - normalized.length % 4) % 4);
      final value = jsonDecode(
        utf8.decode(base64Url.decode('$normalized$padding')),
      );
      if (value is! Map) {
        throw const ScheduleRunsCursorException(
          'The schedule runs cursor is malformed.',
        );
      }
      final json = Map<String, dynamic>.from(value);
      final version = json['v'];
      final cursorScheduleId = json['s'];
      final runAt = json['t'];
      final runId = json['i'];
      if (version != currentVersion ||
          cursorScheduleId is! String ||
          cursorScheduleId.isEmpty ||
          runAt is! String ||
          runId is! String ||
          runId.isEmpty) {
        throw const ScheduleRunsCursorException(
          'The schedule runs cursor is malformed.',
        );
      }
      final parsedRunAt = DateTime.tryParse(runAt);
      if (parsedRunAt == null) {
        throw const ScheduleRunsCursorException(
          'The schedule runs cursor is malformed.',
        );
      }
      if (cursorScheduleId != scheduleId) {
        throw const ScheduleRunsCursorException(
          'The schedule runs cursor belongs to another schedule.',
        );
      }
      return ScheduleRunsCursor(
        scheduleId: cursorScheduleId,
        runAt: parsedRunAt.toUtc(),
        runId: runId,
      );
    } on ScheduleRunsCursorException {
      rethrow;
    } on Object {
      // A base64 or JSON decoder failure is the same malformed request; the
      // decoder's own message never reaches the envelope.
      throw const ScheduleRunsCursorException(
        'The schedule runs cursor is malformed.',
      );
    }
  }
}

/// Owns the read-only schedule queries of the device-owner protocol
/// (Task 139 §Protocol): `schedule.list`, `schedule.preview`, and
/// `schedule.runs`.
///
/// Every query is device-wide, because the human operating the device may see
/// any schedule (S15, 112a D6 read half), and every projection is closed: the
/// Client composes its own localized labels from structured fields, so no Agent
/// sentence becomes a UI string.
class ScheduleQueryHandler {
  ScheduleQueryHandler({
    required CronScheduler scheduler,
    required SessionManager sessionManager,
    String defaultZone = 'local',
    DateTime Function()? clock,
    SanadProtocolBridge? bridge,
  }) : _scheduler = scheduler,
       _sessionManager = sessionManager,
       _defaultZone = defaultZone,
       _clock = clock ?? DateTime.now,
       _bridge = bridge;

  final CronScheduler _scheduler;
  final SessionManager _sessionManager;
  final String _defaultZone;
  final DateTime Function() _clock;
  final SanadProtocolBridge? _bridge;

  static final Logger _logger = Logger('ScheduleQueryHandler');

  static const String listCommand = 'schedule.list';
  static const String previewCommand = 'schedule.preview';
  static const String runsCommand = 'schedule.runs';

  /// Dispatches a schedule query canonical event to its builder.
  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    switch (event.type) {
      case CanonicalEventTypes.scheduleList:
        await emitEnvelope(await buildListEnvelope(event));
        return;
      case CanonicalEventTypes.schedulePreview:
        await emitEnvelope(await buildPreviewEnvelope(event));
        return;
      case CanonicalEventTypes.scheduleRuns:
        await emitEnvelope(await buildRunsEnvelope(event));
        return;
      default:
        _logger.fine('Ignoring unsupported schedule query: ${event.type}');
        return;
    }
  }

  /// Lists every schedule on the device (`schedule.list` ->
  /// `schedule.list_result`).
  Future<Map<String, dynamic>> buildListEnvelope(CanonicalEvent event) async {
    final requestId = _requestIdOf(event);
    try {
      _admit(
        event,
        command: listCommand,
        allowed: {'request_id', CommandAuthority.payloadKey},
      );
      final records = [..._scheduler.listSchedules()]
        ..sort((left, right) {
          final byInstant = left.nextRunAt.compareTo(right.nextRunAt);
          return byInstant != 0 ? byInstant : left.id.compareTo(right.id);
        });
      final truncated = records.length > ScheduleWireLimits.maxListedSchedules;
      final listed = truncated
          ? records.take(ScheduleWireLimits.maxListedSchedules)
          : records;

      _logger.fine('Listing schedules; count=${records.length}.');

      return _buildEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.scheduleListResult,
          payload: {
            'request_id': ?requestId,
            'schedules': [for (final record in listed) _projectRecord(record)],
            'truncated': truncated,
          },
        ),
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: listCommand);
    }
  }

  /// Answers the next instant a candidate definition would fire
  /// (`schedule.preview` -> `schedule.preview_result`).
  ///
  /// A rejected definition is the answer rather than a transport failure: the
  /// result carries `valid: false` and the protocol error code, so the form can
  /// show it while the user types (D4).
  Future<Map<String, dynamic>> buildPreviewEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: previewCommand,
        allowed: {
          'request_id',
          CommandAuthority.payloadKey,
          ...ScheduleRequest.definitionFields,
        },
      );
      final now = _clock().toUtc();
      final ScheduleDefinition definition;
      try {
        definition = ScheduleRequest.parseDefinition(
          ScheduleRequest.definitionValues(fields, command: previewCommand),
          defaultZone: _defaultZone,
          now: now,
        );
      } on ScheduleRequestException catch (error) {
        _logger.fine('Schedule preview rejected; code=${error.code}.');
        return _buildEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.schedulePreviewResult,
            payload: {
              'request_id': ?requestId,
              'valid': false,
              'error_code': error.code,
            },
          ),
        );
      }

      final zone = ScheduleZone.parse(definition.zone);
      final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
        definition,
        from: now,
      );

      return _buildEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.schedulePreviewResult,
          payload: {
            'request_id': ?requestId,
            'valid': true,
            'next_run_at': zone.formatInstant(nextRunAt),
            'zone': zone.raw,
          },
        ),
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: previewCommand);
    }
  }

  /// One bounded, newest-first page of a schedule's run history
  /// (`schedule.runs` -> `schedule.runs_result`).
  Future<Map<String, dynamic>> buildRunsEnvelope(CanonicalEvent event) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: runsCommand,
        allowed: {
          'request_id',
          CommandAuthority.payloadKey,
          'schedule_id',
          'limit',
          'cursor',
        },
      );
      final scheduleId = ScheduleRequest.requiredString(
        fields,
        'schedule_id',
        command: runsCommand,
      );
      final limit = _readLimit(fields);
      final rawCursor = ScheduleRequest.optionalString(
        fields,
        'cursor',
        command: runsCommand,
      );
      final cursor = rawCursor == null
          ? null
          : ScheduleRunsCursor.decode(rawCursor, scheduleId: scheduleId);

      if (_scheduler.getSchedule(scheduleId) == null) {
        throw ScheduleNotFoundException('Schedule "$scheduleId" not found.');
      }

      final page = _sessionManager.db.scheduledTaskRuns.listRuns(
        scheduleId,
        limit: limit,
        before: cursor?.runAt,
        beforeId: cursor?.runId,
      );
      final runs = page.runs;
      final nextCursor = page.hasMore && runs.isNotEmpty
          ? ScheduleRunsCursor(
              scheduleId: scheduleId,
              runAt: runs.last.runAt,
              runId: runs.last.id,
            ).encode()
          : null;

      _logger.fine(
        'Listing schedule runs; schedule_id=$scheduleId, count=${runs.length}, '
        'has_more=${page.hasMore}.',
      );

      return _buildEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.scheduleRunsResult,
          payload: {
            'request_id': ?requestId,
            'schedule_id': scheduleId,
            'runs': [for (final run in runs) ScheduleRunProjection.project(run)],
            'has_more': page.hasMore,
            'next_cursor': ?nextCursor,
          },
        ),
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: runsCommand);
    }
  }

  int _readLimit(Map<String, dynamic> fields) {
    final limit = ScheduleRequest.optionalInt(
      fields,
      'limit',
      command: runsCommand,
    );
    if (limit == null) return ScheduleWireLimits.defaultRunsPageSize;
    if (limit < 1 || limit > ScheduleWireLimits.maxRunsPageSize) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Field "limit" must be between 1 and '
        '${ScheduleWireLimits.maxRunsPageSize} in $runsCommand.',
      );
    }
    return limit;
  }

  Map<String, dynamic> _projectRecord(ScheduledTaskRecord record) {
    final ownerSessionId = ScheduleRowProjection.ownerSession(record);
    return ScheduleRowProjection.project(
      record: record,
      consecutiveFailures: _scheduler.consecutiveFailures(record.id),
      ownerSessionTitle: ownerSessionId == null
          ? null
          : _sessionManager.getSessionRecord(ownerSessionId)?.title,
    );
  }

  /// Applies the same transport-authority and request-shape gate the mutating
  /// commands use: a read is still device-owner only, and a schedule query never
  /// serves an unverified transport.
  Map<String, dynamic> _admit(
    CanonicalEvent event, {
    required String command,
    required Set<String> allowed,
  }) {
    final payload = event.payload;
    ScheduleRequest.requestId(payload, command);

    final authority = CommandAuthority.fromStamped(
      payload[CommandAuthority.payloadKey],
    );
    if (!authority.isOwner) {
      throw const ScheduleRequestException(
        'permission_denied',
        'Only the device owner may control schedules.',
      );
    }

    ScheduleRequest.rejectUnknownFields(
      payload: payload,
      allowed: allowed,
      command: command,
    );
    return payload;
  }

  String? _requestIdOf(CanonicalEvent event) {
    final raw = event.payload['request_id'];
    return raw is String ? raw : null;
  }

  Map<String, dynamic> _failureEnvelope(
    String? requestId,
    Object error, {
    required String command,
  }) {
    final ({String code, String message}) mapped = switch (error) {
      ScheduleRequestException(:final code, :final message) => (
        code: code,
        message: message,
      ),
      ScheduleRunsCursorException(:final message) => (
        code: ScheduleRequestException.invalidRequest,
        message: message,
      ),
      ScheduleNotFoundException(:final message) => (
        code: 'schedule_not_found',
        message: message,
      ),
      SchedulePermissionException(:final message) => (
        code: 'permission_denied',
        message: message,
      ),
      _ => (
        code: 'internal_error',
        message: _internalErrorMessage,
      ),
    };

    if (mapped.code == 'internal_error') {
      _logger.severe('Schedule query failed; command=$command, code=${mapped.code}.');
    } else {
      _logger.warning('Schedule query failed; command=$command, code=${mapped.code}.');
    }
    return _error(requestId, mapped.code, mapped.message);
  }

  static const String _internalErrorMessage =
      'The schedule request could not be completed.';

  Map<String, dynamic> _buildEnvelope(CanonicalEvent canonicalEvent) {
    final bridge = _bridge;
    if (bridge != null) {
      return bridge.buildAgentEventEnvelope(canonicalEvent);
    }
    return buildAgentEventEnvelope(canonicalEvent);
  }

  Map<String, dynamic> _error(String? requestId, String code, String message) {
    return _buildEnvelope(
      CanonicalEvent(
        type: 'error',
        payload: {
          'request_id': requestId,
          'code': code,
          'message': message,
        },
      ),
    );
  }
}
