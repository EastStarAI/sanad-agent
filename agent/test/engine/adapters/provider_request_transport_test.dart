import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_request_cancelled_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_request_transport.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderRequestTransport', () {
    late RunCancellationScope scope;

    setUp(() {
      scope = RunCancellationScope(
        sessionId: 'session-1',
        runId: 'run-1',
        workItemId: 'work-1',
        generation: 1,
      );
    });

    test('rejects requests after scope invalidation', () async {
      scope.invalidate();
      final transport = ProviderRequestTransport(
        options: LLMRequestOptions(cancellationScope: scope),
        requestClient: MockClient((_) async => http.Response('{}', 200)),
      );

      await expectLater(
        transport.post(
          Uri.parse('https://example.com'),
          headers: const {},
          body: '{}',
        ),
        throwsA(isA<ProviderRequestCancelledException>()),
      );
      await transport.dispose();
    });

    test('stops SSE line decoding after cancellation', () async {
      scope.invalidate();
      final transport = ProviderRequestTransport(
        options: LLMRequestOptions(cancellationScope: scope),
      );

      expect(
        () => transport.decodeSseLines(Stream<List<int>>.empty()),
        throwsA(isA<ProviderRequestCancelledException>()),
      );
      await transport.dispose();
    });

    test('parallel scopes invalidate independently', () async {
      final scopeA = RunCancellationScope(
        sessionId: 's',
        runId: 'run-a',
        workItemId: 'w-a',
        generation: 1,
      );
      final scopeB = RunCancellationScope(
        sessionId: 's',
        runId: 'run-b',
        workItemId: 'w-b',
        generation: 2,
      );
      final transportA = ProviderRequestTransport(
        options: LLMRequestOptions(cancellationScope: scopeA),
      );
      final transportB = ProviderRequestTransport(
        options: LLMRequestOptions(cancellationScope: scopeB),
      );

      await scopeA.cancel();

      expect(transportA.isCancelled, isTrue);
      expect(transportB.isCancelled, isFalse);
      await transportA.dispose();
      await transportB.dispose();
    });
  });
}
