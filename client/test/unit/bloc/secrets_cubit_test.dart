import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/secrets_client.dart';
import 'package:sanad_client/features/settings/presentation/bloc/secrets_cubit.dart';

typedef _SetCall = ({String name, String value, String? description});

/// A scripted [SecretsClient]: it records the calls it receives, can hold a call
/// open to exercise single-flight admission, and can fail like the real client.
class _FakeSecretsClient implements SecretsClient {
  final listCalls = <DeviceConfig>[];
  final setCalls = <_SetCall>[];
  final deleteCalls = <String>[];
  final changesController = StreamController<void>.broadcast();

  List<StoredSecret> secrets = const [];
  SecretsException? listError;
  SecretsException? setError;
  SecretsException? deleteError;
  SecretDeletionStatus deleteStatus = SecretDeletionStatus.deleted;
  Completer<void>? listGate;
  Completer<void>? setGate;
  Completer<void>? deleteGate;

  @override
  Future<StoredSecretsSnapshot> list(DeviceConfig device) async {
    listCalls.add(device);
    await listGate?.future;
    final error = listError;
    if (error != null) throw error;
    return StoredSecretsSnapshot(secrets: secrets);
  }

  @override
  Future<StoredSecret> set(
    DeviceConfig device, {
    required String name,
    required String value,
    String? description,
  }) async {
    setCalls.add((name: name, value: value, description: description));
    await setGate?.future;
    final error = setError;
    if (error != null) throw error;
    return StoredSecret(
      name: name,
      description: description,
      source: SecretSource.user,
      createdAt: DateTime.utc(2026, 10, 23, 8, 12),
      updatedAt: DateTime.utc(2026, 10, 23, 9, 40, 11),
    );
  }

  @override
  Future<SecretDeletionStatus> delete(DeviceConfig device, String name) async {
    deleteCalls.add(name);
    await deleteGate?.future;
    final error = deleteError;
    if (error != null) throw error;
    return deleteStatus;
  }

  @override
  Stream<void> changes(DeviceConfig device) => changesController.stream;
}

