import 'dart:convert';

import 'package:sanad_agent/cli/models/provider_selector.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

ProviderInstance _instance({
  required String id,
  required String templateId,
  required String displayName,
  required String defaultModel,
  bool isDefault = false,
}) => ProviderInstance(
  id: id,
  templateId: templateId,
  displayName: displayName,
  protocol: 'openai',
  authMethod: 'api_key',
  defaultModel: defaultModel,
  status: 'ready',
  isDefault: isDefault,
  configRevision: 1,
  credentialRevision: 1,
  requestsPerMinute: 60,
  allowAutoFailover: false,
  createdAt: DateTime.utc(2026, 10, 22),
  updatedAt: DateTime.utc(2026, 10, 22),
);

void main() {
  useIsolatedSanadTestHome();

  late StringBuffer out;
  late StringBuffer err;

  final openCode = _instance(
    id: '03d73aab-7b1f-4530-bbf4-2119b112630d',
    templateId: 'opencode-go',
    displayName: 'OpenCode Go',
    defaultModel: 'deepseek-v4.1-flash',
    isDefault: true,
  );
  final zai = _instance(
    id: '70ff7580-b456-4abb-b87b-63c1a25df59a',
    templateId: 'zai-coding',
    displayName: 'Z.AI Coding Plan',
    defaultModel: 'glm-5.2',
  );

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();

    final db = AgentStateDatabase.atPath(getSanadStateHome());
    try {
      final repo = ProviderInstanceRepository(db);
      repo.createInstance(openCode);
      repo.createInstance(zai);
      repo.upsertModelCache(
        instanceId: openCode.id,
        cacheKey: 'models',
        models: [
          {'value': 'deepseek-v4.1-flash', 'label': 'Deepseek V4.1 Flash'},
          {'value': 'kimi-k3', 'label': 'Kimi K3', 'supports_reasoning': true},
        ],
        fetchedAt: DateTime.utc(2026, 10, 22),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
      repo.upsertModelCache(
        instanceId: zai.id,
        cacheKey: 'models',
        models: [
          {'value': 'glm-5.2', 'label': 'Glm 5.2'},
          {'value': 'glm-5.3', 'label': 'Glm 5.3'},
        ],
        fetchedAt: DateTime.utc(2026, 10, 22),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
    } finally {
      db.dispose();
    }
  });

  Future<int> runModels(List<String> args) => SanadCommandRunner(
    stdoutSink: out,
    stderrSink: err,
  ).run(['models', ...args]);

  Iterable<String> providerLines(String text) =>
      const LineSplitter().convert(text).where((line) => line.contains('• Provider'));

  group('sanad models provider filtering', () {
    test('without a filter it still reports every configured provider', () async {
      expect(await runModels([]), 0);
      final lines = providerLines(out.toString()).toList();
      expect(lines, hasLength(2));
      expect(lines.first, contains('OpenCode Go'));
      expect(out.toString(), contains('glm-5.2'));
    });

    test('--provider <template id> reports exactly one provider', () async {
      expect(await runModels(['--provider', 'opencode-go']), 0);
      final lines = providerLines(out.toString()).toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('opencode-go'));
      expect(out.toString(), contains('kimi-k3'));
      expect(out.toString(), isNot(contains('glm-5.2')));
    });

    test('--provider accepts the instance id and the display name alike', () async {
      expect(await runModels(['--provider', openCode.id]), 0);
      final byId = out.toString();
      out.clear();

      expect(await runModels(['--provider', '  opencode   go ']), 0);
      final byName = out.toString();

      expect(byName, byId);
      expect(providerLines(byName).single, contains('OpenCode Go'));
    });

    test('--provider uses the first matching tier deterministically', () {
      final resolution = ProviderSelector.resolve([openCode, zai], 'zai-coding');
      expect(resolution, isA<ProviderSelectorMatch>());
      expect((resolution as ProviderSelectorMatch).instance.id, zai.id);
    });

    test('an unknown selector fails closed with actionable stderr', () async {
      expect(await runModels(['--provider', 'nope']), 2);
      expect(providerLines(out.toString()), isEmpty);
      expect(err.toString(), contains('does not match any configured provider'));
      expect(err.toString(), contains('opencode-go'));
      expect(err.toString(), contains('zai-coding'));
    });

    test('an ambiguous selector is an error, never a guess', () async {
      final twinA = _instance(
        id: 'twin-a',
        templateId: 'custom',
        displayName: 'Same Name',
        defaultModel: 'm-a',
      );
      final twinB = _instance(
        id: 'twin-b',
        templateId: 'custom',
        displayName: 'Same Name',
        defaultModel: 'm-b',
      );
      final resolution = ProviderSelector.resolve([twinA, twinB], 'Same Name');
      expect(resolution, isA<ProviderSelectorAmbiguous>());
      expect((resolution as ProviderSelectorAmbiguous).candidates, hasLength(2));
    });
  });

  group('sanad models model filtering', () {
    test('--model narrows the catalog inside the selected provider', () async {
      expect(
        await runModels(['--provider', 'opencode-go', '--model', 'kimi-k3']),
        0,
      );
      final text = out.toString();
      expect(providerLines(text), hasLength(1));
      expect(text, contains('Available Models (1)'));
      expect(text, contains('    - kimi-k3'));
      expect(text, isNot(contains('    - deepseek-v4.1-flash')));
    });

    test('--model from another provider fails with a usage error', () async {
      expect(await runModels(['--provider', 'opencode-go', '--model', 'glm-5.3']), 2);
      expect(out.toString(), isEmpty);
      expect(err.toString(), contains('is not in the cached catalog'));
    });
  });

  group('sanad models JSON output', () {
    test('--json emits one machine-readable object for the selection', () async {
      expect(await runModels(['--provider', 'opencode-go', '--json']), 0);
      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded['schema'], 'sanad.models.v1');
      final providers = decoded['providers'] as List<dynamic>;
      expect(providers, hasLength(1));
      final provider = providers.single as Map<String, dynamic>;
      expect(provider['template_id'], 'opencode-go');
      expect(provider['catalog_source'], 'live');
      final models = provider['models'] as List<dynamic>;
      expect(models, hasLength(2));
      expect(
        models.map((model) => (model as Map<String, dynamic>)['value']),
        containsAll(['deepseek-v4.1-flash', 'kimi-k3']),
      );
      expect(
        models
            .cast<Map<String, dynamic>>()
            .firstWhere((model) => model['value'] == 'deepseek-v4.1-flash')['is_default'],
        isTrue,
      );
    });
  });
}
