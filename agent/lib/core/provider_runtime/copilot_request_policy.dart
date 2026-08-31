import '../models/message.dart';
import 'provider_protocol_constants.dart';

/// Copilot per-request header and model-routing helpers.
class CopilotRequestPolicy {
  CopilotRequestPolicy._();

  /// Static Copilot identity headers plus initiator/vision overlays.
  static Map<String, String> requestHeaders({
    required bool afterToolResults,
    required bool vision,
  }) {
    return {
      ...GithubCopilotProtocol.staticRequestHeaders,
      ...GithubCopilotProtocol.dynamicRequestHeaders(
        afterToolResults: afterToolResults,
        vision: vision,
      ),
    };
  }

  /// True when [history] contains image or vision input.
  static bool historyHasVision(Iterable<Message> history) {
    for (final message in history) {
      if (_looksLikeImage(message.content)) return true;
      final metadata = message.metadata;
      if (metadata == null) continue;
      for (final value in metadata.values) {
        if (_looksLikeImage('$value')) return true;
      }
    }
    return false;
  }

  static bool _looksLikeImage(String? value) {
    if (value == null || value.isEmpty) return false;
    final lower = value.toLowerCase();
    return lower.contains('data:image/') ||
        lower.contains('image_url') ||
        lower.contains('image/png') ||
        lower.contains('image/jpeg') ||
        lower.contains('image/jpg') ||
        lower.contains('image/webp') ||
        lower.contains('image/gif');
  }
}
