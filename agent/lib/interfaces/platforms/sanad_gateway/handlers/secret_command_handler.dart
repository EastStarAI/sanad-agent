import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_catalog.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

import '../sanad_protocol_bridge.dart';
import 'support/agent_event_envelope.dart';

/// Handles the device-owner user secret commands (`secrets.list`, `secret.set`,
/// `secret.delete`) across local and cloud gateway transports (Task 140 A2, M4).
///
/// Invariants:
/// - Write-only: values travel inbound only into the vault, never back out to
///   any response, event, broadcast, or log.
/// - Structurally value-free: responses and broadcasts carry non-secret metadata
///   or status only.
/// - Device owner authority only: unverified or model callers are rejected.
/// - Validates completely before mutating: unknown fields, wrong types, or
///   invalid parameters mutate nothing.
/// - Interacts exclusively with [UserSecretCatalog], never reading values from
///   the vault directly.
class SecretCommandHandler {
  SecretCommandHandler({
    required UserSecretCatalog catalog,
    SanadProtocolBridge? bridge,
    void Function(CanonicalEvent event)? broadcastFamilyEvent,
  }) : _catalog = catalog,
       _bridge = bridge,
       _broadcastFamilyEvent = broadcastFamilyEvent;

  final UserSecretCatalog _catalog;
  final SanadProtocolBridge? _bridge;
  final void Function(CanonicalEvent event)? _broadcastFamilyEvent;

  static final _logger = Logger('SecretCommandHandler');

  static const Set<String> _listAllowedKeys = {
    'request_id',
    CommandAuthority.payloadKey,
  };

  static const Set<String> _setAllowedKeys = {
    'request_id',
    CommandAuthority.payloadKey,
    'name',
    'value',
    'description',
  };

  static const Set<String> _deleteAllowedKeys = {
    'request_id',
    CommandAuthority.payloadKey,
    'name',
    'confirm',
  };

