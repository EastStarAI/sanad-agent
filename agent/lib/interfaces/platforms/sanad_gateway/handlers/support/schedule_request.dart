import 'package:sanad_agent/evolution/db/scheduled_task_repository.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';

/// A rejected schedule request, already classified by the protocol error code.
///
/// The two codes it can carry are the ones the schedule family owns (Task 139
/// §Validation and error codes): [invalidRequest] for a malformed envelope and
/// [invalidSchedule] for a definition `ScheduleDefinition.parse` refused. Every
/// other code is raised by the control layer and mapped by the handlers.
class ScheduleRequestException implements Exception {
  static const String invalidRequest = 'invalid_request';
  static const String invalidSchedule = 'invalid_schedule';

  final String code;
  final String message;

  const ScheduleRequestException(this.code, this.message);

  bool get isInvalidSchedule => code == invalidSchedule;

  @override
  String toString() => message;
}

/// Complete request validation for the schedule command and query family.
///
/// Every rule here runs before the first mutation: an unknown field, a wrong
/// type, a missing identity, or a definition error rejects the whole request, so
/// a partially valid payload never reaches the control layer (Task 139
/// §Validation and error codes).
///
/// Messages name fields and never echo payload values other than the field name
/// itself, so an error envelope stays stable and non-secret.
abstract final class ScheduleRequest {
  /// Field types `ScheduleDefinition.parse` requires on the wire.
  ///
  /// The parser is deliberately lenient for model-authored arguments (it accepts
  /// a numeric string, or a comma-separated weekday string), but a device-owner
  /// command has one canonical shape, so a wrong wire type is rejected here
  /// instead of being coerced.
  static const Set<String> _stringDefinitionFields = {
    'kind',
    'time',
    'at',
    'in',
    'every',
    'interval',
    'zone',
  };

  static const Set<String> _intDefinitionFields = {
    'interval_minutes',
    'day_of_month',
    'month_day',
  };

  /// Every accepted definition field, as the recurrence keys of
  /// [ScheduleDefinition.definitionKeys].
  static final Set<String> definitionFields = ScheduleDefinition.definitionKeys;

  /// Rejects the request when [payload] carries a key outside [allowed].
  static void rejectUnknownFields({
    required Map<String, dynamic> payload,
    required Set<String> allowed,
    required String command,
  }) {
    for (final key in payload.keys) {
      if (!allowed.contains(key)) {
        throw ScheduleRequestException(
          ScheduleRequestException.invalidRequest,
          'Unknown field in $command payload: $key.',
        );
      }
    }
  }

