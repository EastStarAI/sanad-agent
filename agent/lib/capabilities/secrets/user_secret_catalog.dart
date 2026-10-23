import 'package:logging/logging.dart';

import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';

import 'user_secret_vault.dart';

/// Why a [UserSecretCatalog] mutation did not happen.
///
/// The code is the protocol error code Task 140 140-02 publishes; this layer
/// names it so the mapping cannot drift, and the message never contains a
/// submitted value, a prefix of one, or its length in characters.
enum UserSecretFailureCode {
  invalidSecretName('invalid_secret_name'),
  reservedSecretName('reserved_secret_name'),
  invalidSecretValue('invalid_secret_value'),
  secretNameRequired('invalid_request'),
  descriptionTooLong('invalid_request'),
  vaultUnavailable('vault_unavailable'),
  internalError('internal_error');

  const UserSecretFailureCode(this.wireName);

  /// The error code the protocol envelope carries.
  final String wireName;
}

/// The typed outcome of a catalog read or mutation.
///
/// A mutation reports success only for the state it actually produced: a
/// verified vault write is never reported as a failure because metadata could
/// not be written (Task 140 M3), and a refused vault write never reports a
/// saved value.
class UserSecretOutcome<T> {
  const UserSecretOutcome.success(this.value) : failure = null;

  const UserSecretOutcome.failure(this.failure) : value = null;

  final T? value;
  final UserSecretFailure? failure;

  bool get isSuccess => failure == null;

  /// The successful value; throws when this outcome is a failure.
  T get requireValue {
    final result = value;
    if (result == null) {
      throw StateError('UserSecretOutcome.requireValue on a failure outcome');
    }
    return result;
  }

  /// A short, value-free description for a log line.
  String describeForLog() => failure == null
      ? 'ok'
      : '${failure!.descriptor} - ${failure!.message}';
}

/// A typed, value-free refusal.
class UserSecretFailure {
  const UserSecretFailure(this.code, this.message);

  final UserSecretFailureCode code;

  /// Operator-facing wording. Never includes the submitted value.
  final String message;

  /// The name of the secret the refusal is about, or `null` when it applied
  /// before the name was known.
  String get descriptor => code.wireName;
}

/// One entry of [UserSecretCatalog.list]: a vault name joined with its
/// non-secret metadata.
///
/// A name that exists in the vault always appears; the three metadata fields
/// are never null in a returned entry because a missing row is repaired on
/// read (Task 140 A2).
class UserSecretEntry {
  const UserSecretEntry({required this.name, required this.metadata});

  /// The vault name.
  final String name;

  /// The repaired-or-existing metadata row.
  final UserSecretMetadata metadata;

  String? get description => metadata.description;

  UserSecretSource get source => metadata.source;

  DateTime get createdAt => metadata.createdAt;

  DateTime get updatedAt => metadata.updatedAt;

  /// The structurally value-free wire shape (Task 140 M4).
  Map<String, dynamic> toJson() => metadata.toJson();
}

/// The single read model behind the Settings → Privacy & Security page
/// (Task 140 A2).
///
/// It joins the vault's names with `user_secret_metadata`, and it is the only
/// owner that may do so. Two rules make the value direction safe:
///
/// - **It never reads a value.** No method here calls `UserSecretVault.resolve`
///   or touches `SecretVaultNamespace.read`; `agent/test/capabilities/secrets/`
///   holds a guard that fails if a value-reading call appears on this path.
/// - **It never trusts an unbounded input.** The name goes through
///   `UserSecretVault.nameRejection`, the value is bounded and sentinel-checked
///   ([UserSecretVault.validateValue]), and the description is bounded by
///   `UserSecretMetadataRepository.maxDescriptionLength`.
///
/// Write ordering is vault first, metadata second (M3): a verified vault write
/// is never reported as a failure because metadata could not be written, and
/// the row is repaired by the next [list]. Metadata is never written for a
/// value the vault refused.
class UserSecretCatalog {
  UserSecretCatalog({
    required UserSecretVault vault,
    required UserSecretMetadataRepository metadata,
  }) : _vault = vault,
       _metadata = metadata;

  final UserSecretVault _vault;
  final UserSecretMetadataRepository _metadata;

  static final _logger = Logger('UserSecretCatalog');

  /// Whether [value] may become a stored secret (Task 140 A2, M6).
  ///
  /// A value is refused when it is empty, longer than
  /// [UserSecretVault.maxValueLength], or a redaction sentinel such as
  /// `[REDACTED:DATABASE_PASSWORD]`. The sentinel rule is what stops a mask
  /// shown in a log, a tool result, or the Client timeline from being written
  /// back as the secret itself. Returns the failure code, or `null` when the
  /// value is acceptable.
  static UserSecretFailureCode? valueRejection(String value) {
    if (value.isEmpty || value.length > UserSecretVault.maxValueLength) {
      return UserSecretFailureCode.invalidSecretValue;
    }
    if (_redactionSentinel.hasMatch(value)) {
      return UserSecretFailureCode.invalidSecretValue;
    }
    return null;
  }

  /// Matches the `[REDACTED:<NAME>]` marker this Agent writes in place of an
  /// injected value. Anchored on the marker anywhere in the value, because a
  /// user pasting a redacted line into the field is the case to refuse.
  static final RegExp _redactionSentinel = RegExp(r'\[REDACTED:[^\]]*\]');

