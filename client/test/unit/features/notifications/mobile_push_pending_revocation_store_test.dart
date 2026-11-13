import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanad_client/features/notifications/data/mobile_push_pending_revocation_store.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_pending_revocation.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';

MobilePushToken _token(int suffix, {MobilePushProvider provider = MobilePushProvider.apns}) =>
    MobilePushToken(
      value: 'provider-token-000000000000$suffix',
      provider: provider,
    );

MobilePushPendingRevocation _record(
  MobilePushToken token, {
  String deviceId = 'device-1',
  DateTime? requestedAt,
}) =>
    MobilePushPendingRevocation(
      token: token,
      deviceId: deviceId,
      requestedAt: requestedAt ?? DateTime.utc(2026, 11, 13, 12),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  late PreferencesMobilePushPendingRevocationStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await SharedPreferences.getInstance();
    store = PreferencesMobilePushPendingRevocationStore(preferences);
  });

  group('PreferencesMobilePushPendingRevocationStore', () {
    test('an empty store owes nothing', () async {
      expect(await store.read(), isEmpty);
    });

    test('a record survives a new store instance', () async {
      final token = _token(1);
      await store.write(_record(token, deviceId: 'device-7'));

      final reopened = PreferencesMobilePushPendingRevocationStore(
        await SharedPreferences.getInstance(),
      );
      final records = await reopened.read();

      expect(records.single.token, token);
      expect(records.single.deviceId, 'device-7');
      expect(records.single.requestedAt, DateTime.utc(2026, 11, 13, 12));
    });

    test('writing the same token twice keeps one record', () async {
      final token = _token(1);
      await store.write(_record(token));
      await store.write(_record(token, deviceId: 'device-2'));

      final records = await store.read();
      expect(records, hasLength(1));
      expect(records.single.deviceId, 'device-2');
    });

    test('removing the last record leaves no residue behind', () async {
      final token = _token(1);
      await store.write(_record(token));
      await store.remove(token);

      expect(await store.read(), isEmpty);
      expect(preferences.getString(PreferencesMobilePushPendingRevocationStore.storageKey), isNull);
    });

    test('removing one token keeps the others', () async {
      final first = _token(1);
      final second = _token(2, provider: MobilePushProvider.fcm);
      await store.write(_record(first));
      await store.write(_record(second));

      await store.remove(first);

      final records = await store.read();
      expect(records.single.token, second);
    });

    test('an unreadable store is discarded instead of blocking a registration', () async {
      await preferences.setString(
        PreferencesMobilePushPendingRevocationStore.storageKey,
        'not json at all',
      );

      expect(await store.read(), isEmpty);
    });

    test('an entry this build cannot address is dropped', () async {
      await preferences.setString(
        PreferencesMobilePushPendingRevocationStore.storageKey,
        jsonEncode(<Object>[
          <String, Object>{'provider': 'webpush', 'token': 'provider-token-0000000000009'},
          <String, Object>{'provider': 'apns', 'token': 'short'},
          <String, Object>{'provider': 'apns', 'token': _token(3).value},
          'not a map',
        ]),
      );

      final records = await store.read();
      expect(records.single.token, _token(3));
    });

    test('the store is bounded and drops the oldest withdrawal', () async {
      final tokens = <MobilePushToken>[
        for (var index = 0; index < PreferencesMobilePushPendingRevocationStore.maxRecords + 2; index += 1)
          _token(index),
      ];
      for (final token in tokens) {
        await store.write(_record(token));
      }

      final records = await store.read();
      expect(records, hasLength(PreferencesMobilePushPendingRevocationStore.maxRecords));
      expect(records.first.token, tokens[2]);
      expect(records.last.token, tokens.last);
    });

    test('the persisted payload is the only place the value is stored in the clear', () async {
      final token = _token(1);
      await store.write(_record(token));

      final raw = preferences.getString(PreferencesMobilePushPendingRevocationStore.storageKey);
      expect(raw, contains(token.value));
      expect((await store.read()).single.toString(), isNot(contains(token.value)));
    });
  });
}
