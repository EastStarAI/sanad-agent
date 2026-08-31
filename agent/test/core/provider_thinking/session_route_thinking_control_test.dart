import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/session_route_thinking_control.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ThinkingSelectionResolver resolver;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    final registry = buildProviderThinkingRegistry();
    final assembler = ThinkingCapabilityAssembler(registry);
    resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
    );
    repo.createInstance(
      ProviderInstance(
        id: 'inst-1',
        templateId: 'openai',
        displayName: 'OpenAI',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
  });

  tearDown(() => state.dispose());

  test('resolveSessionRouteThinkingControl returns supported descriptor map', () {
    final control = resolveSessionRouteThinkingControl(
      resolver: resolver,
      session: SessionState(
        sessionId: 'session-1',
        model: 'o3',
        providerId: 'inst-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );

    expect(control?['status'], 'supported');
    expect(control?['kind'], 'effort');
  });

  test('buildSessionPayload includes thinking_control when provided', () {
    final payload = buildSessionPayload(
      session: SessionState(
        sessionId: 'session-1',
        model: 'o3',
        providerId: 'inst-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      thinkingControl: const {
        'status': 'supported',
        'kind': 'effort',
        'options': [
          {'id': 'low', 'label': 'Low'},
        ],
        'capability_revision': 'rev-1',
        'source': 'profile',
      },
    );

    expect(payload['thinking_control'], isNotNull);
    expect(payload['thinking_control']['status'], 'supported');
  });
}
