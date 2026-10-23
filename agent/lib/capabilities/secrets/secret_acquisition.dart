import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';

import 'user_secret_vault.dart';

/// Tool names of the Plan 84 secret tools.
abstract final class SecretToolNames {
  static const request = 'system_request_secret';
  static const list = 'system_list_secrets';
  static const delete = 'system_delete_secret';
}

/// One input the model asks the user for. [name] is the environment
/// variable name the value is stored and later injected under.
class SecretRequestField {
  const SecretRequestField({
    required this.name,
    required this.label,
    this.description = '',
    this.masked = true,
    this.required = true,
  });

  final String name;
  final String label;
  final String description;
  final bool masked;
  final bool required;

  static const maxFields = 10;
  static const maxLabelLength = 80;
  static const maxDescriptionLength = 300;

  Map<String, dynamic> toJson() => {
    'name': name,
    'label': label,
    if (description.isNotEmpty) 'description': description,
    'masked': masked,
    'required': required,
  };

  /// Parses and validates the model's `fields`. Throws [FormatException]
  /// naming the problem; values are never part of the input.
  static List<SecretRequestField> parseAll(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > maxFields) {
      throw const FormatException(
        'fields must list between 1 and $maxFields secrets.',
      );
    }
    final fields = <SecretRequestField>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const FormatException('Each field must be an object.');
      }
      final name = item['name'];
      if (name is! String || UserSecretVault.nameRejection(name) != null) {
        throw FormatException(
          'Invalid secret name: $name. Use an environment variable name that '
          'is not a protected system or Sanad variable.',
        );
      }
      if (fields.any((field) => field.name == name)) {
        throw FormatException('Duplicate secret name: $name');
      }
      final label = item['label'];
      if (label is! String ||
          label.trim().isEmpty ||
          label.length > maxLabelLength) {
        throw FormatException(
          'Field $name needs a label of at most $maxLabelLength characters.',
        );
      }
      final description = item['description'];
      if (description != null &&
          (description is! String ||
              description.length > maxDescriptionLength)) {
        throw FormatException(
          'Field $name description must be text of at most '
          '$maxDescriptionLength characters.',
        );
      }
      final masked = item['masked'];
      final required = item['required'];
      if ((masked != null && masked is! bool) ||
          (required != null && required is! bool)) {
        throw FormatException('Field $name masked/required must be booleans.');
      }
      fields.add(
        SecretRequestField(
          name: name,
          label: label.trim(),
          description: (description as String?)?.trim() ?? '',
          masked: masked as bool? ?? true,
          required: required as bool? ?? true,
        ),
      );
    }
    return fields;
  }

  static List<SecretRequestField> fromPayload(Object? raw) {
    try {
      return parseAll(raw);
    } on FormatException {
      return const [];
    }
  }
}

/// Typed refusal of a client decision for a pending secret request. The
/// request stays pending.
class SecretDecisionFailure {
  const SecretDecisionFailure(this.code, this.message);

  final String code;
  final String message;
}

/// A validated decision whose values have been removed. [decision] is the
/// only form that may be retained, persisted or handed to the tool; [commit]
/// writes the held values into the vault and records a failure in
/// [decision] when the vault refuses them.
class PreparedSecretDecision {
  PreparedSecretDecision._(this.decision, this._commit);

  final Map<String, dynamic> decision;
  final Future<void> Function() _commit;
  bool _committed = false;

  Future<void> commit() async {
    if (_committed) return;
    _committed = true;
    await _commit();
  }
}

/// Owner of the secret-request decision boundary (Plan 84).
///
/// A client answers a pending `system_request_secret` with
/// `secret_values` (`{NAME: value}`) or a skip (`allowed: false`). The values
/// are validated against the requested fields, written to [UserSecretVault]
/// and dropped: the sanitized decision carries names and an outcome only, so
/// nothing downstream (the in-memory resolution record, the durable
/// `resolved_decision`, the tool result, history or logs) can hold a value.
class SecretAcquisition {
  SecretAcquisition({
    UserSecretVault? vault,
    UserSecretMetadataRepository? metadata,
  }) : _vault = vault ?? UserSecretVault(),
       _metadata = metadata;

  final UserSecretVault _vault;

  /// Owner of the non-secret metadata row of a secret this path stored
  /// (Task 140 A3).
  ///
  /// `null` in a runtime that never opened the agent-state database (a CLI
  /// turn, a test double); the value is still stored, and the metadata row is
  /// created by the next `UserSecretCatalog.list()` repair.
  final UserSecretMetadataRepository? _metadata;

  static final _logger = Logger('SecretAcquisition');

  static const valuesKey = 'secret_values';
  static const outcomeKey = 'secret_outcome';
  static const namesKey = 'secret_names';

