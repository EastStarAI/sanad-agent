import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../runtime/run_cancellation_scope.dart';
import 'llm_request_options.dart';
import 'provider_request_cancelled_exception.dart';
import 'provider_watchdog_config.dart';

/// Request-owned HTTP transport that registers cleanup on [RunCancellationScope].
class ProviderRequestTransport {
  ProviderRequestTransport({
    required LLMRequestOptions options,
    http.Client? adapterSharedClient,
    http.Client? requestClient,
  }) : _options = options,
       _scope = options.cancellationScope,
       _watchdogs = options.watchdogs {
    if (requestClient != null) {
      _client = requestClient;
      // An explicitly supplied request client is still request-owned when a
      // cancellation scope is present. This keeps test/custom transports as
      // interruptible as the default per-run client.
      _ownsClient = _scope != null;
    } else if (_scope != null) {
      _client = http.Client();
      _ownsClient = true;
    } else if (adapterSharedClient != null) {
      _client = adapterSharedClient;
      _ownsClient = false;
    } else {
      _client = http.Client();
      _ownsClient = true;
    }

    if (_scope != null) {
      if (!_scope.isPublicationOpen) {
        _cancelled = true;
      } else {
        _registration = _scope.register(
          'provider_http_request',
          () => dispose(cancelled: true, releaseRegistration: false),
        );
      }
    }
  }

  final LLMRequestOptions _options;
  final RunCancellationScope? _scope;
  final ProviderWatchdogConfig _watchdogs;
  late final http.Client _client;
  late final bool _ownsClient;
  RunCancellationResourceHandle? _registration;
  bool _cancelled = false;
  bool _disposed = false;
  final Stopwatch _lifetime = Stopwatch()..start();
  final Set<Future<void> Function()> _activeStreamCleanups = {};
  final Set<Completer<void>> _inFlightRequests = {};

  http.Client get client => _client;

  bool get isCancelled =>
      _cancelled || (_scope != null && !_scope.isPublicationOpen);

  void throwIfCancelled({String operation = 'provider_request'}) {
    if (isCancelled) {
      throw ProviderRequestCancelledException(operation: operation);
    }
  }

  Future<http.Response> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
    String operation = 'generateResponse',
  }) async {
    throwIfCancelled(operation: operation);
    final completion = Completer<void>();
    _inFlightRequests.add(completion);
    try {
      return await _client
          .post(url, headers: headers, body: body)
          .timeout(_effectiveTimeout(_watchdogs.connectTimeout));
    } on TimeoutException {
      throw TimeoutException(operation);
    } catch (error) {
      if (isCancelled) {
        throw ProviderRequestCancelledException(operation: operation);
      }
      rethrow;
    } finally {
      if (!completion.isCompleted) completion.complete();
      _inFlightRequests.remove(completion);
    }
  }

  Future<http.StreamedResponse> send(
    http.Request request, {
    String operation = 'generateStream',
  }) async {
    throwIfCancelled(operation: operation);
    final completion = Completer<void>();
    _inFlightRequests.add(completion);
    try {
      return await _client
          .send(request)
          .timeout(_effectiveTimeout(_watchdogs.connectTimeout));
    } on TimeoutException {
      throw TimeoutException(operation);
    } catch (error) {
      if (isCancelled) {
        throw ProviderRequestCancelledException(operation: operation);
      }
      rethrow;
    } finally {
      if (!completion.isCompleted) completion.complete();
      _inFlightRequests.remove(completion);
    }
  }

  Stream<String> decodeSseLines(
    Stream<List<int>> byteStream, {
    String operation = 'generateStream',
  }) {
    throwIfCancelled(operation: operation);
    return _watchByteStream(
      byteStream,
      operation: operation,
    ).transform(utf8.decoder).transform(const LineSplitter());
  }

  Future<void> dispose({
    bool cancelled = false,
    bool releaseRegistration = true,
  }) async {
    if (!_disposed) {
      _disposed = true;
      _cancelled = _cancelled || cancelled;
      _lifetime.stop();
      if (_ownsClient) {
        _client.close();
      }
      if (cancelled) {
        await Future.wait([
          ..._activeStreamCleanups
              .toList(growable: false)
              .map((cleanup) => cleanup()),
          ..._inFlightRequests
              .toList(growable: false)
              .map((completion) => completion.future),
        ]);
      }
    }
    if (releaseRegistration) {
      _registration?.release();
      _registration = null;
    }
  }

  Duration _effectiveTimeout(Duration fallback) {
    final remainingTotal = _remainingTotalTimeout;
    if (remainingTotal == null) return fallback;
    if (remainingTotal <= Duration.zero) return Duration.zero;
    return remainingTotal < fallback ? remainingTotal : fallback;
  }

  Duration? get _remainingTotalTimeout {
    final total = _options.timeout ?? _watchdogs.totalTimeout;
    if (total == null) return null;
    return total - _lifetime.elapsed;
  }

  Stream<List<int>> _watchByteStream(
    Stream<List<int>> source, {
    required String operation,
  }) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? phaseTimer;
    Timer? totalTimer;
    var settled = false;
    late final Future<void> Function() cancelForScope;

    void cancelTimers() {
      phaseTimer?.cancel();
      totalTimer?.cancel();
    }

    Future<void> finishWithError(Object error, [StackTrace? stackTrace]) async {
      if (settled) return;
      settled = true;
      _activeStreamCleanups.remove(cancelForScope);
      cancelTimers();
      controller.addError(error, stackTrace);
      await subscription?.cancel();
      await controller.close();
    }

    void armPhaseTimer(Duration timeout, String phase) {
      phaseTimer?.cancel();
      phaseTimer = Timer(
        timeout,
        () => unawaited(
          finishWithError(
            TimeoutException('$operation $phase timeout', timeout),
          ),
        ),
      );
    }

    cancelForScope = () => finishWithError(
      ProviderRequestCancelledException(operation: operation),
    );

    controller = StreamController<List<int>>(
      onListen: () {
        _activeStreamCleanups.add(cancelForScope);
        if (isCancelled) {
          unawaited(cancelForScope());
          return;
        }

        armPhaseTimer(_watchdogs.firstByteTimeout, 'first-byte');
        final remainingTotal = _remainingTotalTimeout;
        if (remainingTotal != null) {
          totalTimer = Timer(
            remainingTotal <= Duration.zero ? Duration.zero : remainingTotal,
            () => unawaited(
              finishWithError(
                TimeoutException('$operation total timeout', remainingTotal),
              ),
            ),
          );
        }

        subscription = source.listen(
          (chunk) {
            if (settled) return;
            if (isCancelled) {
              unawaited(
                finishWithError(
                  ProviderRequestCancelledException(operation: operation),
                ),
              );
              return;
            }
            if (chunk.isNotEmpty) {
              armPhaseTimer(_watchdogs.streamIdleTimeout, 'stream-idle');
            }
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (settled) return;
            settled = true;
            _activeStreamCleanups.remove(cancelForScope);
            cancelTimers();
            controller.addError(
              isCancelled
                  ? ProviderRequestCancelledException(operation: operation)
                  : error,
              stackTrace,
            );
            unawaited(controller.close());
          },
          onDone: () {
            if (settled) return;
            settled = true;
            _activeStreamCleanups.remove(cancelForScope);
            cancelTimers();
            unawaited(controller.close());
          },
        );

        _scope?.whenCancelled.then((_) {
          if (settled) return;
          unawaited(cancelForScope());
        });
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        if (settled) return;
        settled = true;
        _activeStreamCleanups.remove(cancelForScope);
        cancelTimers();
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }
}