  /// One entry per name present in the vault, joined with its metadata row.
  ///
  /// A name with no row is repaired on read (Task 140 A2, owner decision
  /// 2026-10-23): the row is inserted with `source = agent_request`
  /// — the arrival path this Agent had before the Settings screen existed — a
  /// null description, and `created_at`/`updated_at` set to now, so no entry
  /// ever projects a null timestamp. Rows whose name the vault no longer holds
  /// are pruned in the same read.
  UserSecretOutcome<List<UserSecretEntry>> list() {
    if (!_vault.available) {
      return const UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.vaultUnavailable,
          'The Agent credential vault is not available.',
        ),
      );
    }
    final names = _vault.names();
    final known = names.toSet();
    try {
      final pruned = _metadata.pruneExcept(known);
      if (pruned.isNotEmpty) {
        _logger.info('Pruned ${pruned.length} orphaned secret metadata row(s).');
      }
      final rows = {
        for (final row in _metadata.list()) row.name: row,
      };
      final entries = <UserSecretEntry>[];
      for (final name in names) {
        final row =
            rows[name] ??
            _metadata.recordValue(
              name: name,
              description: null,
              source: UserSecretSource.agentRequest,
            );
        entries.add(UserSecretEntry(name: name, metadata: row));
      }
      return UserSecretOutcome.success(List.unmodifiable(entries));
    } catch (error) {
      _logger.warning(
        'Secret metadata could not be read (${error.runtimeType}); '
        'entries=${names.length}.',
      );
      return UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.internalError,
          'Stored secret metadata could not be read.',
        ),
      );
    }
  }

  /// Stores [value] for [name] and records the metadata of a user-arrived
  /// value.
  ///
  /// The value is validated here, written to the vault, and then described in
  /// `user_secret_metadata` with `source = user` and an advanced `updated_at`
  /// (M5). A replacement writes the same path, so it is a single verified vault
  /// write and never reads the old value.
  Future<UserSecretOutcome<UserSecretMetadata>> set({
    required String name,
    required String value,
    String? description,
  }) async {
    final nameRejection = UserSecretVault.nameRejection(name);
    if (nameRejection != null) {
      return UserSecretOutcome.failure(_nameFailure(nameRejection, name));
    }
    final valueRejection = UserSecretCatalog.valueRejection(value);
    if (valueRejection != null) {
      return UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.invalidSecretValue,
          'The value for $name is empty, longer than '
          '${UserSecretVault.maxValueLength} characters, or a redaction '
          'sentinel.',
        ),
      );
    }
    final String? normalizedDescription;
    try {
      normalizedDescription = UserSecretMetadataRepository.normalizeDescription(
        description,
      );
    } on ArgumentError {
      return UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.descriptionTooLong,
          'The description for $name is longer than '
          '${UserSecretMetadataRepository.maxDescriptionLength} characters.',
        ),
      );
    }
    if (!_vault.available) {
      return const UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.vaultUnavailable,
          'The Agent credential vault is not available.',
        ),
      );
    }

    // Vault first, and it must verify: `UserSecretVault.store` reads every
    // entry back. Nothing is written to metadata when this fails.
    try {
      await _vault.store({name: value});
    } catch (error) {
      _logger.warning(
        'User secret was not saved (${error.runtimeType}); name=$name.',
      );
      return UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.vaultUnavailable,
          'The Agent vault could not store $name.',
        ),
      );
    }

    try {
      final saved = _metadata.recordValue(
        name: name,
        description: normalizedDescription,
        source: UserSecretSource.user,
      );
      _logger.info('User secret saved; name=$name, source=user.');
      return UserSecretOutcome.success(saved);
    } catch (error) {
      // M3: the verified vault write stands. Report the stored value with the
      // metadata we can state truthfully, and let the next list repair the row.
      _logger.warning(
        'Saved user secret without metadata (${error.runtimeType}); '
        'name=$name.',
      );
      final now = DateTime.now().toUtc();
      return UserSecretOutcome.success(
        UserSecretMetadata(
          name: name,
          description: normalizedDescription,
          source: UserSecretSource.user,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  }

  /// Deletes the vault entry for [name] and its metadata row.
  ///
  /// Returns `true` when the vault held the name, `false` for an unknown name.
  /// The metadata row is removed in both cases, so a stale row cannot outlive
  /// the value it described.
  Future<UserSecretOutcome<bool>> delete(String name) async {
    final nameRejection = UserSecretVault.nameRejection(name);
    if (nameRejection != null) {
      return UserSecretOutcome.failure(_nameFailure(nameRejection, name));
    }
    if (!_vault.available) {
      return const UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.vaultUnavailable,
          'The Agent credential vault is not available.',
        ),
      );
    }
    final List<String> removed;
    try {
      removed = await _vault.remove([name]);
    } catch (error) {
      _logger.warning(
        'User secret was not deleted (${error.runtimeType}); name=$name.',
      );
      return UserSecretOutcome.failure(
        UserSecretFailure(
          UserSecretFailureCode.vaultUnavailable,
          'The Agent vault could not delete $name.',
        ),
      );
    }
    try {
      _metadata.delete(name);
    } catch (error) {
      // The deletion already happened in the vault, which is authoritative.
      _logger.warning(
        'Deleted user secret without removing its metadata '
        '(${error.runtimeType}); name=$name.',
      );
    }
    final deleted = removed.contains(name);
    _logger.info('User secret delete; name=$name, removed=$deleted.');
    return UserSecretOutcome.success(deleted);
  }

  static UserSecretFailure _nameFailure(String rejection, String name) =>
      switch (rejection) {
        'reserved_name' => UserSecretFailure(
          UserSecretFailureCode.reservedSecretName,
          '$name is a protected or Sanad-owned variable name.',
        ),
        _ => UserSecretFailure(
          UserSecretFailureCode.invalidSecretName,
          '$name is not a valid environment variable name.',
        ),
      };
}
