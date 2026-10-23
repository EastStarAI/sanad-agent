import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/secrets_client.dart';

/// Records the wire shape and returns a scripted response or throwable.
class _RecordingCommands implements DeviceCommandClient {
  final requests = <Map<String, Object?>>[];
  final broadcasts = StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic> response = const {};
  Object? error;

  List<String> get commands => [for (final request in requests) request['command']! as String];

  @override
  Stream<Map<String, dynamic>> events(DeviceConfig device) => broadcasts.stream;

  @override
  Future<Map<String, dynamic>> request({
    required DeviceConfig device,
    required String command,
    required String expectedEvent,
    Set<String>? acceptedEvents,
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 10),
    bool Function(Map<String, dynamic> payload)? payloadMatches,
  }) async {
    requests.add({'command': command, 'expected': expectedEvent, ...payload});
    final thrown = error;
    if (thrown != null) throw thrown;
    return response;
  }
}

void main() {
  const canary = 'canary-value-140-03-9f3a';

  final device = DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: true);

  Map<String, dynamic> entryJson({String name = 'DATABASE_PASSWORD', Object? extra}) => {
    'name': name,
    'description': 'Staging database password',
    'source': 'user',
    'created_at': '2026-10-23T08:12:00.000Z',
    'updated_at': '2026-10-23T09:40:11.000Z',
    if (extra is Map) ...extra,
  };

  group('SecretsClient.list', () {
    test('sends secrets.list and projects the non-secret metadata', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'secrets': [entryJson()],
          'truncated': false,
        };

      final snapshot = await SecretsClient(commands).list(device);

      expect(commands.requests.single, {
        'command': 'secrets.list',
        'expected': 'secrets.list_result',
      });
      expect(snapshot.truncated, isFalse);
      final entry = snapshot.secrets.single;
      expect(entry.name, 'DATABASE_PASSWORD');
      expect(entry.description, 'Staging database password');
      expect(entry.source, SecretSource.user);
      expect(entry.createdAt, DateTime.utc(2026, 10, 23, 8, 12));
      expect(entry.updatedAt, DateTime.utc(2026, 10, 23, 9, 40, 11));
    });

    test('an unexpected value field cannot reach the model or a formatted string', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-1',
          'secrets': [
            entryJson(extra: {'value': canary}),
          ],
        };

      final entry = (await SecretsClient(commands).list(device)).secrets.single;

      expect(entry.toJson().keys, ['name', 'description', 'source', 'created_at', 'updated_at']);
      expect(entry.toJson().toString(), isNot(contains(canary)));
      expect(entry.toString(), isNot(contains(canary)));
    });

    test('an unknown source reads as an agent request, never as a user entry', () async {
      final commands = _RecordingCommands()
        ..response = {
          'secrets': [
            entryJson(extra: {'source': 'something_new'}),
          ],
        };

      final entry = (await SecretsClient(commands).list(device)).secrets.single;
      expect(entry.source, SecretSource.agentRequest);
    });

    test('a malformed entry does not crash the list', () async {
      final commands = _RecordingCommands()
        ..response = {
          'secrets': [
            {'name': 'A', 'updated_at': 'not-a-date'},
            'ignored',
          ],
        };

      final snapshot = await SecretsClient(commands).list(device);
      expect(snapshot.secrets.single.name, 'A');
      expect(snapshot.secrets.single.updatedAt, isNull);
    });
  });

  group('SecretsClient.set', () {
    test('sends the value once and returns metadata only', () async {
      final commands = _RecordingCommands()
        ..response = {
          'request_id': 'req-2',
          ...entryJson(),
        };

      final saved = await SecretsClient(commands).set(
        device,
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Staging database password',
      );

      expect(commands.requests.single, {
        'command': 'secret.set',
        'expected': 'secret.saved',
        'name': 'DATABASE_PASSWORD',
        'value': canary,
        'description': 'Staging database password',
      });
      expect(saved.toJson().toString(), isNot(contains(canary)));
      expect(saved.toString(), isNot(contains(canary)));
      expect(saved.toJson().containsKey('value'), isFalse);
    });

    test('omits an absent description so the Agent keeps the stored one', () async {
      final commands = _RecordingCommands()..response = entryJson();
      await SecretsClient(commands).set(device, name: 'DATABASE_PASSWORD', value: canary);
      expect(commands.requests.single.containsKey('description'), isFalse);
    });

    test('refuses an empty, oversized, or sentinel value before any request', () async {
      final commands = _RecordingCommands();
      final client = SecretsClient(commands);

      for (final value in ['', 'x' * (SecretsClient.maxValueLength + 1), '[REDACTED:DATABASE_PASSWORD]']) {
        await expectLater(
          client.set(device, name: 'DATABASE_PASSWORD', value: value),
          throwsA(
            isA<SecretsException>().having((error) => error.code, 'code', SecretsErrorCode.invalidSecretValue),
          ),
        );
      }
      expect(commands.requests, isEmpty);
    });

    test('refuses an oversized description before any request', () async {
      final commands = _RecordingCommands();
      await expectLater(
        SecretsClient(commands).set(
          device,
          name: 'DATABASE_PASSWORD',
          value: canary,
          description: 'x' * (SecretsClient.maxDescriptionLength + 1),
        ),
        throwsA(isA<SecretsException>().having((error) => error.code, 'code', SecretsErrorCode.invalidRequest)),
      );
      expect(commands.requests, isEmpty);
    });
  });

  group('SecretsClient.delete', () {
    test('always sends confirm: true', () async {
      final commands = _RecordingCommands()..response = {'name': 'DATABASE_PASSWORD', 'status': 'deleted'};
      await SecretsClient(commands).delete(device, 'DATABASE_PASSWORD');
      expect(commands.requests.single, {
        'command': 'secret.delete',
        'expected': 'secret.deleted',
        'name': 'DATABASE_PASSWORD',
        'confirm': true,
      });
    });

    test('maps the reported status', () async {
      final commands = _RecordingCommands()..response = {'status': 'deleted'};
      expect(await SecretsClient(commands).delete(device, 'A'), SecretDeletionStatus.deleted);

      commands.response = {'status': 'not_found'};
      expect(await SecretsClient(commands).delete(device, 'A'), SecretDeletionStatus.notFound);
    });
  });

  group('error mapping', () {
    const wireToTyped = {
      'permission_denied': SecretsErrorCode.permissionDenied,
      'invalid_request': SecretsErrorCode.invalidRequest,
      'invalid_secret_name': SecretsErrorCode.invalidSecretName,
      'reserved_secret_name': SecretsErrorCode.reservedSecretName,
      'invalid_secret_value': SecretsErrorCode.invalidSecretValue,
      'vault_unavailable': SecretsErrorCode.vaultUnavailable,
      'internal_error': SecretsErrorCode.internalError,
    };

    for (final entry in wireToTyped.entries) {
      test('maps ${entry.key} to ${entry.value.name} without carrying Agent text', () async {
        final commands = _RecordingCommands()
          ..error = DeviceCommandException(
            'Agent text that mentions $canary',
            code: entry.key,
            command: 'secrets.list',
          );

        await expectLater(
          SecretsClient(commands).list(device),
          throwsA(
            isA<SecretsException>()
                .having((error) => error.code, 'code', entry.value)
                .having((error) => error.name, 'name', isNull)
                .having((error) => error.wireCode, 'wireCode', isNull)
                .having((error) => error.toString(), 'toString', isNot(contains(canary)))
                .having((error) => error.toString(), 'toString', isNot(contains('Agent text'))),
          ),
        );
      });
    }

    test('keeps an unmapped protocol code as a wire token', () async {
      final commands = _RecordingCommands()
        ..error = DeviceCommandException('nope', code: 'future_code', command: 'secrets.list');

      await expectLater(
        SecretsClient(commands).list(device),
        throwsA(
          isA<SecretsException>()
              .having((error) => error.code, 'code', SecretsErrorCode.unknown)
              .having((error) => error.wireCode, 'wireCode', 'future_code'),
        ),
      );
    });

    test('maps a missing code and a transport failure to typed codes', () async {
      final commands = _RecordingCommands()..error = DeviceCommandException('no code');
      await expectLater(
        SecretsClient(commands).list(device),
        throwsA(isA<SecretsException>().having((error) => error.code, 'code', SecretsErrorCode.unknown)),
      );

      commands.error = StateError('Device Laptop is not connected.');
      await expectLater(
        SecretsClient(commands).list(device),
        throwsA(isA<SecretsException>().having((error) => error.code, 'code', SecretsErrorCode.deviceUnavailable)),
      );

      commands.error = TimeoutException('slow');
      await expectLater(
        SecretsClient(commands).delete(device, 'A'),
        throwsA(
          isA<SecretsException>()
              .having((error) => error.code, 'code', SecretsErrorCode.deviceUnavailable)
              .having((error) => error.name, 'name', 'A'),
        ),
      );
    });
  });

  group('SecretsClient.changes', () {
    test('yields only secrets.changed, with no payload projected', () async {
      final commands = _RecordingCommands();
      final seen = <void>[];
      final subscription = SecretsClient(commands).changes(device).listen(seen.add);

      commands.broadcasts
        ..add({
          'event': 'secrets.list_result',
          'payload': {'secrets': []},
        })
        ..add({
          'event': 'secrets.changed',
          'payload': {'name': 'DATABASE_PASSWORD', 'change': 'set'},
        })
        ..add({
          'event': 'secrets.changed',
          'payload': {'name': 'OTHER', 'change': 'deleted'},
        });
      await pumpEventQueue();
      await subscription.cancel();

      expect(seen, hasLength(2));
    });
  });

  group('name format', () {
    test('accepts the Agent grammar and rejects everything else', () {
      expect(SecretsClient.isValidNameFormat('DATABASE_PASSWORD'), isTrue);
      expect(SecretsClient.isValidNameFormat('_private1'), isTrue);
      expect(SecretsClient.isValidNameFormat('a'), isTrue);
      expect(SecretsClient.isValidNameFormat(''), isFalse);
      expect(SecretsClient.isValidNameFormat('1LEADING_DIGIT'), isFalse);
      expect(SecretsClient.isValidNameFormat('WITH-DASH'), isFalse);
      expect(SecretsClient.isValidNameFormat('x' * 65), isFalse);
      expect(SecretsClient.isValidNameFormat('x' * 64), isTrue);
    });
  });
}
