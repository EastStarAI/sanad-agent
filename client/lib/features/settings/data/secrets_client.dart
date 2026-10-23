import 'dart:async';

import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

/// Why a user-secret command did not succeed, as a code the Client can
/// localize (Task 140 C3).
///
/// Every value except [deviceUnavailable] is a `code` the Agent sent in its
/// error envelope (Task 140 140-02). The Agent's `message` is deliberately not
/// carried: it is operator-facing English, never UI copy, and it is the one
/// string a future change could make value-bearing.
enum SecretsErrorCode {
  /// The caller is not the device owner (`permission_denied`).
  permissionDenied,

  /// Unknown field, wrong type, missing name/confirm, oversized description
  /// (`invalid_request`).
  invalidRequest,

  /// The name is not an environment-variable name (`invalid_secret_name`).
  invalidSecretName,

  /// The name is a protected or Sanad-owned variable (`reserved_secret_name`).
  reservedSecretName,

  /// Empty value, a value over the length bound, or a redaction sentinel
  /// (`invalid_secret_value`).
  invalidSecretValue,

  /// The Agent credential vault cannot store now; nothing was written
  /// (`vault_unavailable`).
  vaultUnavailable,

  /// The Agent could not read or write its metadata store (`internal_error`).
  internalError,

  /// The command never reached the Agent: the device is offline, the socket is
  /// not connected, or the request timed out. Not a protocol code.
  deviceUnavailable,

  /// A code this Client does not know yet; [SecretsException.wireCode] keeps
  /// the protocol token for diagnosis.
  unknown;

  /// Maps a protocol error code to its typed counterpart.
  static SecretsErrorCode fromWireCode(String? code) {
    return switch (code?.trim().toLowerCase()) {
      'permission_denied' => SecretsErrorCode.permissionDenied,
      'invalid_request' => SecretsErrorCode.invalidRequest,
      'invalid_secret_name' => SecretsErrorCode.invalidSecretName,
      'reserved_secret_name' => SecretsErrorCode.reservedSecretName,
      'invalid_secret_value' => SecretsErrorCode.invalidSecretValue,
      'vault_unavailable' => SecretsErrorCode.vaultUnavailable,
      'internal_error' => SecretsErrorCode.internalError,
      _ => SecretsErrorCode.unknown,
    };
  }
}

/// A typed refusal of a user-secret command.
///
/// It carries the typed [code], the secret [name] the refusal is about (safe:
/// it is the row identity the user typed), and the raw [wireCode] only when
/// [code] is [SecretsErrorCode.unknown]. It carries **no** submitted value, no
/// prefix of one, and no Agent message text, so a formatted error can never
/// become a value leak.
class SecretsException implements Exception {
  const SecretsException(this.code, {this.name, this.wireCode});

  final SecretsErrorCode code;
  final String? name;
  final String? wireCode;

  @override
  String toString() =>
      'SecretsException(${code.name}, name: ${name ?? 'none'}'
      '${wireCode == null ? '' : ', wire: $wireCode'})';
}

/// How the **current** value of a stored secret arrived (Task 140 M5).
///
/// An unrecognized wire value reads as [agentRequest]: a row must never claim
/// the device owner typed a value in when no recorded path says so.
enum SecretSource {
  user,
  agentRequest;

  String get wireName => switch (this) {
    SecretSource.user => 'user',
    SecretSource.agentRequest => 'agent_request',
  };

  static SecretSource fromWire(Object? value) =>
      value?.toString().trim().toLowerCase() == 'user' ? SecretSource.user : SecretSource.agentRequest;
}

/// One stored secret as the Settings list sees it: the five non-secret fields
/// the protocol projects and nothing else (Task 140 M4, K2).
///
/// There is no value field, no hash of one, and no prefix of one, so no code
/// path can render, cache, or log a value it never received.
class StoredSecret {
  const StoredSecret({
    required this.name,
    required this.source,
    this.description,
    this.createdAt,
    this.updatedAt,
  });

  /// The vault name; the only identity of a stored secret.
  final String name;

  /// The user-authored description, or `null` when none is stored.
  final String? description;

  /// The arrival path of the current value.
  final SecretSource source;

  /// Protocol timestamps. The Agent never projects a null timestamp; these are
  /// nullable only so a malformed payload cannot crash the list.
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasDescription => (description ?? '').trim().isNotEmpty;

  factory StoredSecret.fromJson(Map<String, dynamic> json) {
    return StoredSecret(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString(),
      source: SecretSource.fromWire(json['source']),
      createdAt: parseUtc(json['created_at']),
      updatedAt: parseUtc(json['updated_at']),
    );
  }

  /// The non-secret projection this Client re-exports. It lists the five
  /// allowed fields explicitly so an unexpected wire field cannot survive.
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'source': source.wireName,
    'created_at': createdAt?.toUtc().toIso8601String(),
    'updated_at': updatedAt?.toUtc().toIso8601String(),
  };

  static DateTime? parseUtc(Object? value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredSecret &&
          other.name == name &&
          other.description == description &&
          other.source == source &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(name, description, source, createdAt, updatedAt);

  @override
  String toString() =>
      'StoredSecret(name: $name, source: ${source.wireName}, updatedAt: ${updatedAt?.toIso8601String()})';
}

/// The `secrets.list_result` projection.
class StoredSecretsSnapshot {
  const StoredSecretsSnapshot({required this.secrets, this.truncated = false});

  final List<StoredSecret> secrets;
  final bool truncated;
}

