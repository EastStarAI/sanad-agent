/// Serializes the documented Chat-template Boolean thinking toggles.
///
/// NIM-hosted Kimi documents `chat_template_kwargs: {"thinking": bool}` and
/// NIM (hosted and self-hosted) Qwen documents
/// `chat_template_kwargs: {"enable_thinking": bool}`. This is the one finite
/// typed serializer for those keys: the directive validates the key against a
/// documented allowlist, so no arbitrary JSON or unknown key can be emitted.
library;

import 'native_thinking_directive.dart';

class ChatTemplateKwargsWireCodec {
  ChatTemplateKwargsWireCodec._();

  static const bodyKey = 'chat_template_kwargs';

  /// Applies [directive] to a Chat Completions body, preserving any other
  /// template kwargs the body already carries.
  static void apply(
    Map<String, dynamic> body,
    ChatTemplateBooleanDirective directive,
  ) {
    final existing = body[bodyKey];
    final kwargs = existing is Map
        ? Map<String, dynamic>.from(
            existing.map((key, value) => MapEntry(key.toString(), value)),
          )
        : <String, dynamic>{};
    kwargs[directive.key] = directive.value;
    body[bodyKey] = kwargs;
  }
}
