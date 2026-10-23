import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../core/sanad_home/sanad_home_bootstrap.dart';
import '../core/models/message.dart';
import '../core/di.dart';
import '../core/config.dart';
import 'llm_payload_sanitizer.dart';

/// A utility class responsible for dumping LLM request payloads and execution errors
/// to the filesystem during development, controlled by the `DUMP_REQUESTS` environment variable.
class LLMRequestDumper {
  static final Logger _logger = Logger('LLMRequestDumper');

  /// Internal environment override for unit testing
  static Map<String, String>? environmentOverride;

  /// The path of the last dumped normal-turn request.
  ///
  /// Invariant: Compaction requests NEVER modify or read this path.
  static String? lastDumpFilePath;

  /// The path of the currently in-flight unkeyed normal-turn request dump, if any.
  /// Cleared to null once the unkeyed request reaches terminal state (completed or error).
  static String? _activeUnkeyedNormalDumpPath;

  /// Active normal-turn dump file paths keyed by requestId.
  static final Map<String, String> _activeNormalDumps = {};

  /// Active compaction dump file paths keyed by canonical compaction key.
  static final Map<String, String> _activeCompactionDumps = {};

  /// Completed compaction dump file paths (bounded FIFO) keyed by canonical compaction key.
  static final Map<String, String> _completedCompactionDumps = {};
  static const int _maxCompletedCompactionDumps = 50;

  /// Resets internal dump file tracking state for test isolation.
  static void resetForTesting() {
    lastDumpFilePath = null;
    _activeUnkeyedNormalDumpPath = null;
    environmentOverride = null;
    _activeNormalDumps.clear();
    _activeCompactionDumps.clear();
    _completedCompactionDumps.clear();
  }

  /// Returns the relative dump path from full file path.
  static String? toRelativeDumpPath(String? fullPath) {
    if (fullPath == null || fullPath.isEmpty) return null;
    return p.join('request_dumps', p.basename(fullPath));
  }

  /// Gets the relative dump path for an active or completed compaction key.
  static String? getRelativeDumpPath({
    String? compactionId,
    String? requestId,
  }) {
    final key = compactionKey(compactionId: compactionId, requestId: requestId);
    if (key.isEmpty) return null;
    final cached = _activeCompactionDumps[key] ?? _completedCompactionDumps[key];
    if (cached != null) {
      return toRelativeDumpPath(cached);
    }
    final cleanComp = compactionId != null && compactionId.isNotEmpty
        ? (compactionId.startsWith('compaction:')
            ? compactionId.substring('compaction:'.length)
            : compactionId)
        : null;
    if (requestId == null && cleanComp != null && cleanComp.isNotEmpty) {
      for (final entry in _activeCompactionDumps.entries) {
        if (entry.key.contains(cleanComp)) {
          return toRelativeDumpPath(entry.value);
        }
      }
      for (final entry in _completedCompactionDumps.entries) {
        if (entry.key.contains(cleanComp)) {
          return toRelativeDumpPath(entry.value);
        }
      }
    }
    try {
      final boundary = SanadHomeBootstrap.state();
      final dumpsDir = Directory(boundary.child('request_dumps'));
      if (dumpsDir.existsSync()) {
        final safeKey = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final prefix = 'compaction_dump_${safeKey}_';
        final cleanCompSafe =
            cleanComp?.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        for (final entity in dumpsDir.listSync()) {
          if (entity is File) {
            final name = p.basename(entity.path);
            if (name.startsWith(prefix) ||
                (cleanCompSafe != null &&
                    cleanCompSafe.isNotEmpty &&
                    name.startsWith('compaction_dump_') &&
                    name.contains(cleanCompSafe))) {
              return toRelativeDumpPath(entity.path);
            }
          }
        }
      }
    } catch (_) {}
    return null;
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
        if (cleanReq == cleanComp ||
            cleanReq.startsWith('$cleanComp:') ||
            cleanReq.startsWith('auto:') ||
            cleanReq.startsWith('overflow:') ||
            cleanReq.startsWith('manual:') ||
            cleanReq.contains(cleanComp)) {
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
    if (parts.length >= 3 &&
        (parts[1] == 'auto' || parts[1] == 'overflow' || parts[1] == 'manual') &&
        parts[2].isNotEmpty) {
      return parts[2];
    }
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
    } else {
      _activeUnkeyedNormalDumpPath = null;
    }
  }

