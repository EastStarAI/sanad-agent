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
      _ownsClient = false;
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
          () => dispose(cancelled: true),
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
    }
  }

  Future<http.StreamedResponse> send(
    http.Request request, {
    String operation = 'generateStream',
  }) async {
    throwIfCancelled(operation: operation);
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
    }
  }

  Stream<String> decodeSseLines(
    Stream<List<int>> byteStream, {
    String operation = 'generateStream',
  }) {
    throwIfCancelled(operation: operation);
    final idleTimeout = _watchdogs.streamIdleTimeout;
    return byteStream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(
          idleTimeout,
          onTimeout: (sink) => sink.close(),
        );
  }

  Future<void> dispose({bool cancelled = false, bool releaseRegistration = true}) async {
    if (_disposed) return;
    _disposed = true;
    _cancelled = _cancelled || cancelled;
    if (_ownsClient) {
      _client.close();
    }
    if (releaseRegistration) {
      _registration?.release();
      _registration = null;
    }
  }

  Duration _effectiveTimeout(Duration fallback) {
    final total = _options.timeout ?? _watchdogs.totalTimeout;
    if (total == null) return fallback;
    return total < fallback ? total : fallback;
  }
}
