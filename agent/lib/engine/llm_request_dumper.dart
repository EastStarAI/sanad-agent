import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../core/sanad_home/sanad_home_bootstrap.dart';
import '../core/models/message.dart';
import '../core/di.dart';
import '../core/config.dart';
import '../core/secrets_redactor.dart';

/// A utility class responsible for dumping LLM request payloads and execution errors
/// to the filesystem during development, controlled by the `DUMP_REQUESTS` environment variable.
class LLMRequestDumper {
  static final Logger _logger = Logger('LLMRequestDumper');

  /// Central secrets redactor — applied to every string value written to disk
  /// so API keys, bearer tokens, and auth headers never appear in dump files.
  static const _redactor = SecretsRedactor();

  /// Internal environment override for unit testing
  static Map<String, String>? environmentOverride;

  /// The path of the last dumped request.
  static String? lastDumpFilePath;

  /// Check if the request dumper is enabled via the `DUMP_REQUESTS` environment variable.
  static bool get isEnabled {
    if (environmentOverride != null) {
      final envVal = environmentOverride!['DUMP_REQUESTS']
          ?.trim()
          .toLowerCase();
      return envVal == 'true' || envVal == '1';
    }

    final sysEnv = Platform.environment['DUMP_REQUESTS']?.trim().toLowerCase();
    if (sysEnv == 'true' || sysEnv == '1') return true;

    try {
      if (getIt.isRegistered<Config>()) {
        return getIt<Config>().dumpRequests;
      }
    } catch (_) {}

    return false;
  }

  /// Check if print to stdout is enabled via the `DUMP_REQUESTS_STDOUT` environment variable.
  static bool get isStdoutEnabled {
    if (environmentOverride != null) {
      final envVal = environmentOverride!['DUMP_REQUESTS_STDOUT']
          ?.trim()
          .toLowerCase();
      return envVal == 'true' || envVal == '1';
    }

    final sysEnv = Platform.environment['DUMP_REQUESTS_STDOUT']
        ?.trim()
        .toLowerCase();
    if (sysEnv == 'true' || sysEnv == '1') return true;

    try {
      if (getIt.isRegistered<Config>()) {
        return getIt<Config>().dumpRequestsStdout;
      }
    } catch (_) {}

    return false;
  }

