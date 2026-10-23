import 'dart:async';
import 'dart:convert' hide json;
import 'dart:io';

import '../../../client/local_gateway_cli_client.dart';
import '../../../discovery/local_gateway_discovery.dart';
import '../../../oneshot/oneshot_runner.dart';
import '../../sanad_command.dart';
import '../session_command.dart';

/// Unwraps a correlated gateway response into its canonical payload map.
///
/// Query responses wrap the canonical payload under `payload`; an envelope that
/// is already canonical is returned unchanged.
Map<String, dynamic> unwrapSessionPayload(Map<String, dynamic> result) =>
    result['payload'] is Map
    ? Map<String, dynamic>.from(result['payload'] as Map)
    : result;

/// Client-side failure codes that are transport problems, never gateway
/// verdicts. Every session intervention command reports them as exit `1`.
const Set<String> sessionTransportErrorCodes = {
  'client_error',
  'connection_failed',
  'disposed',
  'not_connected',
  'disconnected',
  'send_error',
  'query_timeout',
};

/// Shared upper bound of `--timeout` (`addCommonOptions`), in seconds.
const int _maxTimeoutSeconds = 86400;

/// Parses the shared `--timeout` option as an acknowledgement bound.
///
/// A value outside the documented `1..86400` range is a usage error, never a
/// silent fall-back to the default. Returns `null` when the option is unset.
Duration? sessionAcknowledgementTimeout(String? raw) {
  if (raw == null) return null;
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed < 1 || parsed > _maxTimeoutSeconds) {
    throw FormatException(
      '--timeout must be a whole number of seconds from 1 to '
      '$_maxTimeoutSeconds.',
    );
  }
  return Duration(seconds: parsed);
}

abstract class SessionSubcommandBase extends SanadCommand {
  final ClientFactory? clientFactory;
  final LocalGatewayCliClient? clientOverride;

  SessionSubcommandBase({
    this.clientFactory,
    this.clientOverride,
    super.customAction,
  }) {
    addCommonOptions(argParser);
  }

  Future<({LocalGatewayCliClient client, bool shouldDispose})>
  getClient() async {
    if (clientOverride != null) {
      return (client: clientOverride!, shouldDispose: false);
    }
    final parentCmd = parent;
    if (parentCmd is SessionCommand) {
      if (parentCmd.clientOverride != null) {
        return (client: parentCmd.clientOverride!, shouldDispose: false);
      }
      if (parentCmd.clientFactory != null) {
        final c = await parentCmd.clientFactory!(
          urlOverride: gatewayUrl,
          sanadHomeOverride: sanadHome,
        );
        return (client: c, shouldDispose: true);
      }
    }
    if (clientFactory != null) {
      final c = await clientFactory!(
        urlOverride: gatewayUrl,
        sanadHomeOverride: sanadHome,
      );
      return (client: c, shouldDispose: true);
    }
    final c = await LocalGatewayCliClient.discoverAndConnect(
      urlOverride: gatewayUrl,
      sanadHomeOverride: sanadHome,
    );
    return (client: c, shouldDispose: true);
  }

  Future<T> withClient<T>(
    Future<T> Function(LocalGatewayCliClient client) action,
  ) async {
    final handle = await getClient();
    try {
      return await action(handle.client);
    } finally {
      if (handle.shouldDispose) {
        try {
          await handle.client.dispose();
        } catch (_) {}
      }
    }
  }

  int reportUsage({required String? id, String? message, int exitCode = 2}) {
    if (message != null) {
      stderrSink.writeln('Error: $message');
      stderrSink.writeln('Usage: $invocation');
    }
    if (json) {
      stdoutSink.writeln(
        jsonEncode({
          'session_id': ?id,
          'status': 'error',
          'error_code': 'invalid_arguments',
          'error': message ?? 'Invalid invocation.',
          'exit_code': exitCode,
        }),
      );
    }
    return exitCode;
  }

  int reportFailure({
    required String sessionId,
    required String errorCode,
    required String message,
    required int exitCode,
    String? requestId,
  }) {
    // Every outcome after a dispatch names its request id, so a caller can
    // correlate a late acknowledgement with the request it already attempted.
    final trace = requestId == null ? '' : ' (request $requestId)';
    stderrSink.writeln('Error: $message$trace');
    if (json) {
      stdoutSink.writeln(
        jsonEncode({
          'session_id': sessionId,
          'request_id': ?requestId,
          'status': 'error',
          'error_code': errorCode,
          'error': message,
          'exit_code': exitCode,
        }),
      );
    }
    return exitCode;
  }

  String? resolveSessionId() {
    final explicit = getOption('session');
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    final restId = argResults?.rest.firstOrNull;
    if (restId != null && restId.trim().isNotEmpty) {
      return restId.trim();
    }
    final fallback = session;
    if (fallback != null && fallback.trim().isNotEmpty) {
      return fallback.trim();
    }
    return null;
  }

  String? resolveRequestId() {
    final explicit = getOption('request-id');
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    if (argResults != null && argResults!.rest.length > 1) {
      final restId = argResults!.rest[1];
      if (restId.trim().isNotEmpty) {
        return restId.trim();
      }
    }
    return null;
  }

  /// Lets endpoint resolution failures reach the top-level runner.
  ///
  /// Those failures are environment answers (no live runtime for the selected
  /// Home, a foreign record, an unreachable recorded endpoint), so the runner
  /// reports the actionable message and the configuration exit code instead of
  /// a command-specific "failed to …" wrapper.
  void rethrowEndpointFailure(Object error) {
    if (error is GatewayDiscoveryException) throw error;
  }

  String? readAnswerFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      stderrSink.writeln('Error: Answer file does not exist: $filePath');
      return null;
    }
    final fileContent = file.readAsStringSync().trim();
    try {
      final decoded = jsonDecode(fileContent);
      if (decoded is Map) {
        return decoded['answer']?.toString() ??
            decoded['text']?.toString() ??
            fileContent;
      }
      return decoded.toString();
    } catch (_) {
      return fileContent;
    }
  }

  Map<String, dynamic>? readPermissionFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      stderrSink.writeln('Error: Permission file does not exist: $filePath');
      return null;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (e) {
      stderrSink.writeln('Error: Failed to parse permission file JSON: $e');
      return null;
    }
  }
}
