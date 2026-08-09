import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';

void main() {
  group('OAuth Metadata Tests', () {
    test('McpServerConfig should persist OAuth metadata', () {
      final config = McpServerConfig(
        name: 'Test Server',
        serverUrl: 'https://example.com/sse',
        authType: McpAuthType.oauth,
        oauthClientId: 'client-123',
        oauthTokenUrl: 'https://example.com/token',
        oauthAuthUrl: 'https://example.com/authorize',
      );

      expect(config.oauthClientId, 'client-123');
      expect(config.oauthTokenUrl, 'https://example.com/token');
      expect(config.oauthAuthUrl, 'https://example.com/authorize');

      final json = config.toJson();
      final fromJson = McpServerConfig.fromJson(json);

      expect(fromJson.oauthClientId, 'client-123');
      expect(fromJson.oauthTokenUrl, 'https://example.com/token');
      expect(fromJson.oauthAuthUrl, 'https://example.com/authorize');
    });
  });
}
