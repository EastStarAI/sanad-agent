import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/message.dart';

/// Authoritative history-identity helpers for `messages` rows.
///
/// SQL columns own query, pagination, and activity. Message metadata mirrors
/// the same fields so in-memory [Message] values survive JSON round-trips.
class MessageHistoryIdentity {
  static const String active = 'active';
  static const String superseded = 'superseded';
  static const String rootTurn = 'root_turn';
  static const String steer = 'steer';

  static const _uuid = Uuid();

  final String messageId;
  final String turnId;
  final String historyStatus;
  final String? inputKind;
  final String? requestId;
  final String? runId;
  final String? supersededByTurnId;
  final String? originMessageId;
  final bool replayEligible;

  const MessageHistoryIdentity({
    required this.messageId,
    required this.turnId,
    required this.historyStatus,
    required this.inputKind,
    required this.requestId,
    required this.runId,
    required this.supersededByTurnId,
    this.originMessageId,
    required this.replayEligible,
  });

  static bool isSteer(Message message) {
    final metadata = message.metadata;
    if (metadata == null) return false;
    if (metadata['input_kind']?.toString() == steer) return true;
    return metadata['steer'] == true;
  }

  static bool isRootUser(Message message) {
    return message.role == MessageRole.user && !isSteer(message);
  }

  /// True when this record is a delivered steer or carries embedded
  /// `steer_messages` reconstructed from tool-result metadata.
  static bool containsTurnSteers(Message message) {
    if (isSteer(message)) return true;
    final raw = message.metadata?['steer_messages'];
    if (raw is! List) return false;
    return raw.any((entry) => entry is Map);
  }

  static String? requestIdOf(Message message) {
    final raw = message.metadata?['request_id']?.toString().trim();
    return raw == null || raw.isEmpty ? null : raw;
  }

  static String? runIdOf(Message message) {
    final raw = message.metadata?['run_id']?.toString().trim();
    return raw == null || raw.isEmpty ? null : raw;
  }

  static MessageHistoryIdentity read(Message message) {
    final metadata = message.metadata ?? const <String, dynamic>{};
    final inputKind = isRootUser(message)
        ? rootTurn
        : (isSteer(message) ? steer : metadata['input_kind']?.toString());
    final requestId = requestIdOf(message);
    return MessageHistoryIdentity(
      messageId: metadata['message_id']?.toString() ?? '',
      turnId: metadata['turn_id']?.toString() ?? '',
      historyStatus: metadata['history_status']?.toString() ?? active,
      inputKind: inputKind,
      requestId: requestId,
      runId: runIdOf(message),
      supersededByTurnId: metadata['superseded_by_turn_id']?.toString(),
      originMessageId: _nonEmpty(metadata['origin_message_id']),
      replayEligible:
          message.role == MessageRole.user &&
          inputKind == rootTurn &&
          requestId != null,
    );
  }

  static Map<String, dynamic> wireFields(Message message) {
    final identity = read(message);
    return {
      if (identity.messageId.isNotEmpty) 'message_id': identity.messageId,
      if (identity.turnId.isNotEmpty) 'turn_id': identity.turnId,
      if (identity.inputKind != null) 'input_kind': identity.inputKind,
      'history_status': identity.historyStatus,
      'replay_eligible': identity.replayEligible,
    };
  }

  static List<Message> assignIdentities(
    List<Message> messages, {
    List<MessageHistoryIdentity> existingActive = const [],
  }) {
    String? currentTurnId;
    return [
      for (var index = 0; index < messages.length; index++)
        _assignOne(
          _reuseExisting(messages[index], index, existingActive),
          currentTurnId,
          (turnId) {
            currentTurnId = turnId;
          },
        ),
    ];
  }

