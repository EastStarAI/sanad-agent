import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_request_cancelled_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_request_transport.dart';
import 'package:sanad_agent/engine/adapters/provider_watchdog_config.dart';
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

    test('cancellation closes a request-owned client before headers', () async {
      final client = _CloseAwareClient();
      final transport = ProviderRequestTransport(
        options: LLMRequestOptions(cancellationScope: scope),
        requestClient: client,
      );
      final requestExpectation = expectLater(
        transport.send(http.Request('POST', Uri.parse('https://example.com'))),
        throwsA(isA<ProviderRequestCancelledException>()),
      );

      final report = await scope.cancel();

      await requestExpectation;
      expect(client.isClosed, isTrue);
      expect(report.resources, hasLength(1));
      await transport.dispose();
    });

    test('close without request completion reports cleanup timeout', () async {
      final client = _UnstoppableClient();
      final transport = ProviderRequestTransport(
        options: LLMRequestOptions(cancellationScope: scope),
        requestClient: client,
      );
      unawaited(
        transport.send(http.Request('POST', Uri.parse('https://example.com'))),
      );

      final report = await scope.cancel(
        cleanupDeadline: const Duration(milliseconds: 10),
      );

      expect(client.isClosed, isTrue);
      expect(report.finalState, RunCancellationState.cleanupFailed);
      expect(
        report.resources.single.outcome,
        RunCancellationResourceOutcome.timedOut,
      );
      await transport.dispose();
    });

    test('cancellation interrupts an active SSE stream', () async {
      final sourceCancelled = Completer<void>();
      final source = StreamController<List<int>>(
        onCancel: sourceCancelled.complete,
      );
      final transport = ProviderRequestTransport(
        options: LLMRequestOptions(cancellationScope: scope),
      );
      final streamDone = expectLater(
        transport.decodeSseLines(source.stream),
        emitsError(isA<ProviderRequestCancelledException>()),
      );

      await scope.cancel();

      await streamDone;
      await sourceCancelled.future;
      await source.close();
      await transport.dispose();
    });

    test('first-byte watchdog errors and cancels a silent stream', () async {
      final sourceCancelled = Completer<void>();
      final source = StreamController<List<int>>(
        onCancel: sourceCancelled.complete,
      );
      final transport = ProviderRequestTransport(
        options: const LLMRequestOptions(
          watchdogs: ProviderWatchdogConfig(
            firstByteTimeout: Duration(milliseconds: 10),
          ),
        ),
      );

      await expectLater(
        transport.decodeSseLines(source.stream),
        emitsError(isA<TimeoutException>()),
      );

      await sourceCancelled.future;
      await source.close();
      await transport.dispose();
    });

    test('stream-idle watchdog errors after the first byte', () async {
      final sourceCancelled = Completer<void>();
      final source = StreamController<List<int>>(
        onCancel: sourceCancelled.complete,
      );
      final transport = ProviderRequestTransport(
        options: const LLMRequestOptions(
          watchdogs: ProviderWatchdogConfig(
            firstByteTimeout: Duration(seconds: 1),
            streamIdleTimeout: Duration(milliseconds: 10),
          ),
        ),
      );

      final expectation = expectLater(
        transport.decodeSseLines(source.stream),
        emitsInOrder(['data: one', emitsError(isA<TimeoutException>())]),
      );
      source.add('data: one\n'.codeUnits);

      await expectation;
      await sourceCancelled.future;
      await source.close();
      await transport.dispose();
    });

    test('optional total watchdog spans an active stream', () async {
      final sourceCancelled = Completer<void>();
      final source = StreamController<List<int>>(
        onCancel: sourceCancelled.complete,
      );
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => source.add('data: keepalive\n'.codeUnits),
      );
      final transport = ProviderRequestTransport(
        options: const LLMRequestOptions(
          watchdogs: ProviderWatchdogConfig(
            firstByteTimeout: Duration(seconds: 1),
            streamIdleTimeout: Duration(seconds: 1),
            totalTimeout: Duration(milliseconds: 30),
          ),
        ),
      );

      await expectLater(
        transport.decodeSseLines(source.stream).drain<void>(),
        throwsA(isA<TimeoutException>()),
      );

      timer.cancel();
      await sourceCancelled.future;
      await source.close();
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

      final report = await scopeA.cancel();

      expect(transportA.isCancelled, isTrue);
      expect(transportB.isCancelled, isFalse);
      expect(report.resources, hasLength(1));
      expect(
        report.resources.single.outcome,
        RunCancellationResourceOutcome.cancelled,
      );
      await transportA.dispose();
      await transportB.dispose();
    });
  });
}

class _CloseAwareClient extends http.BaseClient {
  final Completer<void> _closed = Completer<void>();

  bool get isClosed => _closed.isCompleted;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await _closed.future;
    throw http.ClientException('request client closed', request.url);
  }

  @override
  void close() {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }
}

class _UnstoppableClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _response =
      Completer<http.StreamedResponse>();
  bool isClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _response.future;

  @override
  void close() {
    isClosed = true;
  }
}