  /// Dispatches incoming secret canonical events to their respective builders.
  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    switch (event.type) {
      case CanonicalEventTypes.secretsList:
        await emitEnvelope(await buildListEnvelope(event));
        return;
      case CanonicalEventTypes.secretSet:
        await emitEnvelope(await buildSetEnvelope(event));
        return;
      case CanonicalEventTypes.secretDelete:
        await emitEnvelope(await buildDeleteEnvelope(event));
        return;
      default:
        _logger.fine('Ignoring unsupported secret event: ${event.type}');
        return;
    }
  }

  /// Lists stored secret non-secret metadata (`secrets.list` -> `secrets.list_result`).
  Future<Map<String, dynamic>> buildListEnvelope(CanonicalEvent event) async {
    final rawRequestId = event.payload['request_id'];
    if (rawRequestId != null && rawRequestId is! String) {
      return _error(null, 'invalid_request', 'request_id must be a string.');
    }
    final requestId = rawRequestId as String?;

    final authorityError = _checkAuthority(event, requestId);
    if (authorityError != null) return authorityError;

    for (final key in event.payload.keys) {
      if (!_listAllowedKeys.contains(key)) {
        _logger.warning('Secret list rejected; code=invalid_request, field=$key.');
        return _error(
          requestId,
          'invalid_request',
          'Unknown field in secrets.list payload: $key.',
        );
      }
    }

    final outcome = _catalog.list();
    if (!outcome.isSuccess) {
      final failure = outcome.failure!;
      _logger.warning(
        'Secret list failed; code=${failure.code.wireName}.',
      );
      return _error(requestId, failure.code.wireName, failure.message);
    }

    final entries = outcome.requireValue;
    _logger.fine('Listing user secrets; count=${entries.length}.');

    return _buildEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.secretsListResult,
        payload: {
          'request_id': ?requestId,
          'secrets': [
            for (final entry in entries) entry.toJson(),
          ],
          'truncated': false,
        },
      ),
    );
  }

  /// Adds or replaces a user secret (`secret.set` -> `secret.saved`).
  Future<Map<String, dynamic>> buildSetEnvelope(CanonicalEvent event) async {
    final rawRequestId = event.payload['request_id'];
    if (rawRequestId != null && rawRequestId is! String) {
      return _error(null, 'invalid_request', 'request_id must be a string.');
    }
    final requestId = rawRequestId as String?;

    final authorityError = _checkAuthority(event, requestId);
    if (authorityError != null) return authorityError;

    for (final key in event.payload.keys) {
      if (!_setAllowedKeys.contains(key)) {
        _logger.warning('Secret set rejected; code=invalid_request, field=$key.');
        return _error(
          requestId,
          'invalid_request',
          'Unknown field in secret.set payload: $key.',
        );
      }
    }

    final rawName = event.payload['name'];
    if (rawName == null || rawName is! String) {
      _logger.warning(
        'Secret set rejected; code=invalid_request, reason=missing_name.',
      );
      return _error(
        requestId,
        'invalid_request',
        'Field "name" is required and must be a string.',
      );
    }
    final name = rawName;

    final nameRejection = UserSecretVault.nameRejection(name);
    if (nameRejection != null) {
      final code = nameRejection == 'reserved_name'
          ? 'reserved_secret_name'
          : 'invalid_secret_name';
      final message = nameRejection == 'reserved_name'
          ? '$name is a protected or Sanad-owned variable name.'
          : '$name is not a valid environment variable name.';
      _logger.warning('Secret set rejected; code=$code, name=$name.');
      return _error(requestId, code, message);
    }

    final rawValue = event.payload['value'];
    if (rawValue == null || rawValue is! String) {
      _logger.warning(
        'Secret set rejected; code=invalid_request, reason=missing_value, name=$name.',
      );
      return _error(
        requestId,
        'invalid_request',
        'Field "value" is required and must be a string.',
      );
    }
    final value = rawValue;

    final valueRejection = UserSecretCatalog.valueRejection(value);
    if (valueRejection != null) {
      _logger.warning('Secret set rejected; code=invalid_secret_value, name=$name.');
      return _error(
        requestId,
        'invalid_secret_value',
        'The value for $name is empty, longer than '
        '${UserSecretVault.maxValueLength} characters, or a redaction sentinel.',
      );
    }

    final rawDescription = event.payload['description'];
    String? description;
    if (rawDescription != null) {
      if (rawDescription is! String) {
        _logger.warning(
          'Secret set rejected; code=invalid_request, reason=bad_description_type, name=$name.',
        );
        return _error(
          requestId,
          'invalid_request',
          'Field "description" must be a string.',
        );
      }
      if (rawDescription.length >
          UserSecretMetadataRepository.maxDescriptionLength) {
        _logger.warning(
          'Secret set rejected; code=invalid_request, reason=description_too_long, name=$name.',
        );
        return _error(
          requestId,
          'invalid_request',
          'The description for $name is longer than '
          '${UserSecretMetadataRepository.maxDescriptionLength} characters.',
        );
      }
      description = rawDescription;
    }

    final outcome = await _catalog.set(
      name: name,
      value: value,
      description: description,
    );

    if (!outcome.isSuccess) {
      final failure = outcome.failure!;
      _logger.warning(
        'Secret set failed; code=${failure.code.wireName}, name=$name.',
      );
      return _error(requestId, failure.code.wireName, failure.message);
    }

    final metadata = outcome.requireValue;
    _logger.info(
      'User secret saved; name=$name, source=${metadata.source.wireName}.',
    );
    _broadcastChanged(name, 'set');

    return _buildEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.secretSaved,
        payload: {
          'request_id': ?requestId,
          'name': metadata.name,
          'description': metadata.description,
          'source': metadata.source.wireName,
          'created_at': metadata.createdAt.toUtc().toIso8601String(),
          'updated_at': metadata.updatedAt.toUtc().toIso8601String(),
        },
      ),
    );
  }

  /// Deletes a stored user secret (`secret.delete` -> `secret.deleted`).
  Future<Map<String, dynamic>> buildDeleteEnvelope(CanonicalEvent event) async {
    final rawRequestId = event.payload['request_id'];
    if (rawRequestId != null && rawRequestId is! String) {
      return _error(null, 'invalid_request', 'request_id must be a string.');
    }
    final requestId = rawRequestId as String?;

    final authorityError = _checkAuthority(event, requestId);
    if (authorityError != null) return authorityError;

    for (final key in event.payload.keys) {
      if (!_deleteAllowedKeys.contains(key)) {
        _logger.warning(
          'Secret delete rejected; code=invalid_request, field=$key.',
        );
        return _error(
          requestId,
          'invalid_request',
          'Unknown field in secret.delete payload: $key.',
        );
      }
    }

    final rawName = event.payload['name'];
    if (rawName == null || rawName is! String) {
      _logger.warning(
        'Secret delete rejected; code=invalid_request, reason=missing_name.',
      );
      return _error(
        requestId,
        'invalid_request',
        'Field "name" is required and must be a string.',
      );
    }
    final name = rawName;

    final nameRejection = UserSecretVault.nameRejection(name);
    if (nameRejection != null) {
      final code = nameRejection == 'reserved_name'
          ? 'reserved_secret_name'
          : 'invalid_secret_name';
      final message = nameRejection == 'reserved_name'
          ? '$name is a protected or Sanad-owned variable name.'
          : '$name is not a valid environment variable name.';
      _logger.warning('Secret delete rejected; code=$code, name=$name.');
      return _error(requestId, code, message);
    }

    final rawConfirm = event.payload['confirm'];
    if (rawConfirm != true) {
      _logger.warning(
        'Secret delete rejected; code=invalid_request, reason=missing_confirm, name=$name.',
      );
      return _error(
        requestId,
        'invalid_request',
        'Deleting a secret requires confirm: true.',
      );
    }

    final outcome = await _catalog.delete(name);
    if (!outcome.isSuccess) {
      final failure = outcome.failure!;
      _logger.warning(
        'Secret delete failed; code=${failure.code.wireName}, name=$name.',
      );
      return _error(requestId, failure.code.wireName, failure.message);
    }

    final deleted = outcome.requireValue;
    if (deleted) {
      _logger.info('User secret deleted; name=$name.');
      _broadcastChanged(name, 'deleted');
    } else {
      _logger.info('User secret delete not found; name=$name.');
    }

    return _buildEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.secretDeleted,
        payload: {
          'request_id': ?requestId,
          'name': name,
          'status': deleted ? 'deleted' : 'not_found',
        },
      ),
    );
  }

  void _broadcastChanged(String name, String change) {
    final broadcastEvent = CanonicalEvent(
      type: CanonicalEventTypes.secretsChanged,
      payload: {
        'name': name,
        'change': change,
      },
    );
    _broadcastFamilyEvent?.call(broadcastEvent);
  }

  Map<String, dynamic>? _checkAuthority(
    CanonicalEvent event,
    String? requestId,
  ) {
    final authority = CommandAuthority.fromStamped(
      event.payload[CommandAuthority.payloadKey],
    );
    if (!authority.isOwner) {
      _logger.warning('Secret command rejected; code=permission_denied.');
      return _error(
        requestId,
        'permission_denied',
        'Only the device owner may manage secrets.',
      );
    }
    return null;
  }

  Map<String, dynamic> _buildEnvelope(CanonicalEvent canonicalEvent) {
    if (_bridge != null) {
      return _bridge.buildAgentEventEnvelope(canonicalEvent);
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