  static Message _reuseExisting(
    Message message,
    int index,
    List<MessageHistoryIdentity> existingActive,
  ) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    if (_nonEmpty(metadata['message_id']) != null ||
        index >= existingActive.length) {
      return message;
    }
    final existing = existingActive[index];
    metadata['message_id'] = existing.messageId;
    metadata['turn_id'] = _nonEmpty(metadata['turn_id']) ?? existing.turnId;
    metadata['history_status'] =
        _nonEmpty(metadata['history_status']) ?? existing.historyStatus;
    if (existing.inputKind != null) {
      metadata['input_kind'] =
          _nonEmpty(metadata['input_kind']) ?? existing.inputKind;
    }
    return message.copyWith(metadata: metadata);
  }

  static Message markSuperseded(Message message, {String? byTurnId}) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    metadata['history_status'] = superseded;
    if (byTurnId != null && byTurnId.isNotEmpty) {
      metadata['superseded_by_turn_id'] = byTurnId;
    }
    metadata['replay_eligible'] = false;
    return message.copyWith(metadata: metadata);
  }

  static Message overlayFromRow(Message message, Row row) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    void put(String key, Object? value) {
      if (value == null) return;
      final text = value.toString();
      if (text.isEmpty) return;
      metadata[key] = text;
    }

    put('message_id', row['message_id']);
    put('turn_id', row['turn_id']);
    put('history_status', row['history_status']);
    put('input_kind', row['input_kind']);
    put('request_id', row['request_id']);
    put('run_id', row['run_id']);
    put('superseded_by_turn_id', row['superseded_by_turn_id']);
    put('origin_message_id', row['origin_message_id']);
    final identity = read(message.copyWith(metadata: metadata));
    metadata['replay_eligible'] = identity.replayEligible;
    if (identity.inputKind != null) {
      metadata['input_kind'] = identity.inputKind;
    }
    return message.copyWith(metadata: metadata);
  }

  static Message fromRow(Row row) {
    final decoded = jsonDecode(row['data'] as String);
    if (decoded is! Map) {
      throw FormatException('Message row data must be a JSON object');
    }
    final json = _promoteLegacyTimestamp(Map<String, dynamic>.from(decoded));
    return overlayFromRow(Message.fromJson(json), row);
  }

  /// Writes one history row, generating identity when missing.
  ///
  /// Existing rows match by [sqliteId] or `message_id`. The physical `id`
  /// cursor is preserved on update so pagination keys stay stable.
  static Message persist(
    Database db,
    String sessionId,
    Message message, {
    int? sqliteId,
  }) {
    final prepared = _ensureForWrite(db, sessionId, message);
    final identity = read(prepared);
    final encoded = jsonEncode(prepared.toJson());
    final values = [
      encoded,
      identity.messageId,
      identity.turnId,
      identity.historyStatus,
      identity.supersededByTurnId,
      identity.inputKind,
      identity.requestId,
      identity.runId,
      identity.originMessageId,
    ];
    if (sqliteId != null) {
      db.execute(
        '''
        UPDATE messages
        SET data = ?, message_id = ?, turn_id = ?, history_status = ?,
            superseded_by_turn_id = ?, input_kind = ?, request_id = ?,
            run_id = ?, origin_message_id = ?
        WHERE id = ? AND session_id = ?
        ''',
        [...values, sqliteId, sessionId],
      );
      return prepared;
    }
    final existing = db.select(
      '''
      SELECT id FROM messages
      WHERE session_id = ? AND message_id = ?
      LIMIT 1
      ''',
      [sessionId, identity.messageId],
    );
    if (existing.isNotEmpty) {
      db.execute(
        '''
        UPDATE messages
        SET data = ?, message_id = ?, turn_id = ?, history_status = ?,
            superseded_by_turn_id = ?, input_kind = ?, request_id = ?,
            run_id = ?, origin_message_id = ?
        WHERE session_id = ? AND message_id = ?
        ''',
        [...values, sessionId, identity.messageId],
      );
      return prepared;
    }
    db.execute(
      '''
      INSERT INTO messages (
        session_id, data, message_id, turn_id, history_status,
        superseded_by_turn_id, input_kind, request_id, run_id,
        origin_message_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [sessionId, ...values],
    );
    return prepared;
  }

  static Message _assignOne(
    Message message,
    String? currentTurnId,
    void Function(String turnId) onTurn,
  ) {
    final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
    final existingTurn = metadata['turn_id']?.toString();
    final String turnId;
    if (existingTurn != null && existingTurn.isNotEmpty) {
      turnId = existingTurn;
    } else if (isRootUser(message) || currentTurnId == null) {
      turnId = _uuid.v4();
    } else {
      turnId = currentTurnId;
    }
    onTurn(turnId);
    metadata['message_id'] = _nonEmpty(metadata['message_id']) ?? _uuid.v4();
    metadata['turn_id'] = turnId;
    metadata['history_status'] =
        _nonEmpty(metadata['history_status']) ?? active;
    final origin = _nonEmpty(metadata['origin_message_id']);
    if (origin != null) {
      metadata['origin_message_id'] = origin;
    }
    if (isRootUser(message)) {
      metadata['input_kind'] = rootTurn;
    } else if (isSteer(message)) {
      metadata['input_kind'] = steer;
    }
    final stamped = _stampSteerMessages(
      message.copyWith(metadata: metadata),
      turnId,
    );
    final identity = read(stamped);
    final nextMetadata = Map<String, dynamic>.from(
      stamped.metadata ?? const {},
    );
    nextMetadata['replay_eligible'] = identity.replayEligible;
    if (identity.inputKind != null) {
      nextMetadata['input_kind'] = identity.inputKind;
    }
    return stamped.copyWith(metadata: nextMetadata);
  }

  static Message _ensureForWrite(
    Database db,
    String sessionId,
    Message message,
  ) {
    final metadata = message.metadata ?? const <String, dynamic>{};
    if (_nonEmpty(metadata['message_id']) != null &&
        _nonEmpty(metadata['turn_id']) != null) {
      return _assignOne(message, metadata['turn_id']?.toString(), (_) {});
    }
    String? currentTurnId = _nonEmpty(metadata['turn_id']);
    if (currentTurnId == null && !isRootUser(message)) {
      final last = db.select(
        '''
        SELECT turn_id FROM messages
        WHERE session_id = ? AND history_status = ?
        ORDER BY id DESC LIMIT 1
        ''',
        [sessionId, active],
      );
      if (last.isNotEmpty) {
        currentTurnId = last.first['turn_id'] as String?;
      }
    }
    return _assignOne(message, currentTurnId, (_) {});
  }

  static Message _stampSteerMessages(Message message, String turnId) {
    final metadata = message.metadata;
    final raw = metadata?['steer_messages'];
    if (raw is! List) return message;
    final stamped = [
      for (final entry in raw)
        if (entry is Map)
          {
            ...Map<String, dynamic>.from(entry),
            'message_id': _nonEmpty(entry['message_id']) ?? _uuid.v4(),
            'turn_id': _nonEmpty(entry['turn_id']) ?? turnId,
            'input_kind': steer,
            'history_status': active,
            'replay_eligible': false,
          }
        else
          entry,
    ];
    return message.copyWith(
      metadata: {...metadata!, 'steer_messages': stamped},
    );
  }

  static Map<String, dynamic> _promoteLegacyTimestamp(
    Map<String, dynamic> json,
  ) {
    final metadata = Map<String, dynamic>.from(
      json['metadata'] is Map
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : const {},
    );
    if (_nonEmpty(metadata['received_at']) == null &&
        _nonEmpty(json['timestamp']) != null) {
      metadata['received_at'] = json['timestamp'];
      json = {...json, 'metadata': metadata};
    }
    return json;
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }
}
