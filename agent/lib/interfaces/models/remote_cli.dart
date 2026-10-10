/// Protocol command identifiers for remote CLI relay.
class RemoteCliCommands {
  static const execute = 'device.cli.execute';
  static const cancel = 'device.cli.cancel';
  static const stdout = 'device.cli.stdout';
  static const stderr = 'device.cli.stderr';
  static const event = 'device.cli.event';
  static const result = 'device.cli.result';

  static const all = {execute, cancel};
}

/// Standard error codes for remote CLI execution rejections.
class RemoteCliErrorCodes {
  static const invalidRequest = 'invalid_request';
  static const duplicateRequest = 'duplicate_request';
  static const payloadTooLarge = 'payload_too_large';
  static const timeout = 'timeout';
  static const cancelled = 'cancelled';
  static const notFound = 'not_found';
  static const wrongDevice = 'wrong_device';
}

/// Bounds and limits enforced on remote CLI execution payloads.
class RemoteCliLimits {
  static const int maxArgCount = 256;
  static const int maxArgLength = 1024 * 1024; // 1 MB
  static const int maxStdinLength = 10 * 1024 * 1024; // 10 MB
  static const int maxBriefContentLength = 512 * 1024; // 512 KB
  static const int maxTotalPayloadLength = 12 * 1024 * 1024; // 12 MB
  static const int minTimeoutSeconds = 1;
  static const int defaultTimeoutSeconds = 300;
  static const int maxTimeoutSeconds = 86400; // 24 hours
}

/// Typed exception thrown when remote CLI request validation fails.
class RemoteCliValidationException implements Exception {
  final String code;
  final String message;

  const RemoteCliValidationException(this.code, this.message);

  @override
  String toString() => 'RemoteCliValidationException($code): $message';
}

/// Parsed and validated request to execute a remote Sanad CLI command.
class RemoteCliExecuteRequest {
  final String requestId;
  final String deviceId;
  final List<String> argv;
  final String? stdin;
  final String? briefFileContent;
  final int timeoutSeconds;

  const RemoteCliExecuteRequest({
    required this.requestId,
    required this.deviceId,
    required this.argv,
    this.stdin,
    this.briefFileContent,
    this.timeoutSeconds = RemoteCliLimits.defaultTimeoutSeconds,
  });

