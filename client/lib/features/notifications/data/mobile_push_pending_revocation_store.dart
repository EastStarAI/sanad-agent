import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_pending_revocation.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';

/// The durable record of withdrawals this device still owes the relay.
///
/// A revocation has to survive the process that ended the session, because the
/// socket that should carry it is already torn down when the notification
/// pipeline learns about the logout. The store is the smallest thing that keeps
/// that promise: one entry per token, read back on the next authenticated
/// connection.
abstract class MobilePushPendingRevocationStore {
  /// Every withdrawal still owed, oldest first.
  Future<List<MobilePushPendingRevocation>> read();

  /// Records [record], replacing any entry for the same token.
  Future<void> write(MobilePushPendingRevocation record);

  /// Forgets the entry for [token], normally because the relay acknowledged it.
  Future<void> remove(MobilePushToken token);
}

/// The application-preferences implementation.
///
/// It uses the same app-private store that already holds the account's refresh
/// token, so the pending record introduces no new trust boundary. A corrupted or
/// unreadable entry is discarded rather than allowed to block the next
/// registration; the token value is never logged, and a log line here names the
/// provider and the fingerprint only.
class PreferencesMobilePushPendingRevocationStore
    implements MobilePushPendingRevocationStore {
  PreferencesMobilePushPendingRevocationStore(this._preferences);

  final SharedPreferences _preferences;

  /// The one key that holds the pending withdrawals.
  static const String storageKey = 'notifications_push_pending_revocations';

  /// The most withdrawals one installation can owe at once.
  ///
  /// A provider rotates a token rarely, so this only bounds a pathological run
  /// of failed sessions. The oldest entry is dropped first, which loses a
  /// withdrawal that the relay would have expired on its own long before.
  static const int maxRecords = 8;

  static const String _providerField = 'provider';
  static const String _tokenField = 'token';
  static const String _deviceField = 'device_id';
  static const String _requestedField = 'requested_at';

  static final Logger _logger = Logger('notifications.push.pending');

  @override
  Future<List<MobilePushPendingRevocation>> read() async {
    final raw = _preferences.getString(storageKey);
    if (raw == null || raw.isEmpty) return const <MobilePushPendingRevocation>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      _logger.warning('discarded an unreadable pending revocation store');
      return const <MobilePushPendingRevocation>[];
    }
    if (decoded is! List) return const <MobilePushPendingRevocation>[];
    final records = <MobilePushPendingRevocation>[];
    for (final entry in decoded) {
      final record = _decode(entry);
      if (record != null) records.add(record);
    }
    return records;
  }

  @override
  Future<void> write(MobilePushPendingRevocation record) async {
    final existing = await read();
    final merged = <MobilePushPendingRevocation>[
      for (final item in existing)
        if (item.token != record.token) item,
      record,
    ];
    final bounded = merged.length <= maxRecords
        ? merged
        : merged.sublist(merged.length - maxRecords);
    await _writeAll(bounded);
  }

  @override
  Future<void> remove(MobilePushToken token) async {
    final existing = await read();
    final remaining = existing
        .where((record) => record.token != token)
        .toList(growable: false);
    if (remaining.length == existing.length) return;
    await _writeAll(remaining);
  }

  Future<void> _writeAll(List<MobilePushPendingRevocation> records) async {
    if (records.isEmpty) {
      // Nothing owed: leave no residue behind the session that ended.
      await _preferences.remove(storageKey);
      return;
    }
    await _preferences.setString(
      storageKey,
      jsonEncode(<Map<String, Object?>>[
        for (final record in records) _encode(record),
      ]),
    );
  }

  Map<String, Object?> _encode(MobilePushPendingRevocation record) =>
      <String, Object?>{
        _providerField: record.token.provider.wire,
        _tokenField: record.token.value,
        _deviceField: record.deviceId,
        _requestedField: record.requestedAt.toUtc().toIso8601String(),
      };

  MobilePushPendingRevocation? _decode(Object? entry) {
    if (entry is! Map) return null;
    final provider = MobilePushProvider.fromWire(entry[_providerField]);
    final value = entry[_tokenField];
    if (provider == null || value is! String) return null;
    final token = MobilePushToken(value: value, provider: provider);
    if (!token.isValid) return null;
    final device = entry[_deviceField];
    final requested = entry[_requestedField];
    return MobilePushPendingRevocation(
      token: token,
      deviceId: device is String ? device : '',
      requestedAt: requested is String
          ? (DateTime.tryParse(requested) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}