  /// Validates [decision] for the request described by [permissionPayload].
  static SecretDecisionFailure? validate(
    Map<String, dynamic> permissionPayload,
    Map<String, dynamic> decision,
  ) {
    if (!CommandAuthority.fromStamped(
      decision[CommandAuthority.payloadKey],
    ).isOwner) {
      return const SecretDecisionFailure(
        'PERMISSION_DENIED',
        'Only the device owner can answer a secret request.',
      );
    }
    if (decision.containsKey('answer')) {
      return const SecretDecisionFailure(
        'INVALID_INTERVENTION_KIND',
        'A secret request takes secret_values or a skip, not an answer.',
      );
    }
    final allowed = decision['allowed'];
    if (allowed is! bool) {
      return const SecretDecisionFailure(
        'MALFORMED_DECISION',
        'The "allowed" field must be a boolean.',
      );
    }
    if (!allowed) return null;

    final raw = decision[valuesKey];
    if (raw is! Map || raw.isEmpty) {
      return const SecretDecisionFailure(
        'INVALID_SECRET_VALUES',
        'A saved secret request needs secret_values.',
      );
    }
    final fields = {
      for (final field in SecretRequestField.fromPayload(
        permissionPayload['fields'],
      ))
        field.name: field,
    };
    for (final entry in raw.entries) {
      final value = entry.value;
      if (!fields.containsKey(entry.key) ||
          value is! String ||
          value.length > UserSecretVault.maxValueLength) {
        return const SecretDecisionFailure(
          'INVALID_SECRET_VALUES',
          'secret_values must contain only requested names with text values.',
        );
      }
    }
    for (final field in fields.values.where((field) => field.required)) {
      final value = raw[field.name];
      if (value is! String || value.isEmpty) {
        return SecretDecisionFailure(
          'INVALID_SECRET_VALUES',
          'The required secret ${field.name} has no value.',
        );
      }
    }
    return null;
  }

  /// Removes the values from an already [validate]d [decision].
  PreparedSecretDecision prepare(Map<String, dynamic> decision) {
    final sessionId = decision['session_id'];
    if (decision['allowed'] != true) {
      return PreparedSecretDecision._({
        'session_id': ?sessionId,
        'allowed': false,
        outcomeKey: 'skipped',
      }, () async {});
    }
    final values = <String, String>{
      for (final entry in (decision[valuesKey] as Map).entries)
        if ((entry.value as String).isNotEmpty)
          entry.key.toString(): entry.value as String,
    };
    final names = values.keys.toList()..sort();
    final sanitized = <String, dynamic>{
      'session_id': ?sessionId,
      'allowed': true,
      outcomeKey: 'stored',
      namesKey: names,
    };
    return PreparedSecretDecision._(sanitized, () async {
      try {
        await _vault.store(values);
      } catch (error) {
        _logger.warning(
          'User secret was not saved (${error.runtimeType}); '
          'count=${values.length}.',
        );
        sanitized
          ..[outcomeKey] = 'failed'
          ..remove(namesKey);
        return;
      }
      _recordAcquiredMetadata(names);
    });
  }

  /// Records `source = agent_request` for the names a card just stored
  /// (Task 140 A3).
  ///
  /// The vault write already verified, so a metadata failure must not change
  /// the reported outcome (M3): the row is repaired by the next catalog read.
  /// Nothing here touches a value, and [names] is all that is passed on.
  void _recordAcquiredMetadata(List<String> names) {
    final metadata = _metadata;
    if (metadata == null) return;
    try {
      for (final name in names) {
        metadata.recordValue(
          name: name,
          description: null,
          source: UserSecretSource.agentRequest,
        );
      }
      _logger.info('Recorded metadata for ${names.length} acquired secret(s).');
    } catch (error) {
      _logger.warning(
        'Acquired user secret stored without metadata '
        '(${error.runtimeType}); count=${names.length}.',
      );
    }
  }

  /// Model-visible result for a sanitized decision. Never contains a value.
  static ({String text, bool isError}) resultFor(
    Map<String, dynamic> decision,
  ) {
    switch (decision[outcomeKey]) {
      case 'stored':
        final names = List<String>.from(
          (decision[namesKey] as List? ?? const []).map((name) => '$name'),
        );
        return (
          text: jsonEncode({
            'status': 'stored',
            'secrets': names,
            'usage':
                'Pass these names in shell_execute "secrets" to use them. '
                'Values are never shown to you.',
          }),
          isError: false,
        );
      case 'failed':
        return (
          text: jsonEncode({
            'status': 'failed',
            'message': 'The secret could not be saved in the Agent vault.',
          }),
          isError: true,
        );
      default:
        return (
          text: jsonEncode({
            'status': 'skipped',
            'message': 'The user did not provide the secret.',
          }),
          isError: false,
        );
    }
  }
}
