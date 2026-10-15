import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

void main() {
  test('AgentCapabilities defaults advertise model-scoped thinking source', () {
    final capabilities = AgentCapabilities(displayName: 'Sanad Agent');

    expect(capabilities.thinkingModeSource, 'model');
    expect(capabilities.thinkingModes, isEmpty);
    expect(
      capabilities.toJson()['capabilities']['thinking_mode_source'],
      'model',
    );
    expect(
      capabilities.toJson()['capabilities']['thinking_modes_list'],
      isEmpty,
    );
  });
}