  /// Reads `request_id`, which is optional and must be a string when present.
  static String? requestId(Map<String, dynamic> payload, String command) {
    final raw = payload['request_id'];
    if (raw == null) return null;
    if (raw is! String) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Field "request_id" must be a string in $command.',
      );
    }
    return raw;
  }

  /// Reads a required, non-blank identity field.
  static String requiredId(
    Map<String, dynamic> payload, {
    required String command,
  }) {
    final raw = payload['id'];
    if (raw is! String || raw.trim().isEmpty) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Field "id" is required and must be a non-empty string in $command.',
      );
    }
    return raw.trim();
  }

  /// Reads a required, non-blank string field.
  static String requiredString(
    Map<String, dynamic> payload,
    String key, {
    required String command,
  }) {
    final raw = payload[key];
    if (raw is! String || raw.trim().isEmpty) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Field "$key" is required and must be a non-empty string in $command.',
      );
    }
    return raw;
  }

  /// Reads an optional string field; an explicit `null` is the same as absent.
  static String? optionalString(
    Map<String, dynamic> payload,
    String key, {
    required String command,
  }) {
    final raw = payload[key];
    if (raw == null) return null;
    if (raw is! String) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Field "$key" must be a string or null in $command.',
      );
    }
    return raw.trim().isEmpty ? null : raw;
  }

  /// Reads an optional integer field.
  static int? optionalInt(
    Map<String, dynamic> payload,
    String key, {
    required String command,
  }) {
    final raw = payload[key];
    if (raw == null) return null;
    if (raw is! int) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Field "$key" must be an integer in $command.',
      );
    }
    return raw;
  }

  /// Requires the explicit `confirm: true` a deletion must carry (Task 139
  /// S10, D7). Only the literal `true` confirms; a string or a `1` does not.
  static void requireConfirmation(
    Map<String, dynamic> payload, {
    required String command,
  }) {
    if (payload['confirm'] != true) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Deleting a schedule requires confirm: true in $command.',
      );
    }
  }

  /// Reads an editable settings column, keeping the repository's
  /// omit-versus-clear sentinel: an absent parameter is [unset], an explicit
  /// `null` clears the column.
  static Object? settingsValue(
    Map<String, dynamic> payload,
    String key, {
    required String command,
  }) {
    if (!payload.containsKey(key)) return ScheduledTaskRepository.unset;
    final raw = payload[key];
    if (raw == null) return null;
    if (raw is! String) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidRequest,
        'Field "$key" must be a string or null in $command.',
      );
    }
    return raw.trim().isEmpty ? null : raw;
  }

  /// Reads the optional `conversation_mode` switch (Task 139 S4).
  ///
  /// The stored column is `NOT NULL`, so `null` is never a valid request and an
  /// unknown value is rejected instead of being coerced into a mode no run can
  /// honor.
  static ScheduleConversationMode? optionalConversationMode(
    Map<String, dynamic> payload, {
    required String command,
  }) {
    if (!payload.containsKey('conversation_mode')) return null;
    final raw = payload['conversation_mode'];
    final text = raw is String ? raw.trim().toLowerCase() : null;
    for (final mode in ScheduleConversationMode.values) {
      if (mode.wireName == text) return mode;
    }
    throw ScheduleRequestException(
      ScheduleRequestException.invalidRequest,
      'Field "conversation_mode" must be one of '
      '${ScheduleConversationMode.values.map((m) => m.wireName).join(', ')} '
      'in $command.',
    );
  }

  /// Returns the definition fields of [payload] with their wire types checked.
  static Map<String, dynamic> definitionValues(
    Map<String, dynamic> payload, {
    required String command,
  }) {
    final values = <String, dynamic>{};
    for (final key in definitionFields) {
      if (!payload.containsKey(key)) continue;
      final raw = payload[key];
      if (_stringDefinitionFields.contains(key)) {
        if (raw is! String) {
          throw ScheduleRequestException(
            ScheduleRequestException.invalidRequest,
            'Field "$key" must be a string in $command.',
          );
        }
        values[key] = raw;
        continue;
      }
      if (_intDefinitionFields.contains(key)) {
        if (raw is! int) {
          throw ScheduleRequestException(
            ScheduleRequestException.invalidRequest,
            'Field "$key" must be an integer in $command.',
          );
        }
        values[key] = raw;
        continue;
      }
      if (key == 'weekdays') {
        if (raw is! List || raw.any((day) => day is! String)) {
          throw ScheduleRequestException(
            ScheduleRequestException.invalidRequest,
            'Field "weekdays" must be an array of strings in $command.',
          );
        }
        values[key] = raw;
      }
    }
    return values;
  }

  /// Parses a definition from already type-checked [values].
  ///
  /// A rejected definition is [ScheduleRequestException.invalidSchedule] with
  /// the parser's own message, which names the violated rule and never carries
  /// payload content.
  static ScheduleDefinition parseDefinition(
    Map<String, dynamic> values, {
    required String defaultZone,
    DateTime? now,
  }) {
    try {
      return ScheduleDefinition.parse(
        values,
        defaultZone: defaultZone,
        now: now,
      );
    } on ScheduleValidationException catch (error) {
      throw ScheduleRequestException(
        ScheduleRequestException.invalidSchedule,
        error.message,
      );
    }
  }
}
