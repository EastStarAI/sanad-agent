/// Applies typed Google Gemini thinking directives via OpenAI-compat extra_body.
library;

import 'native_thinking_directive.dart';

class GoogleThinkingWireCodec {
  GoogleThinkingWireCodec._();

  static void applyThinkingConfig(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case GoogleBudgetDirective(:final budget):
        _thinkingConfig(body)
          ..clear()
          ..['thinking_budget'] = budget;
      case GoogleLevelDirective(:final level):
        _thinkingConfig(body)
          ..clear()
          ..['thinking_level'] = level;
      case UseProviderDefault():
      case null:
        break;
      default:
        break;
    }
  }

  static Map<String, dynamic> _thinkingConfig(Map<String, dynamic> body) {
    final extraBody = _extraBody(body);
    final google = _google(extraBody);
    final thinkingConfig = google.putIfAbsent(
      'thinking_config',
      () => <String, dynamic>{},
    );
    if (thinkingConfig is Map<String, dynamic>) {
      return thinkingConfig;
    }
    if (thinkingConfig is Map) {
      final normalized = thinkingConfig.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      google['thinking_config'] = normalized;
      return normalized;
    }
    final created = <String, dynamic>{};
    google['thinking_config'] = created;
    return created;
  }

  static Map<String, dynamic> _extraBody(Map<String, dynamic> body) {
    final existing = body['extra_body'];
    if (existing is Map<String, dynamic>) {
      return existing;
    }
    if (existing is Map) {
      final normalized = existing.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      body['extra_body'] = normalized;
      return normalized;
    }
    final created = <String, dynamic>{};
    body['extra_body'] = created;
    return created;
  }

  static Map<String, dynamic> _google(Map<String, dynamic> extraBody) {
    final existing = extraBody['google'];
    if (existing is Map<String, dynamic>) {
      return existing;
    }
    if (existing is Map) {
      final normalized = existing.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      extraBody['google'] = normalized;
      return normalized;
    }
    final created = <String, dynamic>{};
    extraBody['google'] = created;
    return created;
  }
}
