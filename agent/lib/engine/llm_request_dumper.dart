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

  /// The path of the last dumped normal-turn request.
  ///
  /// Invariant: Compaction requests NEVER modify or read this path.
  static String? lastDumpFilePath;

  /// Active normal-turn dump file paths keyed by requestId.
  static final Map<String, String> _activeNormalDumps = {};

  /// Active compaction dump file paths keyed by canonical compaction key.
  static final Map<String, String> _activeCompactionDumps = {};

  /// Resets internal dump file tracking state for test isolation.
  static void resetForTesting() {
    lastDumpFilePath = null;
    environmentOverride = null;
    _activeNormalDumps.clear();
    _activeCompactionDumps.clear();
  }

  /// Whether an in-flight request dump is currently tracked in active maps.
  static bool hasActiveDump({String? compactionId, String? requestId}) {
    final key = compactionKey(compactionId: compactionId, requestId: requestId);
    if (key.isNotEmpty && _activeCompactionDumps.containsKey(key)) {
      return true;
    }
    if (requestId != null && _activeNormalDumps.containsKey(requestId)) {
      return true;
    }
    return false;
  }

  /// Returns whether the given parameters identify a compaction request.
  static bool isCompactionRequest({String? compactionId, String? requestId}) {
    if (compactionId != null && compactionId.isNotEmpty) return true;
    if (requestId != null && requestId.startsWith('compaction:')) return true;
    return false;
  }

  /// Builds a canonical compaction key from compactionId and/or requestId.
  ///
  /// Canonical examples:
  /// - compactionId: 'c1', requestId: 'r1' -> 'compaction:c1:r1'
  /// - compactionId: 'c1', requestId: 'compaction:c1:r1' -> 'compaction:c1:r1'
  /// - requestId: 'compaction:c1:r1' -> 'compaction:c1:r1'
  /// - compactionId: 'c1', requestId: null -> 'compaction:c1'
  static String compactionKey({String? compactionId, String? requestId}) {
    if (compactionId != null && compactionId.isNotEmpty) {
      final cleanComp = compactionId.startsWith('compaction:')
          ? compactionId.substring('compaction:'.length)
          : compactionId;
      if (requestId != null && requestId.isNotEmpty) {
        final cleanReq = requestId.startsWith('compaction:')
            ? requestId.substring('compaction:'.length)
            : requestId;
        if (cleanReq == cleanComp || cleanReq.startsWith('$cleanComp:')) {
          return 'compaction:$cleanReq';
        }
        return 'compaction:$cleanComp:$cleanReq';
      }
      return 'compaction:$cleanComp';
    }
    if (requestId != null && requestId.startsWith('compaction:')) {
      return requestId;
    }
    return '';
  }

  /// Extracts a clean compaction ID from a canonical key.
  static String? extractCompactionId(String key) {
    if (!key.startsWith('compaction:')) return null;
    final parts = key.split(':');
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return parts[1];
    }
    return null;
  }

  /// Explicitly cleans up an in-flight compaction mapping if abandoned or cancelled.
  static void cleanupActiveDump({String? compactionId, String? requestId}) {
    final key = compactionKey(compactionId: compactionId, requestId: requestId);
    if (key.isNotEmpty) {
      _activeCompactionDumps.remove(key);
    }
    if (requestId != null && requestId.isNotEmpty) {
      _activeNormalDumps.remove(requestId);
    }
  }

  static String _formatTimestamp(DateTime now) {
    return '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}_'
        '${now.millisecond.toString().padLeft(2, '0')}';
  }

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
  /// Compaction requests are keyed by compactionId:requestId and NEVER touch [lastDumpFilePath].
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
    String? requestId,
    String? compactionId,
  }) async {
    if (!isEnabled) return null;

    try {
      final now = DateTime.now();
      final timestamp = _formatTimestamp(now);
      final isCompaction = isCompactionRequest(
        compactionId: compactionId,
        requestId: requestId,
      );

      final boundary = SanadHomeBootstrap.state();
      final String fileName;
      final String relativePath;
      String? key;

      if (isCompaction) {
        key = compactionKey(compactionId: compactionId, requestId: requestId);
        final safeCompactionKey = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        fileName = 'compaction_dump_${safeCompactionKey}_$timestamp.json';
        relativePath = p.join('request_dumps', fileName);
      } else {
        final safeSessionId = sessionId.replaceAll(
          RegExp(r'[^A-Za-z0-9_-]'),
          '_',
        );
        fileName = 'request_dump_${safeSessionId}_$timestamp.json';
        relativePath = p.join('request_dumps', fileName);
      }

      final rawPayload = <String, dynamic>{
        'timestamp': now.toIso8601String(),
        'session_id': sessionId,
        if (isCompaction) ...{
          'compaction_id': ?(compactionId ?? (key != null ? extractCompactionId(key) : null)),
          'request_id': ?requestId,
        },
        'model': model,
        'provider': provider,
        'base_url': baseUrl,
        'api_key': _maskApiKey(apiKey),
        'metadata': customMetadata,
        'capture_state': 'initialized',
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

      final sanitizedPayload = _sanitizePayload(rawPayload);
      final jsonString = const JsonEncoder.withIndent('  ').convert(sanitizedPayload);
      await boundary.writeConfigText(relativePath, jsonString);

      _logger.info(
        isCompaction
            ? 'Compaction LLM request debug dump written ($key).'
            : 'LLM request debug dump written.',
      );

      if (isStdoutEnabled) {
        stdout.writeln('\n--- DUMP_REQUESTS START ---');
        stdout.writeln(jsonString);
        stdout.writeln('--- DUMP_REQUESTS END ---\n');
      }

      final fullPath = boundary.child(relativePath);
      if (isCompaction) {
        if (key != null && key.isNotEmpty) {
          _activeCompactionDumps[key] = fullPath;
        }
      } else {
        lastDumpFilePath = fullPath;
        if (requestId != null && requestId.isNotEmpty) {
          _activeNormalDumps[requestId] = fullPath;
        }
      }

      return fullPath;
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to dump LLM request debug payload: $e',
        e,
        stackTrace,
      );
      return null;
    }
  }


  static Future<String?> recordActualRequest({
    required Uri url,
    required Map<String, String> headers,
    Object? body,
    String? requestId,
    String? compactionId,
  }) async {
    if (!isEnabled) return null;

    final isCompaction = isCompactionRequest(
      compactionId: compactionId,
      requestId: requestId,
    );

    final boundary = SanadHomeBootstrap.state();
    String? targetPath;
    String? key;

    if (isCompaction) {
      key = compactionKey(compactionId: compactionId, requestId: requestId);
      targetPath = _activeCompactionDumps[key];

      if (targetPath == null) {
        // Auto-create dump file on actual request if no preceding dumpRequest call
        final now = DateTime.now();
        final timestamp = _formatTimestamp(now);
        final safeCompactionKey = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final fileName = 'compaction_dump_${safeCompactionKey}_$timestamp.json';
        final relativePath = p.join('request_dumps', fileName);

        final rawPayload = <String, dynamic>{
          'timestamp': now.toIso8601String(),
          'compaction_id': ?(compactionId ?? extractCompactionId(key)),
          'request_id': ?requestId,
          'capture_state': 'request_sent',
          'request': {
            'method': 'POST',
            'url': url.toString(),
            'headers': headers,
            'body': ?body,
          },
        };

        final sanitizedPayload = _sanitizePayload(rawPayload);
        final jsonString = const JsonEncoder.withIndent('  ').convert(sanitizedPayload);
        await boundary.writeConfigText(relativePath, jsonString);

        targetPath = boundary.child(relativePath);
        _activeCompactionDumps[key] = targetPath;
        return targetPath;
      }
    } else {
      if (requestId != null && _activeNormalDumps.containsKey(requestId)) {
        targetPath = _activeNormalDumps[requestId];
      } else {
        targetPath = lastDumpFilePath;
      }
      if (targetPath == null) {
        return null;
      }
      if (requestId != null && requestId.isNotEmpty) {
        _activeNormalDumps[requestId] = targetPath;
      }
    }

    try {
      final relativePath = p.join('request_dumps', p.basename(targetPath));
      if (!boundary.fileExists(relativePath)) {
        return null;
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
      data['capture_state'] = 'request_sent';

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await boundary.writeConfigText(relativePath, jsonString);
      return targetPath;
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to update LLM request dump transport: $e',
        e,
        stackTrace,
      );
      return null;
    }
  }

  static Future<String?> recordError(
    Object error, {
    String? requestId,
    String? compactionId,
  }) async {
    if (!isEnabled) return null;

    final isCompaction = isCompactionRequest(
      compactionId: compactionId,
      requestId: requestId,
    );

    String? targetPath;
    String? key;

    if (isCompaction) {
      key = compactionKey(compactionId: compactionId, requestId: requestId);
      targetPath = _activeCompactionDumps[key];
      if (targetPath == null) {
        _logger.fine(
          'Skipping error dump for unmatched compaction request ($key).',
        );
        return null;
      }
    } else {
      if (requestId != null && _activeNormalDumps.containsKey(requestId)) {
        targetPath = _activeNormalDumps[requestId];
      } else {
        targetPath = lastDumpFilePath;
      }
      if (targetPath == null) {
        return null;
      }
    }

    try {
      final boundary = SanadHomeBootstrap.state();
      final relativePath = p.join('request_dumps', p.basename(targetPath));
      if (!boundary.fileExists(relativePath)) {
        return null;
      }

      final content = utf8.decode(boundary.readSecretBytes(relativePath));
      final Map<String, dynamic> data = jsonDecode(content);
      data['error'] = _sanitizePayload(_serializeError(error));
      data['capture_state'] = 'error';

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await boundary.writeConfigText(relativePath, jsonString);

      if (isCompaction && key != null) {
        _activeCompactionDumps.remove(key);
      } else if (requestId != null) {
        _activeNormalDumps.remove(requestId);
      }

      return targetPath;
    } catch (e, stackTrace) {
      _logger.warning(
        'Failed to append LLM request error details: $e',
        e,
        stackTrace,
      );
      return null;
    }
  }

  /// Dumps the response payload to the matching dump file.
  ///
  /// For compaction requests, pairs by compactionKey and never modifies or reads
  /// [lastDumpFilePath]. For unmatched auxiliary compaction requests, logs at fine
  /// level without error.
  static Future<String?> dumpResponse(
    dynamic responsePayload, {
    String? requestId,
    String? compactionId,
  }) async {
    if (!isEnabled) return null;

    final isCompaction = isCompactionRequest(
      compactionId: compactionId,
      requestId: requestId,
    );

    String? targetPath;
    String? key;

    if (isCompaction) {
      key = compactionKey(compactionId: compactionId, requestId: requestId);
      targetPath = _activeCompactionDumps[key];
      if (targetPath == null) {
        _logger.fine(
          'Skipping LLM response dump for auxiliary compaction request ($key).',
        );
        return null;
      }
    } else {
      if (requestId != null && _activeNormalDumps.containsKey(requestId)) {
        targetPath = _activeNormalDumps[requestId];
      } else {
        targetPath = lastDumpFilePath;
      }
      if (targetPath == null) {
        _logger.fine(
          'Attempted to dump LLM response, but lastDumpFilePath is null.',
        );
        return null;
      }
    }

    try {
      final boundary = SanadHomeBootstrap.state();
      final relativePath = p.join('request_dumps', p.basename(targetPath));
      if (!boundary.fileExists(relativePath)) {
        _logger.warning('Request dump file not found.');
        return null;
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
      } else if (responsePayload is! Map &&
          responsePayload is! List &&
          responsePayload is! num &&
          responsePayload is! bool &&
          responsePayload != null) {
        try {
          sanitizedResponse = (responsePayload as dynamic).toJson();
        } catch (_) {}
      }

      data['response'] = _sanitizePayload(sanitizedResponse);
      data['capture_state'] = 'completed';

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await boundary.writeConfigText(relativePath, jsonString);

      _logger.info(
        isCompaction
            ? 'Compaction LLM response added to request dump ($key).'
            : 'LLM response added to request dump.',
      );

      if (isStdoutEnabled) {
        stdout.writeln('\n--- DUMP_RESPONSE START ---');
        stdout.writeln(jsonString);
        stdout.writeln('--- DUMP_RESPONSE END ---\n');
      }

      // Cleanup active mapping on completion to prevent unbounded accumulation
      if (isCompaction && key != null) {
        _activeCompactionDumps.remove(key);
      } else if (requestId != null) {
        _activeNormalDumps.remove(requestId);
      }

      return targetPath;
    } catch (e, stackTrace) {
      _logger.warning('Failed to dump LLM response: $e', e, stackTrace);
      return null;
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

  /// Returns a recursively sanitized deep copy for diagnostics. The live
  /// provider payload is never mutated.
  static dynamic sanitizePayloadForTesting(dynamic value) =>
      _sanitizePayload(value);

  /// Recursively traverses a payload, replacing typed image blocks, native Ollama
  /// image arrays, and data URIs before generic secret/string redaction.
  static dynamic _sanitizePayload(dynamic value) {
    if (value is Map) {
      final image = _imagePayloadMetadata(value);
      if (image != null) return image;
      return value.map((key, child) {
        if (key == 'images') {
          if (child is List) {
            return MapEntry(key, child.map(_sanitizeNativeImage).toList());
          }
          if (child is String) {
            return MapEntry(key, _sanitizeNativeImage(child));
          }
        }
        return MapEntry(key, _sanitizePayload(child));
      });
    }
    if (value is List) return value.map(_sanitizePayload).toList();
    if (value is String) return _sanitizeString(value);
    if (value != null && value is! num && value is! bool) {
      try {
        return _sanitizePayload((value as dynamic).toJson());
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  static Map<String, dynamic>? _imagePayloadMetadata(Map value) {
    final type = value['type']?.toString();
    if (type != 'image' && type != 'image_url' && type != 'input_image') {
      return null;
    }

    String? mimeType;
    String? payload;
    if (value['dataBase64'] is String) {
      payload = value['dataBase64'] as String;
      mimeType = value['mimeType']?.toString();
    } else if (value['data'] is String) {
      payload = value['data'] as String;
      mimeType = value['mimeType']?.toString();
    } else if (value['source'] is Map) {
      final source = value['source'] as Map;
      payload = source['data'] is String ? source['data'] as String : null;
      mimeType = (source['media_type'] ?? source['mimeType'])?.toString();
    } else if (value['image_url'] is Map) {
      final imageUrl = value['image_url'] as Map;
      payload = imageUrl['url'] is String ? imageUrl['url'] as String : null;
    } else if (value['image_url'] is String) {
      payload = value['image_url'] as String;
    }
    if (payload == null) return null;

    final dataUri = _parseDataUri(payload);
    mimeType ??= dataUri?.mimeType;
    final base64Value = dataUri?.payload ?? payload;
    final decodedBytes = _decodedBase64Bytes(base64Value);
    if (decodedBytes != null &&
        (mimeType == null ||
            mimeType == 'unknown' ||
            mimeType == 'application/octet-stream')) {
      mimeType = _sniffMimeTypeFromBase64(base64Value);
    }
    return {
      'type': 'image_redacted',
      'mime_type': mimeType ?? 'unknown',
      'decoded_bytes': decodedBytes,
    };
  }

  static Map<String, dynamic> _sanitizeNativeImage(dynamic item) {
    if (item is Map) {
      final image = _imagePayloadMetadata(item);
      if (image != null) return image;
    }
    if (item is! String) {
      return const {
        'type': 'image_redacted',
        'mime_type': 'unknown',
        'decoded_bytes': null,
      };
    }

    final dataUri = _parseDataUri(item);
    final String base64Payload;
    String? mimeType;
    if (dataUri != null) {
      base64Payload = dataUri.payload;
      if (dataUri.mimeType.isNotEmpty) {
        mimeType = dataUri.mimeType;
      }
    } else {
      base64Payload = item;
    }

    final decodedBytes = _decodedBase64Bytes(base64Payload);
    if (decodedBytes == null) {
      return {
        'type': 'image_redacted',
        'mime_type': mimeType ?? 'unknown',
        'decoded_bytes': null,
      };
    }

    if (mimeType == null ||
        mimeType == 'unknown' ||
        mimeType == 'application/octet-stream') {
      mimeType = _sniffMimeTypeFromBase64(base64Payload);
    }

    return {
      'type': 'image_redacted',
      'mime_type': mimeType,
      'decoded_bytes': decodedBytes,
    };
  }

  static String _sniffMimeTypeFromBase64(String base64Payload) {
    if (base64Payload.isEmpty) return 'unknown';
    try {
      final headerLength = base64Payload.length >= 16
          ? 16
          : base64Payload.length;
      final bytes = base64.decode(base64Payload.substring(0, headerLength));
      return _sniffMimeTypeFromBytes(bytes);
    } catch (_) {
      return 'unknown';
    }
  }

  static String _sniffMimeTypeFromBytes(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return 'unknown';
  }

  static ({String mimeType, String payload})? _parseDataUri(String value) {
    if (!value.toLowerCase().startsWith('data:')) return null;
    final separator = value.toLowerCase().indexOf(';base64,');
    if (separator <= 5) return null;
    final mimeType = value.substring(5, separator);
    if (mimeType.contains(',') || mimeType.contains(';')) return null;
    return (
      mimeType: mimeType,
      payload: value.substring(separator + ';base64,'.length),
    );
  }

  static int? _decodedBase64Bytes(String value) {
    if (value.isEmpty ||
        value.length % 4 != 0 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(value)) {
      return null;
    }
    final padding = value.endsWith('==')
        ? 2
        : value.endsWith('=')
        ? 1
        : 0;
    return (value.length * 3 ~/ 4) - padding;
  }

  /// Sanitizes one string without retaining any sample of binary payloads.
  static String _sanitizeString(String val) {
    final dataUri = _parseDataUri(val);
    if (dataUri != null) {
      final bytes = _decodedBase64Bytes(dataUri.payload);
      return '[image payload redacted: mime=${dataUri.mimeType}, bytes=${bytes ?? 'unknown'}]';
    }

    val = _redactor.redact(val);
    if (val.length > 1000 &&
        !val.contains(RegExp(r'\s')) &&
        RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(val)) {
      return '[binary payload redacted: mime=unknown, bytes=${_decodedBase64Bytes(val) ?? 'unknown'}]';
    }
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