/// The outcome of `secret.delete`: the vault held the name or it did not.
enum SecretDeletionStatus { deleted, notFound }

/// Client data boundary for the device-owner user-secret protocol (Task 140 C5).
///
/// It speaks only the write-only protocol of
/// `docs/technical/secret_management_protocol.md` through the shared
/// [DeviceCommandClient], so local and cloud routes are identical and no screen
/// selects a transport. It never reads a stored value: there is no command that
/// returns one.
class SecretsClient {
  SecretsClient(this._commands);

  final DeviceCommandClient _commands;

  static const String listCommand = 'secrets.list';
  static const String listResultEvent = 'secrets.list_result';
  static const String setCommand = 'secret.set';
  static const String savedEvent = 'secret.saved';
  static const String deleteCommand = 'secret.delete';
  static const String deletedEvent = 'secret.deleted';
  static const String changedEvent = 'secrets.changed';

  /// Mirrors `UserSecretVault.maxValueLength`; the Agent remains authoritative.
  static const int maxValueLength = 16384;

  /// Mirrors `UserSecretMetadataRepository.maxDescriptionLength`.
  static const int maxDescriptionLength = 256;

  /// The name grammar the Agent enforces (`UserSecretVault.nameRejection`).
  ///
  /// Only the shape lives here. The reserved-name list (protected operator
  /// variables and Sanad-owned variables) stays Agent-owned: duplicating it
  /// would drift, so a reserved name is reported by the Agent as
  /// [SecretsErrorCode.reservedSecretName].
  static final RegExp namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

  /// Matches the `[REDACTED:<NAME>]` marker the Agent writes in place of an
  /// injected value, so a displayed mask can never be stored as a secret
  /// (Task 140 M6, protocol §7.4).
  static final RegExp _redactionSentinel = RegExp(r'\[REDACTED:[^\]]*\]');

  /// Whether [name] matches the Agent's name grammar.
  static bool isValidNameFormat(String name) => namePattern.hasMatch(name);

  /// Every stored secret's non-secret metadata (`secrets.list`).
  Future<StoredSecretsSnapshot> list(DeviceConfig device) async {
    final payload = await _request(
      device,
      command: listCommand,
      expectedEvent: listResultEvent,
    );
    final entries = payload['secrets'];
    return StoredSecretsSnapshot(
      secrets: [
        if (entries is List)
          for (final entry in entries)
            if (entry is Map) StoredSecret.fromJson(Map<String, dynamic>.from(entry)),
      ],
      truncated: payload['truncated'] == true,
    );
  }

  /// Adds a value for [name], or replaces the stored one (Task 140 K3).
  ///
  /// [value] is validated here and then sent; it is not retained by this
  /// object, returned by this method, or stored anywhere on the Client.
  /// Passing a `null` description clears the stored description on the Agent.
  Future<StoredSecret> set(
    DeviceConfig device, {
    required String name,
    required String value,
    String? description,
  }) async {
    _rejectUnstorableValue(name, value);
    if ((description?.length ?? 0) > maxDescriptionLength) {
      throw SecretsException(SecretsErrorCode.invalidRequest, name: name);
    }
    final payload = await _request(
      device,
      command: setCommand,
      expectedEvent: savedEvent,
      name: name,
      payload: {
        'name': name,
        'value': value,
        if (description != null) 'description': description,
      },
    );
    return StoredSecret.fromJson(payload);
  }

  /// Deletes [name] from the Agent vault and its metadata row.
  ///
  /// The protocol requires `confirm: true` on every request; the user-facing
  /// confirmation belongs to the screen that calls this method (Task 140 C2).
  Future<SecretDeletionStatus> delete(DeviceConfig device, String name) async {
    final payload = await _request(
      device,
      command: deleteCommand,
      expectedEvent: deletedEvent,
      name: name,
      payload: {'name': name, 'confirm': true},
    );
    return payload['status'] == 'deleted' ? SecretDeletionStatus.deleted : SecretDeletionStatus.notFound;
  }

  /// Mutations of any secret on [device] made by this or another client
  /// (`secrets.changed`).
  ///
  /// The payload is not projected at all: it announces that the authoritative
  /// list changed, and the owning cubit re-reads that list instead of trusting
  /// the event as the list.
  Stream<void> changes(DeviceConfig device) =>
      _commands.events(device).where((event) => event['event'] == changedEvent).map<void>((_) {});

  void _rejectUnstorableValue(String name, String value) {
    if (value.isEmpty || value.length > maxValueLength || _redactionSentinel.hasMatch(value)) {
      throw SecretsException(SecretsErrorCode.invalidSecretValue, name: name);
    }
  }

  Future<Map<String, dynamic>> _request(
    DeviceConfig device, {
    required String command,
    required String expectedEvent,
    String? name,
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
      final code = SecretsErrorCode.fromWireCode(error.code);
      throw SecretsException(
        code,
        name: name,
        wireCode: code == SecretsErrorCode.unknown ? error.code : null,
      );
    } on SecretsException {
      rethrow;
    } on TimeoutException {
      throw SecretsException(SecretsErrorCode.deviceUnavailable, name: name);
    } on StateError {
      // The shared command client reports "not connected" and a command timeout
      // as StateError; neither ever becomes UI copy.
      throw SecretsException(SecretsErrorCode.deviceUnavailable, name: name);
    } catch (_) {
      throw SecretsException(SecretsErrorCode.deviceUnavailable, name: name);
    }
  }
}