  factory RemoteCliExecuteRequest.fromPayload({
    required String deviceId,
    required Map<String, dynamic> payload,
    String? envelopeRequestId,
  }) {
    final reqId = (payload['request_id'] ?? envelopeRequestId)?.toString().trim() ?? '';
    if (reqId.isEmpty) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.invalidRequest,
        'request_id is required.',
      );
    }

    final rawArgv = payload['argv'];
    if (rawArgv == null) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.invalidRequest,
        'argv is required.',
      );
    }
    if (rawArgv is! List) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.invalidRequest,
        'argv must be a list of strings.',
      );
    }
    if (rawArgv.isEmpty) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.invalidRequest,
        'argv must not be empty.',
      );
    }
    if (rawArgv.length > RemoteCliLimits.maxArgCount) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.payloadTooLarge,
        'argv exceeds maximum argument count of ${RemoteCliLimits.maxArgCount}.',
      );
    }

    final argv = <String>[];
    for (final arg in rawArgv) {
      if (arg is! String) {
        throw const RemoteCliValidationException(
          RemoteCliErrorCodes.invalidRequest,
          'Every argument in argv must be a string.',
        );
      }
      if (arg.length > RemoteCliLimits.maxArgLength) {
        throw const RemoteCliValidationException(
          RemoteCliErrorCodes.payloadTooLarge,
          'Argument exceeds maximum length of ${RemoteCliLimits.maxArgLength} bytes.',
        );
      }
      argv.add(arg);
    }

    final rawStdin = payload['stdin'];
    String? stdin;
    if (rawStdin != null) {
      if (rawStdin is! String) {
        throw const RemoteCliValidationException(
          RemoteCliErrorCodes.invalidRequest,
          'stdin must be a string.',
        );
      }
      if (rawStdin.length > RemoteCliLimits.maxStdinLength) {
        throw const RemoteCliValidationException(
          RemoteCliErrorCodes.payloadTooLarge,
          'stdin exceeds maximum length of ${RemoteCliLimits.maxStdinLength} bytes.',
        );
      }
      stdin = rawStdin;
    }

    final rawBriefContent = payload['brief_content'] ?? payload['brief_file_content'];
    String? briefFileContent;
    if (rawBriefContent != null) {
      if (rawBriefContent is! String) {
        throw const RemoteCliValidationException(
          RemoteCliErrorCodes.invalidRequest,
          'brief_content must be a string.',
        );
      }
      if (rawBriefContent.length > RemoteCliLimits.maxBriefContentLength) {
        throw const RemoteCliValidationException(
          RemoteCliErrorCodes.payloadTooLarge,
          'brief_content exceeds maximum length of ${RemoteCliLimits.maxBriefContentLength} bytes.',
        );
      }
      briefFileContent = rawBriefContent;
    }

    final totalPayloadLength = argv.fold<int>(0, (sum, arg) => sum + arg.length) +
        (stdin?.length ?? 0) +
        (briefFileContent?.length ?? 0);
    if (totalPayloadLength > RemoteCliLimits.maxTotalPayloadLength) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.payloadTooLarge,
        'Total payload exceeds maximum size of ${RemoteCliLimits.maxTotalPayloadLength} bytes.',
      );
    }

    int timeoutSeconds = RemoteCliLimits.defaultTimeoutSeconds;
    if (payload.containsKey('timeout_seconds') && payload['timeout_seconds'] != null) {
      final parsed = int.tryParse(payload['timeout_seconds'].toString());
      if (parsed == null ||
          parsed < RemoteCliLimits.minTimeoutSeconds ||
          parsed > RemoteCliLimits.maxTimeoutSeconds) {
        throw const RemoteCliValidationException(
          RemoteCliErrorCodes.invalidRequest,
          'timeout_seconds must be an integer between 1 and 86400.',
        );
      }
      timeoutSeconds = parsed;
    }

    return RemoteCliExecuteRequest(
      requestId: reqId,
      deviceId: deviceId,
      argv: List.unmodifiable(argv),
      stdin: stdin,
      briefFileContent: briefFileContent,
      timeoutSeconds: timeoutSeconds,
    );
  }

  Map<String, dynamic> toPayload() => {
    'request_id': requestId,
    'argv': argv,
    if (stdin != null) 'stdin': stdin,
    if (briefFileContent != null) 'brief_content': briefFileContent,
    'timeout_seconds': timeoutSeconds,
  };
}

/// Parsed and validated request to cancel an in-flight remote CLI execution.
class RemoteCliCancelRequest {
  final String requestId;
  final String deviceId;
  final String targetRequestId;

  const RemoteCliCancelRequest({
    required this.requestId,
    required this.deviceId,
    required this.targetRequestId,
  });

  factory RemoteCliCancelRequest.fromPayload({
    required String deviceId,
    required Map<String, dynamic> payload,
    String? envelopeRequestId,
  }) {
    final reqId = (payload['request_id'] ?? envelopeRequestId)?.toString().trim() ?? '';
    if (reqId.isEmpty) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.invalidRequest,
        'request_id is required.',
      );
    }

    final targetId = payload['target_request_id']?.toString().trim() ?? '';
    if (targetId.isEmpty) {
      throw const RemoteCliValidationException(
        RemoteCliErrorCodes.invalidRequest,
        'target_request_id is required.',
      );
    }

    return RemoteCliCancelRequest(
      requestId: reqId,
      deviceId: deviceId,
      targetRequestId: targetId,
    );
  }

  Map<String, dynamic> toPayload() => {
    'request_id': requestId,
    'target_request_id': targetRequestId,
  };
}

/// Terminal execution result emitted as `device.cli.result`.
class RemoteCliResult {
  final String requestId;
  final int seq;
  final int exitCode;
  final int durationMs;
  final bool cancelled;
  final bool timedOut;
  final String? error;

  const RemoteCliResult({
    required this.requestId,
    required this.seq,
    required this.exitCode,
    required this.durationMs,
    this.cancelled = false,
    this.timedOut = false,
    this.error,
  });

  Map<String, dynamic> toPayload() => {
    'request_id': requestId,
    'seq': seq,
    'exit_code': exitCode,
    'duration_ms': durationMs,
    'cancelled': cancelled,
    'timed_out': timedOut,
    if (error != null) 'error': error,
  };
}
