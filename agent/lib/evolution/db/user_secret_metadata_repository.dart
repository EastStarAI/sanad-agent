import 'package:sqlite3/sqlite3.dart';

import 'agent_state_database.dart';

/// How the **current** value of a stored user secret arrived (Task 140 M5).
///
/// The value itself never reaches this owner: it moves from the client into
/// the Agent vault and stays there. This enum records only the path that wrote
/// the value that is stored now, so the Settings screen can label a row as
/// "Added by you" or "Requested by the agent".
enum UserSecretSource {
  /// Stored through the Task 84 acquisition card (`system_request_secret`).
  agentRequest,

  /// Stored or replaced through the Settings → Privacy & Security command.
  user;

  /// The value stored in `user_secret_metadata.source`.
  String get wireName => switch (this) {
    UserSecretSource.agentRequest => 'agent_request',
    UserSecretSource.user => 'user',
  };

  /// Parses a stored value.
  ///
  /// An unrecognized value reads as [agentRequest]: a row must never claim the
  /// device owner typed a value in when no recorded path says so.
  static UserSecretSource fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final source in values) {
      if (source.wireName == normalized) return source;
    }
    return agentRequest;
  }
}

/// One `user_secret_metadata` row: everything the Settings list displays about
/// a stored secret (Task 140 M1, K2).
///
/// There is deliberately no value field. The three displayed fields are the
/// name (the vault identity), the user-authored description, and the arrival
/// source with its two timestamps.
class UserSecretMetadata {
  const UserSecretMetadata({
    required this.name,
    required this.description,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The vault name; the only identity of a user secret.
  final String name;

  /// User-authored, bounded and normalized; `null` when the user cleared it.
  final String? description;

  /// How the currently stored value arrived.
  final UserSecretSource source;

  /// UTC instant the metadata row was first written.
  final DateTime createdAt;

  /// UTC instant the stored value last changed; `createdAt` when never
  /// replaced.
  final DateTime updatedAt;

  UserSecretMetadata copyWith({
    String? description,
    UserSecretSource? source,
    DateTime? updatedAt,
  }) => UserSecretMetadata(
    name: name,
    description: description,
    source: source ?? this.source,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// The non-secret projection every caller and the wire see (M4).
  ///
  /// Structurally value-free: it lists the five allowed fields explicitly, so a
  /// later addition to this class cannot reach a response by accident.
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'source': source.wireName,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory UserSecretMetadata.fromRow(Map<String, dynamic> row) {
    final rawCreatedAt = row['created_at']?.toString();
    final rawUpdatedAt = row['updated_at']?.toString();
    if (rawCreatedAt == null || rawUpdatedAt == null) {
      throw const FormatException(
        'user_secret_metadata requires created_at and updated_at',
      );
    }
    return UserSecretMetadata(
      name: row['name'] as String,
      description: _blankToNull(row['description']),
      source: UserSecretSource.fromWire(row['source']),
      createdAt: DateTime.parse(rawCreatedAt).toUtc(),
      updatedAt: DateTime.parse(rawUpdatedAt).toUtc(),
    );
  }

  static String? _blankToNull(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}

/// Persistent storage for `user_secret_metadata` (Task 140 A1).
///
/// Owns every read and write of the table; no other owner issues SQL against
/// it. The table schema lives in `schema/user_secrets_schema.dart`, and the
/// only callers above this repository are `UserSecretCatalog` and the Task 84
/// acquisition path, which record a name, a description, and an arrival source
/// — never a value.
class UserSecretMetadataRepository {
  UserSecretMetadataRepository(this._state);

  final AgentStateDatabase _state;

  Database get _db => _state.db;

  /// Upper bound for a stored description (Task 140 A1).
  ///
  /// The same bound the protocol validates and the Settings field enforces, so
  /// a description that reached the database cannot be one the screen would
  /// refuse to display.
  static const int maxDescriptionLength = 256;

  /// Every metadata row, ordered by name.
  ///
  /// An empty table, a missing table, and an unreadable row are not failures:
  /// the vault is the source of truth for which secrets exist, so a metadata
  /// read only enriches it.
  List<UserSecretMetadata> list() {
    final rows = _db.select(
      'SELECT * FROM user_secret_metadata ORDER BY name ASC',
    );
    return [
      for (final row in rows)
        _decode(Map<String, dynamic>.from(row)),
    ];
  }

  /// One row, or `null` when the secret has no metadata yet.
  UserSecretMetadata? find(String name) {
    final rows = _db.select(
      'SELECT * FROM user_secret_metadata WHERE name = ? LIMIT 1',
      [name],
    );
    return rows.isEmpty ? null : _decode(Map<String, dynamic>.from(rows.first));
  }

  /// Records that a value arrived for [name] at [at].
  ///
  /// The row is created when absent and updated in place otherwise:
  /// `created_at` is written once, `updated_at` always advances, and [source]
  /// describes the value that is stored now (M5). [description] is
  /// authoritative — passing `null` or a blank string clears the stored
  /// description, which is how the Replace dialog removes one.
  UserSecretMetadata recordValue({
    required String name,
    required String? description,
    required UserSecretSource source,
    DateTime? at,
  }) {
    final instant = _normalize(at ?? DateTime.now());
    final normalized = normalizeDescription(description);
    final existing = find(name);
    if (existing == null) {
      _db.execute(
        'INSERT INTO user_secret_metadata '
        '(name, description, source, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [name, normalized, source.wireName, instant, instant],
      );
    } else {
      _db.execute(
        'UPDATE user_secret_metadata '
        'SET description = ?, source = ?, updated_at = ? WHERE name = ?',
        [normalized, source.wireName, instant, name],
      );
    }
    return find(name)!;
  }

  /// Removes the metadata row of [name]; returns whether a row existed.
  bool delete(String name) {
    _db.execute('DELETE FROM user_secret_metadata WHERE name = ?', [name]);
    return _db.updatedRows > 0;
  }

  /// Removes every row whose name is not in [names], and returns the pruned
  /// names.
  ///
  /// Called by `UserSecretCatalog.list()` so a row cannot outlive its vault
  /// entry after a deletion that happened elsewhere (the model's
  /// `system_delete_secret`, a vault entry removed outside this Agent). The
  /// vault remains the authority for which secrets exist.
  List<String> pruneExcept(Set<String> names) {
    final orphans = [
      for (final row in list())
        if (!names.contains(row.name)) row.name,
    ];
    if (orphans.isEmpty) return const [];
    final placeholders = List.filled(orphans.length, '?').join(', ');
    _db.execute(
      'DELETE FROM user_secret_metadata WHERE name IN ($placeholders)',
      orphans,
    );
    return orphans;
  }

  /// Trims [description], collapses nothing else, and treats an empty or
  /// whitespace-only value as absent.
  ///
  /// Returns the stored form, or throws [ArgumentError] when it exceeds
  /// [maxDescriptionLength].
  static String? normalizeDescription(String? description) {
    final trimmed = description?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length > maxDescriptionLength) {
      throw ArgumentError.value(
        description,
        'description',
        'a secret description is at most $maxDescriptionLength characters',
      );
    }
    return trimmed;
  }

  static String _normalize(DateTime value) => value.toUtc().toIso8601String();

  static UserSecretMetadata _decode(Map<String, dynamic> row) =>
      UserSecretMetadata.fromRow(row);
}