StoredSecret _secret(String name, {String? description = 'Staging database password'}) => StoredSecret(
  name: name,
  description: description,
  source: SecretSource.user,
  createdAt: DateTime.utc(2026, 10, 23, 8, 12),
  updatedAt: DateTime.utc(2026, 10, 23, 9, 40, 11),
);

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const canary = 'canary-value-140-03-9f3a';

  late _FakeSecretsClient client;
  late DeviceConfig? device;
  late SecretsCubit cubit;
  late List<SecretsState> emitted;

  SecretsCubit build() {
    final instance = SecretsCubit(client: client, device: () => device);
    emitted = <SecretsState>[];
    instance.stream.listen(emitted.add);
    return instance;
  }

  /// Every state this cubit ever emitted, plus the current one, formatted the
  /// way a log line or a JSON dump would.
  List<String> dumps() => [
    for (final state in [...emitted, cubit.state])
      '${state.toString()}|${state.secrets.map((secret) => secret.toJson()).toList()}'
          '|${state.secrets.map((secret) => secret.toString()).toList()}'
          '|${state.failure}',
  ];

  setUp(() {
    client = _FakeSecretsClient();
    device = DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: true);
    cubit = build();
  });

  tearDown(() async {
    if (!cubit.isClosed) await cubit.close();
    await client.changesController.close();
  });

  group('load', () {
    test('issues no request before load is called', () async {
      await _settle();
      expect(client.listCalls, isEmpty);
      expect(cubit.state.status, SecretsStatus.initial);
    });

    test('reports loading, then empty for a device without secrets', () async {
      final future = cubit.load();
      expect(cubit.state.status, SecretsStatus.loading);
      await future;
      await _settle();

      expect(emitted.map((state) => state.status), [SecretsStatus.loading, SecretsStatus.empty]);
      expect(cubit.state.secrets, isEmpty);
      expect(cubit.state.isEmpty, isTrue);
      expect(cubit.state.showsList, isFalse);
    });

    test('projects the stored metadata as the loaded list', () async {
      client.secrets = [_secret('DATABASE_PASSWORD'), _secret('STRIPE_KEY', description: null)];

      await cubit.load();

      expect(cubit.state.status, SecretsStatus.loaded);
      expect(cubit.state.showsList, isTrue);
      expect(cubit.state.secrets.map((secret) => secret.name), ['DATABASE_PASSWORD', 'STRIPE_KEY']);
      expect(cubit.state.secrets.last.hasDescription, isFalse);
    });

    test('keeps the rows visible while re-reading an already loaded list', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();

      final gate = Completer<void>();
      client.listGate = gate;
      final future = cubit.load();

      expect(cubit.state.status, SecretsStatus.loaded);
      expect(cubit.state.refreshing, isTrue);
      expect(cubit.state.showsList, isTrue);

      client.listGate = null;
      gate.complete();
      await future;
      expect(cubit.state.refreshing, isFalse);
    });

    test('an offline device short-circuits before any request', () async {
      device!.isOnline = false;

      await cubit.load();

      expect(client.listCalls, isEmpty);
      expect(cubit.state.status, SecretsStatus.deviceUnavailable);
      expect(cubit.state.secrets, isEmpty);
    });

    test('a missing device scope short-circuits before any request', () async {
      device = null;

      await cubit.load();

      expect(client.listCalls, isEmpty);
      expect(cubit.state.status, SecretsStatus.deviceUnavailable);
    });

    test('a typed failure becomes the error state and drops the stale rows', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();

      client.listError = const SecretsException(SecretsErrorCode.invalidRequest);
      await cubit.load();

      expect(cubit.state.status, SecretsStatus.error);
      expect(cubit.state.secrets, isEmpty);
      expect(cubit.state.showsList, isFalse);
      expect(cubit.state.failure?.code, SecretsErrorCode.invalidRequest);
    });

    test('a transport failure becomes the unavailable state', () async {
      client.listError = const SecretsException(SecretsErrorCode.deviceUnavailable);

      await cubit.load();

      expect(cubit.state.status, SecretsStatus.deviceUnavailable);
      expect(cubit.state.failure?.code, SecretsErrorCode.deviceUnavailable);
    });

    test('a retry after a failure reaches the loaded state', () async {
      client.listError = const SecretsException(SecretsErrorCode.vaultUnavailable);
      await cubit.load();
      expect(cubit.state.status, SecretsStatus.error);

      client.listError = null;
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();

      expect(cubit.state.status, SecretsStatus.loaded);
      expect(cubit.state.failure, isNull);
    });
  });

  group('single-flight', () {
    test('a second load joins the in-flight one and queues at most one re-read', () async {
      final gate = Completer<void>();
      client.listGate = gate;

      final first = cubit.load();
      final second = cubit.load();
      expect(identical(first, second), isTrue);
      expect(client.listCalls, hasLength(1));

      final third = cubit.load();
      expect(identical(first, third), isTrue);
      expect(client.listCalls, hasLength(1));

      client.listGate = null;
      gate.complete();
      await first;
      await _settle();

      // One running read plus exactly one queued follow-up, never three.
      expect(client.listCalls, hasLength(2));
    });

    test('a second mutation is rejected with busy and sends nothing', () async {
      final gate = Completer<void>();
      client.setGate = gate;

      final first = cubit.set(name: 'DATABASE_PASSWORD', value: canary);
      final second = await cubit.set(name: 'OTHER_KEY', value: canary);
      expect(second, SecretsActionOutcome.busy);
      expect(client.setCalls, hasLength(1));
      expect(cubit.state.mutationInFlight, isTrue);

      client.setGate = null;
      gate.complete();
      expect(await first, SecretsActionOutcome.success);
      expect(cubit.state.mutationInFlight, isFalse);
    });

    test('a second delete is rejected with busy and sends nothing', () async {
      final gate = Completer<void>();
      client.deleteGate = gate;

      final first = cubit.delete('DATABASE_PASSWORD');
      expect(await cubit.delete('OTHER_KEY'), SecretsActionOutcome.busy);
      expect(client.deleteCalls, ['DATABASE_PASSWORD']);

      client.deleteGate = null;
      gate.complete();
      expect(await first, SecretsActionOutcome.success);
    });
  });

  group('no value is retained', () {
    test('a successful set sends the value once and keeps it out of every state', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();
      emitted.clear();

      client.secrets = [_secret('DATABASE_PASSWORD')];
      expect(await cubit.set(name: 'DATABASE_PASSWORD', value: canary), SecretsActionOutcome.success);

      expect(client.setCalls.single.value, canary);
      expect(cubit.state.status, SecretsStatus.loaded);
      for (final dump in dumps()) {
        expect(dump, isNot(contains(canary)));
      }
    });

    test('a failed set keeps the list, reports the typed code, and keeps the value out of state', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();
      emitted.clear();

      client.setError = const SecretsException(SecretsErrorCode.invalidSecretValue, name: 'DATABASE_PASSWORD');
      expect(
        await cubit.set(name: 'DATABASE_PASSWORD', value: canary, description: 'rotated'),
        SecretsActionOutcome.failed,
      );

      expect(cubit.state.status, SecretsStatus.loaded);
      expect(cubit.state.secrets.map((secret) => secret.name), ['DATABASE_PASSWORD']);
      expect(cubit.state.failure?.code, SecretsErrorCode.invalidSecretValue);
      expect(cubit.state.failure?.name, 'DATABASE_PASSWORD');
      expect(cubit.state.mutationInFlight, isFalse);
      for (final dump in dumps()) {
        expect(dump, isNot(contains(canary)));
      }
    });

    test('the value never appears in a formatted exception', () async {
      client.setError = const SecretsException(SecretsErrorCode.unknown, name: 'DATABASE_PASSWORD', wireCode: 'future');
      await cubit.set(name: 'DATABASE_PASSWORD', value: canary);
      expect(client.setError.toString(), isNot(contains(canary)));
      for (final dump in dumps()) {
        expect(dump, isNot(contains(canary)));
      }
    });
  });

  group('mutations', () {
    test('a successful set re-reads the authoritative list', () async {
      await cubit.load();
      final before = client.listCalls.length;

      client.secrets = [_secret('DATABASE_PASSWORD')];
      expect(await cubit.set(name: 'DATABASE_PASSWORD', value: canary), SecretsActionOutcome.success);

      expect(client.listCalls.length, before + 1);
      expect(cubit.state.secrets.single.name, 'DATABASE_PASSWORD');
    });

    test('a successful delete re-reads the list', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();
      final before = client.listCalls.length;

      client.secrets = const [];
      expect(await cubit.delete('DATABASE_PASSWORD'), SecretsActionOutcome.success);

      expect(client.deleteCalls, ['DATABASE_PASSWORD']);
      expect(client.listCalls.length, before + 1);
      expect(cubit.state.status, SecretsStatus.empty);
    });

    test('a delete for an unknown name reports not_found without re-reading', () async {
      await cubit.load();
      final before = client.listCalls.length;

      client.deleteStatus = SecretDeletionStatus.notFound;
      expect(await cubit.delete('MISSING'), SecretsActionOutcome.notFound);

      expect(client.listCalls.length, before);
    });

    test('a transport failure during a set clears the rows', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();

      client.setError = const SecretsException(SecretsErrorCode.deviceUnavailable);
      expect(await cubit.set(name: 'DATABASE_PASSWORD', value: canary), SecretsActionOutcome.deviceUnavailable);

      expect(cubit.state.status, SecretsStatus.deviceUnavailable);
      expect(cubit.state.secrets, isEmpty);
    });

    test('an offline device refuses a set and a delete before any request', () async {
      device!.isOnline = false;

      expect(await cubit.set(name: 'DATABASE_PASSWORD', value: canary), SecretsActionOutcome.deviceUnavailable);
      expect(await cubit.delete('DATABASE_PASSWORD'), SecretsActionOutcome.deviceUnavailable);

      expect(client.setCalls, isEmpty);
      expect(client.deleteCalls, isEmpty);
      expect(cubit.state.status, SecretsStatus.deviceUnavailable);
    });
  });

  group('secrets.changed', () {
    test('refreshes through the cubit and never trusts the event as the list', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();
      expect(client.listCalls, hasLength(1));

      client.secrets = [_secret('DATABASE_PASSWORD'), _secret('SECOND_KEY')];
      client.changesController.add(null);
      await _settle();

      expect(client.listCalls, hasLength(2));
      expect(cubit.state.secrets.map((secret) => secret.name), ['DATABASE_PASSWORD', 'SECOND_KEY']);
    });

    test('a burst of broadcasts coalesces into one follow-up read', () async {
      final gate = Completer<void>();
      client.listGate = gate;
      final first = cubit.load();

      client.changesController.add(null);
      client.changesController.add(null);
      client.changesController.add(null);
      await _settle();
      expect(client.listCalls, hasLength(1));

      client.listGate = null;
      gate.complete();
      await first;
      await _settle();

      expect(client.listCalls, hasLength(2));
    });

    test('a closed cubit stops following the broadcast', () async {
      await cubit.load();
      final before = client.listCalls.length;

      await cubit.close();
      client.changesController.add(null);
      await _settle();

      expect(client.listCalls.length, before);
    });
  });

  group('device scope', () {
    test('markDeviceUnavailable drops a loaded list without a request', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await cubit.load();
      final before = client.listCalls.length;

      cubit.markDeviceUnavailable();

      expect(client.listCalls.length, before);
      expect(cubit.state.status, SecretsStatus.deviceUnavailable);
      expect(cubit.state.secrets, isEmpty);
      expect(cubit.state.showsList, isFalse);
    });

    test('reports the device that was resolved at call time', () async {
      final other = DeviceConfig(id: 'device-2', name: 'Desktop', hardwareId: 'hw-2', isOnline: true);
      await cubit.load();
      device = other;
      await cubit.load();

      expect(client.listCalls.map((entry) => entry.id), ['device-1', 'device-2']);
    });

    test('an offline transition invalidates a read that is still in flight', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      final gate = Completer<void>();
      client.listGate = gate;
      final pending = cubit.load();

      cubit.markDeviceUnavailable();
      client.listGate = null;
      gate.complete();
      await pending;
      await _settle();

      expect(cubit.state.status, SecretsStatus.deviceUnavailable);
      expect(cubit.state.secrets, isEmpty);
    });

    test('a scope change discards the answer for the previous device', () async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      final gate = Completer<void>();
      client.listGate = gate;
      final pending = cubit.load();

      device = DeviceConfig(id: 'device-2', name: 'Desktop', hardwareId: 'hw-2', isOnline: true);
      client.listGate = null;
      gate.complete();
      await pending;
      await _settle();

      expect(cubit.state.secrets, isEmpty);
      expect(cubit.state.status, SecretsStatus.loading);
    });
  });
}