  /// Dumps the LLM request payload (history and tools) to a file.
  /// If [error] is provided, captures error details.
  static Future<String?> dumpRequest({
    required String sessionId,
    required List<Message> history,
    required List<dynamic> tools,
    String? model,
    String? provider,
    String? baseUrl,
    String? apiKey,
    Map<String, dynamic>? customMetadata,
    Object? error,
  }) async {
    if (!isEnabled) return null;

    try {
      final now = DateTime.now();
      // Format timestamp as YYYYMMDD_HHMMSS_MS to prevent filesystem collisions
      final timestamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}_'
          '${now.millisecond.toString().padLeft(2, '0')}';

      final safeSessionId = sessionId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      final fileName = 'request_dump_${safeSessionId}_$timestamp.json';
      final relativePath = p.join('request_dumps', fileName);
      final boundary = SanadHomeBootstrap.state();

      // Build the raw payload map
      final rawPayload = {
        'timestamp': now.toIso8601String(),
        'session_id': sessionId,
        'model': model,
        'provider': provider,
        'base_url': baseUrl,
        'api_key': _maskApiKey(apiKey),
        'metadata': customMetadata,
        'request': {
          'method': 'POST',
          'url': baseUrl != null
              ? '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions'
              : null,
          'headers': {
            if (apiKey != null)
              'Authorization': 'Bearer ${_maskApiKey(apiKey)}',
            'Content-Type': 'application/json',
          },
          'body': {
            'model': model,
            'messages': history.map((m) => m.toJson()).toList(),
            if (tools.isNotEmpty)
              'tools': tools.map((t) {
                try {
                  return (t as dynamic).toJson();
                } catch (_) {
                  return t;
                }
              }).toList(),
          },
        },
        if (error != null) 'error': _serializeError(error),
      };

      // Recursively sanitize the payload to redact secrets and truncate large base64 strings
      final sanitizedPayload = _sanitizePayload(rawPayload);

      final jsonString = const JsonEncoder.withIndent(
        '  ',
      ).convert(sanitizedPayload);
      await boundary.writeConfigText(relativePath, jsonString);

      _logger.info('LLM request debug dump written.');

      if (isStdoutEnabled) {
        // Print formatted json payload directly to stdout
        stdout.writeln('\n--- DUMP_REQUESTS START ---');
        stdout.writeln(jsonString);
        stdout.writeln('--- DUMP_REQUESTS END ---\n');
      }

      lastDumpFilePath = boundary.child(relativePath);
      return lastDumpFilePath;
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to dump LLM request debug payload: $e',
        e,
        stackTrace,
      );
      return null;
    }
  }

  static Future<void> recordActualRequest({
    required Uri url,
    required Map<String, String> headers,
    Object? body,
  }) async {
    if (!isEnabled) return;
    final path = lastDumpFilePath;
    if (path == null) {
      return;
    }

    try {
      final boundary = SanadHomeBootstrap.state();
      final relativePath = p.join('request_dumps', p.basename(path));
      if (!boundary.fileExists(relativePath)) {
        return;
      }

      final content = utf8.decode(boundary.readSecretBytes(relativePath));
      final Map<String, dynamic> data = jsonDecode(content);
      final request =
          (data['request'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      request['url'] = url.toString();
      request['headers'] = headers;
      if (body != null) {
        request['body'] = body;
      }
      data['request'] = _sanitizePayload(request);

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await boundary.writeConfigText(relativePath, jsonString);
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to update LLM request dump transport: $e',
        e,
        stackTrace,
      );
    }
  }

  static Future<void> recordError(Object error) async {
    if (!isEnabled) return;
    final path = lastDumpFilePath;
    if (path == null) {
      return;
    }

    try {
      final boundary = SanadHomeBootstrap.state();
      final relativePath = p.join('request_dumps', p.basename(path));
      if (!boundary.fileExists(relativePath)) {
        return;
      }

      final content = utf8.decode(boundary.readSecretBytes(relativePath));
      final Map<String, dynamic> data = jsonDecode(content);
      data['error'] = _sanitizePayload(_serializeError(error));
      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await boundary.writeConfigText(relativePath, jsonString);
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to append LLM request error details: $e',
        e,
        stackTrace,
      );
    }
  }

  /// Dumps the response payload to the last request dump file.
  static Future<void> dumpResponse(dynamic responsePayload) async {
    if (!isEnabled) return;
    final path = lastDumpFilePath;
    if (path == null) {
      _logger.warning(
        'Attempted to dump LLM response, but lastDumpFilePath is null.',
      );
      return;
    }

    try {
      final boundary = SanadHomeBootstrap.state();
      final relativePath = p.join('request_dumps', p.basename(path));
      if (!boundary.fileExists(relativePath)) {
        _logger.warning('Request dump file not found.');
        return;
      }

      final content = utf8.decode(boundary.readSecretBytes(relativePath));
      final Map<String, dynamic> data = jsonDecode(content);

      // Add response key with parsed dynamic payload or decoded JSON
      dynamic sanitizedResponse = responsePayload;
      if (responsePayload is String) {
        try {
          sanitizedResponse = jsonDecode(responsePayload);
        } catch (_) {
          // If not valid JSON, keep it as raw string
        }
      }

      data['response'] = _sanitizePayload(sanitizedResponse);

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await boundary.writeConfigText(relativePath, jsonString);

      _logger.info('LLM response added to request dump.');

      if (isStdoutEnabled) {
        stdout.writeln('\n--- DUMP_RESPONSE START ---');
        stdout.writeln(jsonString);
        stdout.writeln('--- DUMP_RESPONSE END ---\n');
      }
    } catch (e, stackTrace) {
      _logger.warning('Failed to dump LLM response: $e', e, stackTrace);
    }
  }

  /// Mask sensitive API keys, keeping only the first 8 and last 4 characters.
  static String? _maskApiKey(String? key) {
    if (key == null || key.isEmpty) return null;
    if (key.length <= 12) return '***';
    return '${key.substring(0, 8)}...${key.substring(key.length - 4)}';
  }

  /// Serialize error objects including custom status code and response body details.
  static Map<String, dynamic> _serializeError(Object error) {
    final Map<String, dynamic> errorMap = {
      'type': error.runtimeType.toString(),
      // Redact the message immediately so secrets never appear in dump files.
      'message': _redactor.redact(error.toString()),
    };

    try {
      final dynamic err = error;
      if (err.statusCode != null) {
        errorMap['status_code'] = err.statusCode;
      }
    } catch (_) {}

    try {
      final dynamic err = error;
      if (err.uri != null) {
        errorMap['uri'] = _redactor.redact(err.uri.toString());
      }
    } catch (_) {}

    try {
      final dynamic err = error;
      if (err.response != null) {
        errorMap['response_status'] = err.response.statusCode;
        errorMap['response_body'] = _redactor.redact(
          err.response.body.toString(),
        );
      }
    } catch (_) {}

    return errorMap;
  }

  /// Recursively traverse the payload to find and sanitize string values
  static dynamic _sanitizePayload(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k, _sanitizePayload(v)));
    } else if (value is List) {
      return value.map(_sanitizePayload).toList();
    } else if (value is String) {
      return _sanitizeString(value);
    }
    return value;
  }

  /// Sanitize a string value: first pass through central SecretsRedactor to
  /// strip API keys / tokens / auth headers, then apply structural transforms
  /// (base64 truncation, legacy prefix masking).
  static String _sanitizeString(String val) {
    // 0. Central redaction — must run first so that patterns like
    //    `api_key: sk-abc...` inside error bodies are caught before any
    //    structural transform might obscure them.
    val = _redactor.redact(val);

    // 1. Truncate Data URI base64 strings (e.g. data:image/png;base64,iVBORw...)
    if (val.startsWith('data:') &&
        val.contains(';base64,') &&
        val.length > 500) {
      final parts = val.split(';base64,');
      if (parts.length == 2) {
        final header = parts[0];
        final base64Sample = parts[1].substring(0, 30);
        return '$header;base64,$base64Sample... [Base64 Data Truncated, Original Size: ${val.length} characters]';
      }
    }

    // 2. Truncate raw base64 blocks (long strings without spaces consisting only of base64 alphabet)
    if (val.length > 1000 && !val.contains(RegExp(r'\s'))) {
      final base64Regex = RegExp(r'^[A-Za-z0-9+/=]+$');
      if (base64Regex.hasMatch(val)) {
        return '${val.substring(0, 50)}... [Raw Base64 Data Truncated, Original Size: ${val.length} characters]';
      }
    }

    // 3. Redact common secret API key structures found inside conversation histories or prompts
    if (val.startsWith('sk-') && val.length > 20) {
      return _maskApiKey(val) ?? val;
    }
    if (val.startsWith('nvapi-') && val.length > 20) {
      return _maskApiKey(val) ?? val;
    }
    if (val.startsWith('Bearer ') && val.length > 30) {
      final token = val.substring(7);
      return 'Bearer ${_maskApiKey(token)}';
    }

    return val;
  }
}
