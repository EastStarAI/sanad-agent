import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:test/test.dart';

/// A credential-shaped value that must never reach a user surface.
const _secret = 'sk-live-abcdefghijklmnop1234567890';

/// The provider body the issue quotes, including the credential echo and the
/// headers the transport keeps.
LlmHttpException _unauthorized() => LlmHttpException.fromResponse(
  http.Response(
    '{"error":{"type":"server_error","message":"Invalid credential for $_secret"}}',
    401,
    headers: {
      'x-api-key': _secret,
      'authorization': 'Bearer $_secret',
    },
  ),
  operation: 'getAvailableModels',
);

Uri _modelsEndpoint() =>
    Uri.parse('https://opencode.ai/zen/go/v1/models');

void main() {
  group('classification', () {
    test('a rejected credential is an auth failure with status and endpoint', () {
      final error = ProviderDiscoveryError.capture(
        _unauthorized(),
        endpoint: _modelsEndpoint(),
      );

      expect(error.kind, ProviderFailureCategory.invalidCredential);
      expect(error.statusCode, 401);
      expect(error.isAuthFailure, isTrue);
      expect(error.message, 'Invalid credential (HTTP 401)');
      expect(
        error.summary,
        'Invalid credential (HTTP 401) from '
        'https://opencode.ai/zen/go/v1/models',
      );
    });

    test('403 is an auth failure too', () {
      final error = ProviderDiscoveryError.capture(
        LlmHttpException.fromResponse(
          http.Response('forbidden', 403),
          operation: 'getAvailableModels',
        ),
      );

      expect(error.kind, ProviderFailureCategory.forbidden);
      expect(error.message, 'Access denied (HTTP 403)');
    });

    test('other HTTP failures keep their own category', () {
      final cases = <int, (String, String)>{
        404: (
          ProviderFailureCategory.endpointNotFound,
          'Models endpoint not found (HTTP 404)',
        ),
        429: (ProviderFailureCategory.rateLimited, 'Rate limited (HTTP 429)'),
        500: (
          ProviderFailureCategory.serverError,
          'Provider server error (HTTP 500)',
        ),
        502: (
          ProviderFailureCategory.serverError,
          'Provider server error (HTTP 502)',
        ),
        418: (
          ProviderFailureCategory.http,
          'Provider rejected the request (HTTP 418)',
        ),
      };
      for (final entry in cases.entries) {
        final error = ProviderDiscoveryError.capture(
          LlmHttpException.fromResponse(
            http.Response('', entry.key),
            operation: 'getAvailableModels',
          ),
        );
        expect(error.kind, entry.value.$1, reason: '${entry.key}');
        expect(error.statusCode, entry.key);
        expect(error.message, entry.value.$2);
        expect(error.isAuthFailure, isFalse);
      }
    });

    test('network and malformed-list failures carry no HTTP status', () {
      final network = ProviderDiscoveryError.capture(
        SocketException('Network disconnected'),
      );
      expect(network.kind, ProviderFailureCategory.network);
      expect(network.statusCode, isNull);
      expect(network.message, 'Could not reach the provider endpoint');

      final timeout = ProviderDiscoveryError.capture(TimeoutException('slow'));
      expect(timeout.kind, ProviderFailureCategory.timeout);
      expect(timeout.message, 'The provider endpoint timed out');

      final empty = ProviderDiscoveryError.capture(
        StateError('Empty model list returned from provider'),
      );
      expect(empty.kind, ProviderFailureCategory.noModels);
      expect(empty.message, 'The provider returned an empty model list');

      final unexpected = ProviderDiscoveryError.capture(
        const FormatException('boom'),
      );
      expect(unexpected.kind, ProviderFailureCategory.noModels);
      expect(
        unexpected.message,
        'The provider returned an unexpected model list',
      );
    });

    test('an unclassified failure degrades to a generic cause', () {
      final error = ProviderDiscoveryError.capture(_SecretCarryingError());
      expect(error.kind, ProviderFailureCategory.unknown);
      expect(error.message, 'The provider request failed');
      expect(error.summary.contains(_secret), isFalse);
    });
  });

  group('sanitization', () {
    test('no surface carries the body, a header, or the credential', () {
      final error = ProviderDiscoveryError.capture(
        _unauthorized(),
        endpoint: _modelsEndpoint(),
      );

      final surfaces = <String>[
        error.message,
        error.summary,
        error.toString(),
        error.toJson(),
        jsonEncode(error.toMap()),
        ...error.toMap().values.map((value) => value.toString()),
      ];
      for (final surface in surfaces) {
        expect(surface, isNot(contains(_secret)), reason: surface);
        expect(
          surface.toLowerCase(),
          isNot(contains('authorization')),
          reason: surface,
        );
        expect(surface, isNot(contains('x-api-key')), reason: surface);
        expect(surface, isNot(contains('server_error')), reason: surface);
        expect(surface, isNot(contains('Invalid credential for')), reason: surface);
      }
    });

    test('the endpoint drops query, fragment, and user info', () {
      final error = ProviderDiscoveryError.capture(
        _unauthorized(),
        endpoint: Uri.parse(
          'https://user:pass@gateway.example:8443/v1/models'
          '?api_key=$_secret&alt=sse#fragment',
        ),
      );

      expect(error.endpoint, 'https://gateway.example:8443/v1/models');
      expect(error.summary.contains(_secret), isFalse);
      expect(error.summary.contains('pass'), isFalse);
    });

    test('an absent endpoint is omitted from the projection', () {
      final error = ProviderDiscoveryError.capture(_unauthorized());
      expect(error.endpoint, isNull);
      expect(error.summary, 'Invalid credential (HTTP 401)');
      expect(error.toMap().containsKey('endpoint'), isFalse);
    });

    test('message length is bounded', () {
      final error = ProviderDiscoveryError.fromMap({
        'kind': ProviderFailureCategory.unknown,
        'message': 'x' * 400,
      });
      expect(error, isNotNull);
      expect(
        error!.message.length,
        lessThanOrEqualTo(ProviderDiscoveryError.maxMessageLength),
      );
    });
  });

  group('storage round trip', () {
    test('the encoded projection restores exactly', () {
      final error = ProviderDiscoveryError.capture(
        _unauthorized(),
        endpoint: _modelsEndpoint(),
      );

      final restored = ProviderDiscoveryError.tryRestore(
        detailJson: error.toJson(),
      );

      expect(restored, isNotNull);
      expect(restored!.kind, error.kind);
      expect(restored.statusCode, error.statusCode);
      expect(restored.message, error.message);
      expect(restored.endpoint, error.endpoint);
      expect(restored.summary, error.summary);
    });

    test('a legacy row is re-derived from its status prefix without the body', () {
      final restored = ProviderDiscoveryError.tryRestore(
        legacyText:
            'LlmHttpException(401 getAvailableModels): '
            '{"error":{"message":"Invalid credential for $_secret"}}',
      );

      expect(restored, isNotNull);
      expect(restored!.kind, ProviderFailureCategory.invalidCredential);
      expect(restored.statusCode, 401);
      expect(restored.summary, 'Invalid credential (HTTP 401)');
      expect(restored.summary.contains(_secret), isFalse);
    });

    test('an unclassifiable legacy row degrades to a generic cause', () {
      final restored = ProviderDiscoveryError.tryRestore(
        legacyText: 'Failed to fetch standard models (fell back to presets).',
      );

      expect(restored, isNotNull);
      expect(restored!.kind, ProviderFailureCategory.unknown);
      expect(restored.message, 'Model discovery failed');
    });

    test('a row without an error restores nothing', () {
      expect(ProviderDiscoveryError.tryRestore(), isNull);
      expect(ProviderDiscoveryError.tryRestore(detailJson: null), isNull);
      expect(
        ProviderDiscoveryError.tryRestore(detailJson: '', legacyText: '   '),
        isNull,
      );
    });

    test('a structured row wins over leftover legacy text', () {
      final error = ProviderDiscoveryError.capture(
        LlmHttpException.fromResponse(
          http.Response('', 429),
          operation: 'getAvailableModels',
        ),
      );

      final restored = ProviderDiscoveryError.tryRestore(
        detailJson: error.toJson(),
        legacyText: 'LlmHttpException(401 getAvailableModels): stale',
      );

      expect(restored!.statusCode, 429);
      expect(restored.kind, ProviderFailureCategory.rateLimited);
    });
  });
}

/// An error whose own text carries a credential, proving the projection never
/// copies arbitrary exception text.
class _SecretCarryingError implements Exception {
  @override
  String toString() => 'Authorization: Bearer $_secret';
}
