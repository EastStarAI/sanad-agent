// This file is generated. Do not edit manually.
// Source: agent/model_capability_defaults.yaml
// Regenerate: fvm dart run tool/generate_model_capability_defaults.dart

const modelCapabilityDefaultsRevision = '5e8fe322b080a22ff9e850b6660d9572df67b36ce5aa6577288c4b60e59514e8';

/// Shipped thinking-capability defaults keyed by exact model id.
const modelCapabilityDefaults = <String, ShippedModelCapabilityDefault>{
  "o1": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "openai/o1": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "o1-2024-12-17": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "openai/o1-2024-12-17": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "o3-mini": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "openai/o3-mini": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "o3-mini-2025-01-31": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "openai/o3-mini-2025-01-31": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "o3": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "openai/o3": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/guides/reasoning",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "gpt-5.1-codex-mini": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh"}},
  ),
  "gpt-5.2-codex": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/models/gpt-5.2-codex.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh"}},
  ),
  "gpt-5.6-sol": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/models/gpt-5.6-sol.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"none": "none", "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max"}, "default_option": "medium"},
  ),
  "openai/gpt-5.6-sol": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/models/gpt-5.6-sol.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"none": "none", "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max"}, "default_option": "medium"},
  ),
  "gpt-6-astra": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/models/gpt-6-astra.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max"}},
  ),
  "openai/gpt-6-astra": ShippedModelCapabilityDefault(
    source: "https://developers.openai.com/api/docs/models/gpt-6-astra.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max"}},
  ),
  "gpt-oss-120b": ShippedModelCapabilityDefault(
    source: "https://openai.com/index/introducing-gpt-oss/",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}},
  ),
  "openai/gpt-oss-120b": ShippedModelCapabilityDefault(
    source: "https://openai.com/index/introducing-gpt-oss/",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}},
  ),
  "gpt-oss-20b": ShippedModelCapabilityDefault(
    source: "https://openai.com/index/introducing-gpt-oss/",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}},
  ),
  "openai/gpt-oss-20b": ShippedModelCapabilityDefault(
    source: "https://openai.com/index/introducing-gpt-oss/",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}},
  ),
  "grok-4.5": ShippedModelCapabilityDefault(
    source: "https://docs.x.ai/developers/model-capabilities/text/reasoning.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "high"},
  ),
  "grok-4.6": ShippedModelCapabilityDefault(
    source: "https://docs.x.ai/developers/model-capabilities/text/reasoning.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh"}, "default_option": "high"},
  ),
  "grok-4.7": ShippedModelCapabilityDefault(
    source: "https://docs.x.ai/developers/model-capabilities/text/reasoning.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh"}, "default_option": "high"},
  ),
  "grok-4.20-0309-non-reasoning": ShippedModelCapabilityDefault(
    source: "https://docs.x.ai/developers/model-capabilities/text/reasoning.md",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "kimi-k3": ShippedModelCapabilityDefault(
    source: "https://platform.kimi.ai/docs/guide/use-thinking-models",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "kimi-k2.6": ShippedModelCapabilityDefault(
    source: "https://platform.kimi.ai/docs/guide/use-thinking-models",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"on": true, "off": false}, "default_option": "on"},
  ),
  "kimi-k2.7-code": ShippedModelCapabilityDefault(
    source: "https://platform.kimi.ai/docs/guide/use-thinking-models",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "kimi-k2.7-code-highspeed": ShippedModelCapabilityDefault(
    source: "https://platform.kimi.ai/docs/guide/use-thinking-models",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "moonshot-v1-8k": ShippedModelCapabilityDefault(
    source: "https://platform.kimi.ai/docs/guide/use-thinking-models",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "moonshot-v1-32k": ShippedModelCapabilityDefault(
    source: "https://platform.kimi.ai/docs/guide/use-thinking-models",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "moonshot-v1-128k": ShippedModelCapabilityDefault(
    source: "https://platform.kimi.ai/docs/guide/use-thinking-models",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-reasoner": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek/deepseek-reasoner": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-ai/deepseek-reasoner": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-r1": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek/deepseek-r1": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-ai/deepseek-r1": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-ai/DeepSeek-R1": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-r1-zero": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek/deepseek-r1-zero": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-ai/deepseek-r1-zero": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-chat": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek/deepseek-chat": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek-ai/deepseek-chat": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek-v3": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek/deepseek-v3": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek-ai/deepseek-v3": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek-ai/DeepSeek-V3": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek-chat-v3": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek/deepseek-chat-v3": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek-ai/deepseek-chat-v3": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "deepseek-v4": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek/deepseek-v4": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek-ai/deepseek-v4": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek-v4-pro": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek/deepseek-v4-pro": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek-v4-flash": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek/deepseek-v4-flash": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek-flash": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek/deepseek-flash": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek-ai/deepseek-flash": ShippedModelCapabilityDefault(
    source: "https://api-docs.deepseek.com/guides/thinking_mode",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek-v4.1-flash": ShippedModelCapabilityDefault(
    source: "https://www.deepseek.com/en/news/deepseek-v4-1-flash/",
    routes: "native",
    compatibleChat: "positive_efforts",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "low": "low", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "glm-4.5": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-4.5",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}},
  ),
  "z-ai/glm-4.5": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-4.5",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}},
  ),
  "zai/glm-4.5": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-4.5",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}},
  ),
  "glm-4.5-air": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-4.5",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}},
  ),
  "z-ai/glm-4.5-air": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-4.5",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}},
  ),
  "zai/glm-4.5-air": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-4.5",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}},
  ),
  "glm-4.7": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "z-ai/glm-4.7": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "zai/glm-4.7": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "glm-5": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "z-ai/glm-5": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "zai/glm-5": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "glm-5.1": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "z-ai/glm-5.1": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "zai/glm-5.1": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "glm-4.7-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "z-ai/glm-4.7-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "zai/glm-4.7-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "on": true}, "default_option": "on"},
  ),
  "glm-5.2": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "first_party",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "z-ai/glm-5.2": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "first_party",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "zai/glm-5.2": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "first_party",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"off": false, "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "glm-5.3": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-5.3",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "z-ai/glm-5.3": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-5.3",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "zai/glm-5.3": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-5.3",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "glm-5.3-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-5.3",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "z-ai/glm-5.3-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-5.3",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "zai/glm-5.3-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/llm/glm-5.3",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "native_toggle_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "glm-4-plus": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "z-ai/glm-4-plus": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "zai/glm-4-plus": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "glm-4-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "z-ai/glm-4-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "zai/glm-4-flash": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "glm-4-9b": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "z-ai/glm-4-9b": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "zai/glm-4-9b": ShippedModelCapabilityDefault(
    source: "https://docs.z.ai/guides/capabilities/thinking-mode",
    routes: "native",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "claude-opus-4-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-opus-4.5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-opus-4.5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-opus-4-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-sonnet-4-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-sonnet-4.5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-sonnet-4.5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-sonnet-4-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-haiku-4-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-haiku-4.5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-haiku-4.5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-haiku-4-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-3-7-sonnet": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-3.7-sonnet": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-3-7-sonnet-20250219": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-3.7-sonnet-20250219": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-3.7-sonnet:thinking": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-3-7-sonnet": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-3.7-sonnet": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-3-7-sonnet-20250219": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "anthropic/claude-3.7-sonnet:thinking": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_budget", "options": <String, Object?>{"off": false, "low": 2048, "medium": 8192, "high": 16384}},
  ),
  "claude-opus-4-6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "claude-opus-4.6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "anthropic/claude-opus-4.6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "anthropic/claude-opus-4-6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "claude-sonnet-4-6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "claude-sonnet-4.6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "anthropic/claude-sonnet-4.6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "anthropic/claude-sonnet-4-6": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "claude-mythos-preview": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "anthropic/claude-mythos-preview": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high"}},
  ),
  "claude-opus-4-8": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "claude-opus-4.8": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "anthropic/claude-opus-4.8": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "anthropic/claude-opus-4-8": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "claude-opus-4-7": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "claude-opus-4.7": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "anthropic/claude-opus-4.7": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "anthropic/claude-opus-4-7": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "claude-sonnet-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "anthropic/claude-sonnet-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"off": false, "low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "claude-fable-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "anthropic/claude-fable-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "claude-mythos-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "anthropic/claude-mythos-5": ShippedModelCapabilityDefault(
    source: "https://platform.claude.com/docs/en/build-with-claude/thinking",
    routes: "any",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "anthropic_adaptive", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high", "max": "max"}},
  ),
  "gemini-4-argon": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "google/gemini-4-argon": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "gemini-3.8-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "google/gemini-3.8-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "gemini-3.6-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"minimal": "minimal", "low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "google/gemini-3.6-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"minimal": "minimal", "low": "low", "medium": "medium", "high": "high"}, "default_option": "medium"},
  ),
  "gemini-3.5-flash-lite": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"minimal": "minimal", "low": "low", "medium": "medium", "high": "high"}, "default_option": "minimal"},
  ),
  "google/gemini-3.5-flash-lite": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"minimal": "minimal", "low": "low", "medium": "medium", "high": "high"}, "default_option": "minimal"},
  ),
  "gemini-3-flash-preview": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"minimal": "minimal", "low": "low", "medium": "medium", "high": "high"}, "default_option": "high"},
  ),
  "google/gemini-3-flash-preview": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"minimal": "minimal", "low": "low", "medium": "medium", "high": "high"}, "default_option": "high"},
  ),
  "gemini-3.1-pro-preview": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "high"},
  ),
  "google/gemini-3.1-pro-preview": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "medium": "medium", "high": "high"}, "default_option": "high"},
  ),
  "gemini-3-pro-preview": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "high": "high"}, "default_option": "high"},
  ),
  "google/gemini-3-pro-preview": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": "low", "high": "high"}, "default_option": "high"},
  ),
  "gemini-2.5-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"off": 0, "low": 1024, "medium": 8192, "high": 24576}},
  ),
  "google/gemini-2.5-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"off": 0, "low": 1024, "medium": 8192, "high": 24576}},
  ),
  "gemini-2.5-pro": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": 1024, "medium": 8192, "high": 24576}},
  ),
  "google/gemini-2.5-pro": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "google_thinking", "options": <String, Object?>{"low": 1024, "medium": 8192, "high": 24576}},
  ),
  "gemini-1.5-pro": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "google/gemini-1.5-pro": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "gemini-1.5-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "google/gemini-1.5-flash": ShippedModelCapabilityDefault(
    source: "https://ai.google.dev/gemini-api/docs/thinking",
    routes: "google",
    thinkingControl: <String, Object?>{"status": "unsupported"},
  ),
  "deepseek-ai/deepseek-v4-flash": ShippedModelCapabilityDefault(
    source: "https://docs.api.nvidia.com/nim/reference/deepseek-ai-deepseek-v4-flash-infer",
    routes: "nim",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"none": "none", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "deepseek-ai/deepseek-v4-pro": ShippedModelCapabilityDefault(
    source: "https://docs.api.nvidia.com/nim/reference/deepseek-ai-deepseek-v4-pro-infer",
    routes: "nim",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"none": "none", "high": "high", "max": "max"}, "default_option": "high"},
  ),
  "moonshotai/kimi-k3": ShippedModelCapabilityDefault(
    source: "https://docs.api.nvidia.com/nim/reference/moonshotai-kimi-k3-infer",
    routes: "nim",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "openai_chat_effort", "options": <String, Object?>{"low": "low", "high": "high", "max": "max"}, "default_option": "max"},
  ),
  "moonshotai/kimi-k2.6": ShippedModelCapabilityDefault(
    source: "https://docs.api.nvidia.com/nim/reference/moonshotai-kimi-k2-6-infer",
    routes: "nim",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "nim_kimi_thinking", "options": <String, Object?>{"on": true, "off": false}},
  ),
  "qwen/qwen3.5-122b-a10b": ShippedModelCapabilityDefault(
    source: "docs/qa_maintenance/nvidia_thinking_wire_qa.md (git 2607a342) hosted NIM reference pages",
    routes: "nim",
    thinkingControl: <String, Object?>{"status": "supported", "wire": "nim_qwen_thinking", "options": <String, Object?>{"on": true, "off": false}},
  ),
};

class ShippedModelCapabilityDefault {
  const ShippedModelCapabilityDefault({required this.source, required this.routes, this.compatibleChat, required this.thinkingControl});
  final String source;
  final String routes;
  final String? compatibleChat;
  final Map<String, Object?> thinkingControl;
}
