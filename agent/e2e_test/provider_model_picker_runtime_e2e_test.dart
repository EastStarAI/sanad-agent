import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

void main() {
  final port = int.tryParse(
    Platform.environment['SANAD_E2E_GATEWAY_PORT'] ??
        Platform.environment['SANAD_LOCAL_GATEWAY_PORT'] ??
        '',
  );
  final sanadHomePath = Platform.environment['SANAD_E2E_SANAD_HOME']?.trim();

  test(
    'real runtime snapshot covers all configured provider instances and returns normalized model ids',
    () async {
      if (port == null || sanadHomePath == null || sanadHomePath.isEmpty) {
        markTestSkipped(
          'Set SANAD_E2E_GATEWAY_PORT and SANAD_E2E_SANAD_HOME for the isolated '
          'running local gateway before executing this E2E test.',
        );
        return;
      }

      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: sanadHomePath,
      );
      addTearDown(() async {
        await socket.close();
      });

      final frames = StreamIterator(socket);
      final registerSuccess = await _nextDeviceFrame(frames);
      expect(registerSuccess['type'], equals('register_success'));

      final instancesPayload = await _request(
        socket,
        frames,
        command: 'provider.instances.list',
        expectedEvent: 'provider.instances.result',
      );
      final instances =
          (instancesPayload['instances'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>();
      expect(instances, isNotEmpty, reason: 'Expected configured providers.');

      final instanceById = {
        for (final instance in instances)
          instance['id']!.toString(): _RuntimeInstance.fromJson(instance),
      };

      final initialSnapshot = await _request(
        socket,
        frames,
        command: 'model.snapshot',
        expectedEvent: 'model.snapshot_result',
      );
      final initialIds = _snapshotIds(initialSnapshot);
      expect(
        initialIds,
        containsAll(instanceById.keys),
        reason:
            'Every configured provider instance must appear in model.snapshot.',
      );

      for (final instance in instanceById.values) {
        await _refreshInstance(socket, frames, instance.id);
      }

      final refreshedSnapshot = await _request(
        socket,
        frames,
        command: 'model.snapshot',
        expectedEvent: 'model.snapshot_result',
      );
      final snapshotInstances =
          (refreshedSnapshot['instances'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>();
      final diagnostics = <String>[];

      for (final snapshot in snapshotInstances) {
        final id = snapshot['id']!.toString();
        final runtimeInstance = instanceById[id];
        expect(runtimeInstance, isNotNull, reason: 'Unknown snapshot id: $id');

        final status = snapshot['status']?.toString() ?? 'draft';
        final models = (snapshot['models'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>();
        diagnostics.add(
          '${runtimeInstance!.displayName} '
          '[${runtimeInstance.templateId}/${runtimeInstance.protocol}] '
          '@ ${runtimeInstance.baseUrl.isEmpty ? '<default>' : runtimeInstance.baseUrl} '
          '-> ${models.length} models',
        );

        if (status == 'ready') {
          expect(
            models,
            isNotEmpty,
            reason:
                'Ready provider ${runtimeInstance.displayName} should have models after refresh.',
          );
        }

        for (final model in models) {
          final rawId = (model['value'] ?? '').toString();
          expect(rawId, isNotEmpty, reason: 'Model id must not be empty.');
          expect(
            _hasRedundantProviderPrefix(rawId, runtimeInstance.templateId),
            isFalse,
            reason:
                'Model "$rawId" for ${runtimeInstance.displayName} still contains an extra provider prefix.',
          );
          expect(
            rawId.startsWith('models/'),
            isFalse,
            reason:
                'Model "$rawId" for ${runtimeInstance.displayName} still contains the Gemini API "models/" path prefix.',
          );
        }

        final defaultModel = snapshot['default_model']?.toString();
        if (defaultModel != null && defaultModel.isNotEmpty) {
          expect(
            _hasRedundantProviderPrefix(
              defaultModel,
              runtimeInstance.templateId,
            ),
            isFalse,
            reason:
                'Default model "$defaultModel" for ${runtimeInstance.displayName} still contains an extra provider prefix.',
          );
          expect(
            defaultModel.startsWith('models/'),
            isFalse,
            reason:
                'Default model "$defaultModel" for ${runtimeInstance.displayName} still contains the Gemini API "models/" prefix.',
          );
        }

        if (status == 'ready' && runtimeInstance.templateId == 'openai-codex') {
          expect(
            models.length,
            greaterThanOrEqualTo(5),
            reason:
                'ChatGPT Plus should expose a real GPT catalog, not a single fallback model.',
          );
        }

        if (status == 'ready' &&
            runtimeInstance.baseUrl.startsWith('http://localhost:9000') &&
            runtimeInstance.protocol == 'openai_compatible') {
          expect(
            models.length,
            greaterThan(1),
            reason:
                'Local OpenAI-compatible provider at localhost:9000 should resolve multiple models '
                '(detects /models vs /v1/models regressions).',
          );
        }

        if (status == 'ready' &&
            runtimeInstance.baseUrl.startsWith('http://localhost:9000') &&
            runtimeInstance.protocol == 'anthropic_compatible') {
          expect(
            models.length,
            greaterThan(1),
            reason:
                'Local Anthropic-compatible provider at localhost:9000 should resolve multiple models, '
                'not just the selected default fallback.',
          );
        }
      }

      for (final line in diagnostics) {
        print(line);
      }

      final geminiInstances = snapshotInstances.where((snapshot) {
        final runtime = instanceById[snapshot['id']!.toString()];
        return runtime?.templateId == 'gemini';
      }).toList();
      expect(
        geminiInstances,
        isNotEmpty,
        reason:
            'This runtime is expected to have at least one Gemini provider.',
      );
      for (final snapshot in geminiInstances) {
        final models = (snapshot['models'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>();
        expect(
          models,
          isNotEmpty,
          reason: 'Gemini provider should return live models after refresh.',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<Map<String, dynamic>> _request(
  WebSocket socket,
  StreamIterator<dynamic> frames, {
  required String command,
  required String expectedEvent,
  Map<String, dynamic> payload = const {},
}) async {
  final requestId = 'req-${DateTime.now().microsecondsSinceEpoch}';
  socket.add(
    jsonEncode({
      'type': 'execute_command',
      'command': command,
      'payload': {'request_id': requestId, ...payload},
    }),
  );

  while (true) {
    final frame = await _nextDeviceFrame(frames);
    if (frame['event'] != expectedEvent) {
      continue;
    }
    final frameRequestId =
        frame['request_id']?.toString() ??
        (frame['payload'] as Map<String, dynamic>?)?['request_id']?.toString();
    if (frameRequestId == requestId) {
      return (frame['payload'] as Map).cast<String, dynamic>();
    }
  }
}

Future<void> _refreshInstance(
  WebSocket socket,
  StreamIterator<dynamic> frames,
  String providerInstanceId,
) async {
  final requestId = 'req-refresh-${DateTime.now().microsecondsSinceEpoch}';
  socket.add(
    jsonEncode({
      'type': 'execute_command',
      'command': 'model.refresh',
      'payload': {
        'request_id': requestId,
        'provider_instance_id': providerInstanceId,
        'manual': true,
      },
    }),
  );

  while (true) {
    final frame = await _nextDeviceFrame(frames);
    if (frame['event'] != 'model.cache_updated') {
      continue;
    }
    final payload = (frame['payload'] as Map).cast<String, dynamic>();
    final frameRequestId =
        frame['request_id']?.toString() ?? payload['request_id']?.toString();
    if (frameRequestId != requestId) {
      continue;
    }
    final status = payload['status']?.toString();
    if (status == 'updated') {
      return;
    }
    if (status == 'failed') {
      fail(
        'Model refresh failed for instance $providerInstanceId: '
        '${payload['error'] ?? payload['message'] ?? payload}',
      );
    }
  }
}

Future<Map<String, dynamic>> _nextDeviceFrame(
  StreamIterator<dynamic> frames,
) async {
  final hasFrame = await frames.moveNext().timeout(const Duration(seconds: 15));
  if (!hasFrame) {
    throw StateError('Expected websocket frame but stream ended.');
  }
  return (jsonDecode(frames.current as String) as Map).cast<String, dynamic>();
}

Set<String> _snapshotIds(Map<String, dynamic> payload) {
  final instances = (payload['instances'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>();
  return instances.map((instance) => instance['id']!.toString()).toSet();
}

bool _hasRedundantProviderPrefix(String modelId, String templateId) {
  if (templateId.isEmpty) return false;
  final prefix = '$templateId/';
  return modelId.startsWith(prefix);
}

class _RuntimeInstance {
  final String id;
  final String templateId;
  final String displayName;
  final String protocol;
  final String baseUrl;

  const _RuntimeInstance({
    required this.id,
    required this.templateId,
    required this.displayName,
    required this.protocol,
    required this.baseUrl,
  });

  factory _RuntimeInstance.fromJson(Map<String, dynamic> json) {
    return _RuntimeInstance(
      id: json['id']!.toString(),
      templateId: (json['template_id'] ?? '').toString(),
      displayName: (json['display_name'] ?? '').toString(),
      protocol: (json['protocol'] ?? '').toString(),
      baseUrl: (json['base_url'] ?? '').toString(),
    );
  }
}
