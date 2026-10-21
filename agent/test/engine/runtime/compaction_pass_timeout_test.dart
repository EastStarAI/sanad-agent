import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_request_transport.dart';
import 'package:sanad_agent/engine/adapters/provider_watchdog_config.dart';
import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:test/test.dart';

/// Task 118 item 1: a non-streamed compaction pass waits for its whole
/// response under the configured compaction pass timeout, not under the
/// normal-turn `connectTimeout` (90 s), which capped slow-model summary and
/// recovery passes in Task 117's live acceptance.
void main() {
  const route = RouteSignature(
    providerInstanceId: 'provider-test',
    templateId: 'openai',
    protocol: 'openai_compatible',
    normalizedBaseUrl: 'https://api.example.com/v1',
    modelId: 'gpt-4o',
    configRevision: 1,
    credentialRevision: 1,
  );

  late Directory home;

  setUp(() {
    getIt.reset();
    home = Directory.systemTemp.createTempSync('compaction_pass_timeout_');
    setSanadHomeOverride(home.path);
  });

  tearDown(() {
    getIt.reset();
    setSanadHomeOverride(null);
    home.deleteSync(recursive: true);
  });

  test('normal-turn watchdog defaults stay unchanged', () {
    expect(
      ProviderWatchdogConfig.defaults.connectTimeout,
      const Duration(seconds: 90),
    );
    expect(
      ProviderWatchdogConfig.defaults.firstByteTimeout,
      const Duration(seconds: 120),
    );
    expect(
      ProviderWatchdogConfig.defaults.streamIdleTimeout,
      const Duration(seconds: 120),
    );
  });

  test('compaction options use the central default pass timeout', () {
    final options = CompactionRequestFactory.buildCompactionRequestOptions(
      sessionId: 's',
      compactionId: 'cmp',
      routeSignature: route,
    );
    expect(
      options.watchdogs.connectTimeout,
      greaterThan(ProviderWatchdogConfig.defaults.connectTimeout),
      reason: 'a 60-71 s pass on a slow model must not be cut at 90 s',
    );
  });

  test('compaction options keep other normal-turn watchdog fields', () {
    const base = LLMRequestOptions(
      watchdogs: ProviderWatchdogConfig(
        connectTimeout: Duration(seconds: 45),
        firstByteTimeout: Duration(seconds: 33),
        streamIdleTimeout: Duration(seconds: 34),
      ),
    );
    final options = CompactionRequestFactory.buildCompactionRequestOptions(
      sessionId: 's',
      compactionId: 'cmp',
      routeSignature: route,
      baseOptions: base,
    );
    expect(options.watchdogs.firstByteTimeout, const Duration(seconds: 33));
    expect(options.watchdogs.streamIdleTimeout, const Duration(seconds: 34));
    expect(
      base.watchdogs.connectTimeout,
      const Duration(seconds: 45),
      reason: 'the normal-turn options object is never mutated',
    );
  });

  test('config.yaml compaction.passTimeoutSeconds drives the pass timeout', () {
    File('${home.path}/config.yaml').writeAsStringSync('''
compaction:
  passTimeoutSeconds: 420
''');
    getIt.registerSingleton<Config>(Config(environment: const {}));

    final options = CompactionRequestFactory.buildCompactionRequestOptions(
      sessionId: 's',
      compactionId: 'cmp',
      routeSignature: route,
      baseOptions: const LLMRequestOptions(),
    );
    expect(options.watchdogs.connectTimeout, const Duration(seconds: 420));
  });

  test('config.yaml rejects a non-positive or fractional pass timeout', () {
    for (final value in ['0', '-5', '1.5', '"slow"']) {
      File(
        '${home.path}/config.yaml',
      ).writeAsStringSync('compaction:\n  passTimeoutSeconds: $value\n');
      expect(
        () => Config(environment: const {}),
        throwsA(isA<FormatException>()),
        reason: value,
      );
    }
  });

  test('a slow non-streamed pass completes under the compaction timeout but '
      'times out under the normal-turn watchdog', () async {
    http.Client slowClient() => MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      return http.Response('{"ok":true}', 200);
    });
    final normalTurn = LLMRequestOptions(
      watchdogs: const ProviderWatchdogConfig(
        connectTimeout: Duration(milliseconds: 20),
      ),
      requestClientFactory: slowClient,
    );

    final normalTransport = ProviderRequestTransport(options: normalTurn);
    await expectLater(
      normalTransport.post(
        Uri.parse('https://api.example.com/v1/chat/completions'),
        headers: const {},
        body: '{}',
      ),
      throwsA(isA<TimeoutException>()),
    );
    await normalTransport.dispose();

    final compactionOptions =
        CompactionRequestFactory.buildCompactionRequestOptions(
          sessionId: 's',
          compactionId: 'cmp',
          routeSignature: route,
          baseOptions: normalTurn,
        );
    final compactionTransport = ProviderRequestTransport(
      options: compactionOptions,
    );
    final response = await compactionTransport.post(
      Uri.parse('https://api.example.com/v1/chat/completions'),
      headers: const {},
      body: '{}',
    );
    expect(response.statusCode, 200);
    await compactionTransport.dispose();
  });
}