  static String _formatTimestamp(DateTime now) {
    final ms = now.millisecond.toString().padLeft(3, '0');
    final us = (now.microsecond % 1000).toString().padLeft(3, '0');
    return '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}_'
        '${ms}_$us';
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
    String? protocol,
    bool? stream,
    Map<String, dynamic>? safeOptions,
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
      String fileName;
      String relativePath;
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

      if (boundary.fileExists(relativePath)) {
        final ext = p.extension(fileName);
        final base = p.basenameWithoutExtension(fileName);
        fileName = '${base}_${DateTime.now().microsecondsSinceEpoch}$ext';
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
        'protocol': ?protocol,
        'stream': ?stream,
        'options': ?safeOptions,
        'api_key': LLMPayloadSanitizer.maskApiKey(apiKey),
        'metadata': customMetadata,
        'capture_state': 'initialized',
        'request': {
          'method': 'POST',
          'url': baseUrl != null
              ? '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions'
              : null,
          'headers': {
            if (apiKey != null)
              'Authorization': 'Bearer ${LLMPayloadSanitizer.maskApiKey(apiKey)}',
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
        if (error != null) 'error': LLMPayloadSanitizer.serializeError(error),
      };

      final sanitizedPayload = LLMPayloadSanitizer.sanitizePayload(rawPayload);
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
        } else {
          _activeUnkeyedNormalDumpPath = fullPath;
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
    String? sessionId,
    String? provider,
    String? model,
    String? baseUrl,
    String? protocol,
    bool? stream,
    Map<String, dynamic>? safeOptions,
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
          'provider': ?provider,
          'model': ?model,
          'base_url': baseUrl ?? url.origin,
          'protocol': ?protocol,
          'stream': ?stream,
          'options': ?safeOptions,
          'capture_state': 'request_sent',
          'request': {
            'method': 'POST',
            'url': url.toString(),
            'headers': headers,
            'body': ?body,
          },
        };

        final sanitizedPayload = LLMPayloadSanitizer.sanitizePayload(rawPayload);
        final jsonString = const JsonEncoder.withIndent('  ').convert(sanitizedPayload);
        await boundary.writeConfigText(relativePath, jsonString);

        targetPath = boundary.child(relativePath);
        _activeCompactionDumps[key] = targetPath;
        return targetPath;
      }
    } else {
      if (requestId != null && requestId.isNotEmpty) {
        if (_activeNormalDumps.containsKey(requestId)) {
          targetPath = _activeNormalDumps[requestId];
        } else {
          // Keyed request ID was supplied, but is unknown or already terminal.
          // Fail closed: never attach to a different active request or unkeyed dump.
          return null;
        }
      } else {
        if (_activeUnkeyedNormalDumpPath != null) {
          targetPath = _activeUnkeyedNormalDumpPath;
        } else {
          // Auto-create independent unkeyed dump file on actual request if no preceding dumpRequest call
          final now = DateTime.now();
          final timestamp = _formatTimestamp(now);
          final sid = sessionId ?? 'auxiliary';
          final safeSessionId = sid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
          var fileName = 'request_dump_${safeSessionId}_$timestamp.json';
          var relativePath = p.join('request_dumps', fileName);
          if (boundary.fileExists(relativePath)) {
            final ext = p.extension(fileName);
            final base = p.basenameWithoutExtension(fileName);
            fileName = '${base}_${DateTime.now().microsecondsSinceEpoch}$ext';
            relativePath = p.join('request_dumps', fileName);
          }

          final rawPayload = <String, dynamic>{
            'timestamp': now.toIso8601String(),
            'session_id': sid,
            'provider': ?provider,
            'model': ?model,
            'base_url': baseUrl ?? url.origin,
            'protocol': ?protocol,
            'stream': ?stream,
            if (safeOptions != null && safeOptions.isNotEmpty)
              'options': safeOptions,
            'capture_state': 'request_sent',
            'request': {
              'method': 'POST',
              'url': url.toString(),
              'headers': headers,
              'body': ?body,
            },
          };

          final sanitizedPayload =
              LLMPayloadSanitizer.sanitizePayload(rawPayload);
          final jsonString =
              const JsonEncoder.withIndent('  ').convert(sanitizedPayload);
          await boundary.writeConfigText(relativePath, jsonString);

          targetPath = boundary.child(relativePath);
          _activeUnkeyedNormalDumpPath = targetPath;
          lastDumpFilePath = targetPath;
          return targetPath;
        }
      }
      if (targetPath == null) {
        return null;
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
      data['request'] = LLMPayloadSanitizer.sanitizePayload(request);
      data['capture_state'] = 'request_sent';
      if (provider != null) data['provider'] = provider;
      if (model != null) data['model'] = model;
      if (baseUrl != null) {
        data['base_url'] = baseUrl;
      } else if (data['base_url'] == null) {
        data['base_url'] = url.origin;
      }
      if (protocol != null) data['protocol'] = protocol;
      if (stream != null) data['stream'] = stream;
      if (safeOptions != null && safeOptions.isNotEmpty) {
        data['options'] = LLMPayloadSanitizer.sanitizePayload(safeOptions);
      }

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
    int? statusCode,
    Duration? duration,
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
      if (requestId != null && requestId.isNotEmpty) {
        if (_activeNormalDumps.containsKey(requestId)) {
          targetPath = _activeNormalDumps[requestId];
        } else {
          // Keyed request ID is unknown or already terminal. Fail closed.
          return null;
        }
      } else {
        if (_activeUnkeyedNormalDumpPath != null) {
          targetPath = _activeUnkeyedNormalDumpPath;
        } else {
          return null;
        }
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
      data['error'] = LLMPayloadSanitizer.sanitizePayload(
        LLMPayloadSanitizer.serializeError(error),
      );
      data['capture_state'] = 'error';
      if (statusCode != null) data['status_code'] = statusCode;
      if (duration != null) data['duration_ms'] = duration.inMilliseconds;

      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await boundary.writeConfigText(relativePath, jsonString);

      if (isCompaction && key != null) {
        _activeCompactionDumps.remove(key);
        _completedCompactionDumps[key] = targetPath;
        if (_completedCompactionDumps.length > _maxCompletedCompactionDumps) {
          _completedCompactionDumps.remove(_completedCompactionDumps.keys.first);
        }
      } else {
        if (requestId != null && requestId.isNotEmpty) {
          _activeNormalDumps.remove(requestId);
        } else if (_activeUnkeyedNormalDumpPath == targetPath) {
          _activeUnkeyedNormalDumpPath = null;
        }
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
    int? statusCode,
    Duration? duration,
    String? finishReason,
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
      if (requestId != null && requestId.isNotEmpty) {
        if (_activeNormalDumps.containsKey(requestId)) {
          targetPath = _activeNormalDumps[requestId];
        } else {
          // Keyed request ID is unknown or already terminal. Fail closed.
          return null;
        }
      } else {
        if (_activeUnkeyedNormalDumpPath != null) {
          targetPath = _activeUnkeyedNormalDumpPath;
        } else {
          _logger.fine(
            'Attempted to dump LLM response, but lastDumpFilePath is null.',
          );
          return null;
        }
      }
      if (targetPath == null) {
        _logger.fine(
          'Attempted to dump LLM response, but active normal dump path is null.',
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

      data['response'] = LLMPayloadSanitizer.sanitizePayload(sanitizedResponse);
      if (statusCode != null) data['status_code'] = statusCode;
      if (duration != null) data['duration_ms'] = duration.inMilliseconds;
      if (finishReason != null) data['finish_reason'] = finishReason;

      final isTruncated = finishReason == 'length' ||
          finishReason == 'incomplete' ||
          finishReason == 'max_tokens' ||
          (responsePayload is Map &&
              (responsePayload['partial_message'] != null ||
                  responsePayload['truncated'] == true));
      final isError = (statusCode != null && statusCode != 200) ||
          (responsePayload is Map && responsePayload['error'] != null) ||
          finishReason == 'failed' ||
          finishReason == 'cancelled';

      if (isError) {
        data['capture_state'] = 'error';
      } else if (isTruncated) {
        data['capture_state'] = 'truncated';
        data['truncated'] = true;
      } else {
        data['capture_state'] = 'completed';
      }

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
        _completedCompactionDumps[key] = targetPath;
        if (_completedCompactionDumps.length > _maxCompletedCompactionDumps) {
          _completedCompactionDumps.remove(_completedCompactionDumps.keys.first);
        }
      } else {
        if (requestId != null && requestId.isNotEmpty) {
          _activeNormalDumps.remove(requestId);
        } else if (_activeUnkeyedNormalDumpPath == targetPath) {
          _activeUnkeyedNormalDumpPath = null;
        }
      }

      return targetPath;
    } catch (e, stackTrace) {
      _logger.warning('Failed to dump LLM response: $e', e, stackTrace);
      return null;
    }
  }

  /// Returns a recursively sanitized deep copy for diagnostics. The live
  /// provider payload is never mutated.
  static dynamic sanitizePayloadForTesting(dynamic value) =>
      LLMPayloadSanitizer.sanitizePayload(value);
}
