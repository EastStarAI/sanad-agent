@Deprecated('MCP configuration is daemon-owned. Use McpRuntimeClient.')
abstract final class McpServerManager {
  static Never create() => throw UnsupportedError(
    'Client-owned MCP configuration storage is disabled. Use McpRuntimeClient.',
  );
}
