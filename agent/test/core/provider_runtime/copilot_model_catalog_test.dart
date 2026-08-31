import 'package:sanad_agent/core/provider_runtime/copilot_model_catalog.dart';
import 'package:test/test.dart';

void main() {
  test('keeps enabled streaming tool-call models and their context limits', () {
    final models = CopilotModelCatalog.parseList({
      'data': [
        {
          'id': 'gpt-4o',
          'capabilities': {
            'limits': {'max_context_window_tokens': 128000},
            'supports': {
              'streaming': true,
              'tool_calls': true,
              'vision': true,
            },
          },
          'policy': {'state': 'enabled'},
        },
        {
          'id': 'claude-sonnet-4.6',
          'capabilities': {
            'supports': {'streaming': true, 'tool_calls': true},
          },
        },
      ],
    });
    expect(models.map((model) => model.id), ['gpt-4o', 'claude-sonnet-4.6']);
    expect(models.first.contextLimit, 128000);
    expect(models.first.vision, isTrue);
  });

  test('drops disabled, non-streaming, and non-tool models', () {
    final models = CopilotModelCatalog.parseList({
      'data': [
        {
          'id': 'blocked',
          'policy': {'state': 'disabled'},
          'capabilities': {
            'supports': {'streaming': true, 'tool_calls': true},
          },
        },
        {
          'id': 'unconfigured',
          'policy': {'state': 'unconfigured'},
          'capabilities': {
            'supports': {'streaming': true, 'tool_calls': true},
          },
        },
        {
          'id': 'no-tools',
          'capabilities': {
            'supports': {'streaming': true, 'tool_calls': false},
          },
        },
        {
          'id': 'no-stream',
          'capabilities': {
            'supports': {'streaming': false, 'tool_calls': true},
          },
        },
        {
          'id': 'hidden',
          'model_picker_enabled': false,
          'capabilities': {
            'supports': {'streaming': true, 'tool_calls': true},
          },
        },
        {
          'id': 'ok',
          'capabilities': {
            'supports': {'streaming': true, 'tool_calls': true},
          },
        },
      ],
    });
    expect(models.map((model) => model.id), ['ok']);
  });
}
