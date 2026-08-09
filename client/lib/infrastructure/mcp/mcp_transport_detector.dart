import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';

/// Legacy result retained only for source compatibility during migration.
/// MCP inspection is daemon-owned and must be requested through McpRuntimeClient.
class ConnectionTestResult {
  const ConnectionTestResult({
    required this.success,
    required this.message,
    this.detectedTransport,
    this.availableTools,
    this.oauthClientId,
    this.oauthTokenUrl,
    this.oauthAuthUrl,
  });

  final bool success;
  final String message;
  final McpTransportType? detectedTransport;
  final List<String>? availableTools;
  final String? oauthClientId;
  final String? oauthTokenUrl;
  final String? oauthAuthUrl;
}

@Deprecated('Use daemon-owned McpRuntimeClient.inspectServer.')
abstract final class McpTransportDetector {
  static Future<ConnectionTestResult> testConnection({
    required String serverUrl,
    required McpAuthType authType,
    String? oauthClientId,
    String? oauthClientSecret,
    Map<String, String>? headers,
  }) => throw UnsupportedError(
    'Client-owned MCP networking is disabled. Use the local daemon.',
  );
}
