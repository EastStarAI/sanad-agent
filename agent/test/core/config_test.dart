import 'dart:isolate';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempWorkDir;
  late Directory tempSanadHome;
  late String originalCurrentDirectory;

  setUp(() async {
    originalCurrentDirectory = Directory.current.path;
    tempWorkDir = await Directory.systemTemp.createTemp(
      'sanadagent-config-test',
    );
    tempSanadHome = await Directory.systemTemp.createTemp(
      'sanadagent-home-test',
    );
    Directory.current = tempWorkDir.path;
    setSanadHomeOverride(tempSanadHome.path);
    setSanadStateHomeOverride(null);
  });

  tearDown(() async {
    Directory.current = originalCurrentDirectory;
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    try {
      if (tempWorkDir.existsSync()) {
        await tempWorkDir.delete(recursive: true);
      }
    } catch (_) {}
    try {
      if (tempSanadHome.existsSync()) {
        await tempSanadHome.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('reads local gateway configuration from environment', () async {
    final envFile = File('${tempSanadHome.path}/.env');
    await envFile.writeAsString('''
ENABLE_LOCAL_GATEWAY=true
LOCAL_GATEWAY_PORT=59123
LLM_BASE_URL=http://127.0.0.1:11434
LLM_MODEL=gemma:2b
''');

    final config = Config(environment: const {});

    expect(config.enableLocalGateway, isTrue);
    expect(config.localGatewayPort, equals(59123));
    expect(config.localGatewayHost, equals('127.0.0.1'));
    expect(config.localGatewayUrl, equals('http://127.0.0.1:59123'));
  });

  test('runtime state home defaults to Sanad home and supports isolation', () {
    expect(getSanadStateHome(), tempSanadHome.path);

    final isolatedState = '${tempWorkDir.path}/isolated-state';
    setSanadStateHomeOverride(isolatedState);

    expect(getSanadStateHome(), isolatedState);
    expect(getSanadHome(), tempSanadHome.path);
  });

  test('brackets an IPv6 local gateway authority', () {
    File('${tempSanadHome.path}/.env').writeAsStringSync('''
LOCAL_GATEWAY_HOST=::1
LOCAL_GATEWAY_PORT=59123
''');

    expect(Config(environment: const {}).localGatewayUrl, 'http://[::1]:59123');
  });

  test(
    'source worktree always uses global env from SANAD_HOME even if local env exists',
    () {
      expect(getEnvPath(), p.join(tempSanadHome.path, '.env'));

      File(
        p.join(tempWorkDir.path, '.env'),
      ).writeAsStringSync('LLM_MODEL=local');

      expect(getEnvPath(), p.join(tempSanadHome.path, '.env'));
    },
  );

  test('treats local LLM setups as valid without an API key', () async {
    final envFile = File('${tempSanadHome.path}/.env');
    await envFile.writeAsString('''
LLM_BASE_URL=http://127.0.0.1:11434
LLM_MODEL=llama3
''');

    final config = Config(environment: const {});

    expect(config.llmApiKey, isEmpty);
    expect(config.usesLikelyLocalLlm, isTrue);
    expect(config.isValid, isTrue);
  });

  test('prefers explicit process environment values over .env files', () async {
    final envFile = File('${tempSanadHome.path}/.env');
    await envFile.writeAsString('''
ENABLE_LOCAL_GATEWAY=true
LOCAL_GATEWAY_PORT=58085
LLM_BASE_URL=http://127.0.0.1:11434
LLM_MODEL=gemma:2b
''');

    final config = Config(
      environment: {
        'ENABLE_LOCAL_GATEWAY': 'true',
        'LOCAL_GATEWAY_PORT': '59234',
        'LLM_BASE_URL': 'http://127.0.0.1:2244',
        'LLM_MODEL': 'override-model',
      },
    );

    expect(config.localGatewayPort, equals(59234));
    expect(config.llmBaseUrl, equals('http://127.0.0.1:2244'));
    expect(config.llmModel, equals('override-model'));
  });

  group('model-aware context compaction YAML', () {
    test('loads defaults and exact per-model overrides from config.yaml', () {
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync('''
context:
  modelLimits:
    gpt-5.6-sol: 258000
    gpt-4o: 128000
compaction:
  threshold: 0.90
  targetRatio: 0.10
  models:
    gpt-5.6-sol:
      threshold: 0.85
      targetRatio: 0.08
    gpt-4o:
      threshold: 0.75
''');

      final config = Config(environment: const {});

      expect(config.contextModelLimit(' GPT-5.6-SOL '), 258000);
      expect(config.contextModelLimit('gpt-4o'), 128000);
      expect(config.contextModelLimit('unlisted'), isNull);
      expect(config.compactionPolicyForModel('gpt-5.6-sol').threshold, 0.85);
      expect(config.compactionPolicyForModel('gpt-5.6-sol').targetRatio, 0.08);
      expect(config.compactionPolicyForModel('gpt-4o').threshold, 0.75);
      expect(config.compactionPolicyForModel('gpt-4o').targetRatio, 0.10);
      expect(config.compactionPolicyForModel('unlisted').threshold, 0.90);
      expect(config.compactionPolicyForModel('unlisted').targetRatio, 0.10);
    });

    test('ignores legacy CONTEXT_LIMIT and rejects conflicting YAML keys', () {
      File(
        '${tempSanadHome.path}/.env',
      ).writeAsStringSync('CONTEXT_LIMIT=999999\n');
      expect(Config(environment: const {}).contextModelLimit('gpt-4o'), isNull);

      for (final yaml in [
        'compaction:\n  thresholdTokens: 1000\n',
        'compaction:\n  modelThresholds: {}\n',
        'compaction:\n  threshold: 1.0\n',
        'context:\n  modelLimits:\n    gpt-4o: 0\n',
      ]) {
        File('${tempSanadHome.path}/config.yaml').writeAsStringSync(yaml);
        expect(
          () => Config(environment: const {}),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });

  test('reads logging configuration from environment', () async {
    final envFile = File('${tempSanadHome.path}/.env');
    await envFile.writeAsString('''
LOG_LEVEL=ALL
LOG_COLOR=false
LOG_MAX_LENGTH=1000
''');

    final config = Config(environment: const {});

    expect(config.logLevel, equals('ALL'));
    expect(config.logColor, isFalse);
    expect(config.logMaxLength, equals(1000));
  });

  test('uses EastStar cloud defaults and accepts internal overrides', () {
    final defaults = Config(environment: const {});
    expect(defaults.gatewayUrl, 'https://api.sanad.eaststarai.com');
    expect(defaults.portalUrl, 'https://portal.sanad.eaststarai.com');

    final overridden = Config(
      environment: const {
        'GATEWAY_URL': 'https://gateway.internal.example',
        'PORTAL_URL': 'https://portal.internal.example',
      },
    );
    expect(overridden.gatewayUrl, 'https://gateway.internal.example');
    expect(overridden.portalUrl, 'https://portal.internal.example');
  });

  test(
    'ignores local project config and only uses global home config',
    () async {
      // 1. Create a global .env file in tempSanadHome
      final globalEnvFile = File('${tempSanadHome.path}/.env');
      await globalEnvFile.writeAsString('''
LLM_MODEL=global-model
LOCAL_GATEWAY_PORT=55555
''');

      // 2. Create a local .env file in tempWorkDir
      final localEnvFile = File('${tempWorkDir.path}/.env');
      await localEnvFile.writeAsString('''
LLM_MODEL=local-model
''');

      final config = Config(environment: const {});

      // The global LLM_MODEL should be loaded; local should be ignored.
      expect(config.llmModel, equals('global-model'));
      expect(config.localGatewayPort, equals(55555));
    },
  );

  group('Dynamic Provider Credentials Resolution', () {
    test('resolves provider-specific key and falls back correctly', () async {
      final envFile = File('${tempSanadHome.path}/.env');
      await envFile.writeAsString('''
ACTIVE_PROVIDER=openrouter
OPENROUTER_API_KEY=sk-or-testkey
LLM_API_KEY=sk-openai-fallback
''');

      final config = Config(environment: const {});
      expect(config.activeProvider, equals('openrouter'));
      expect(config.resolveProviderName(), equals('openrouter'));
      expect(config.llmApiKey, equals('sk-or-testkey'));
    });

    test(
      'falls back to LLM_API_KEY if provider-specific key is missing',
      () async {
        final envFile = File('${tempSanadHome.path}/.env');
        await envFile.writeAsString('''
ACTIVE_PROVIDER=openrouter
LLM_API_KEY=sk-openai-fallback
''');

        final config = Config(environment: const {});
        expect(config.activeProvider, equals('openrouter'));
        expect(config.llmApiKey, equals('sk-openai-fallback'));
      },
    );

    test(
      'uses provider profile default base URL if LLM_BASE_URL is not set',
      () async {
        final envFile = File('${tempSanadHome.path}/.env');
        await envFile.writeAsString('''
ACTIVE_PROVIDER=deepseek
''');

        final config = Config(environment: const {});
        expect(config.resolveProviderName(), equals('deepseek'));
        expect(config.llmBaseUrl, equals('https://api.deepseek.com'));
      },
    );

    test(
      'overrides default base URL if LLM_BASE_URL is explicitly set',
      () async {
        final envFile = File('${tempSanadHome.path}/.env');
        await envFile.writeAsString('''
ACTIVE_PROVIDER=deepseek
LLM_BASE_URL=https://custom-deepseek-proxy.internal
''');

        final config = Config(environment: const {});
        expect(
          config.llmBaseUrl,
          equals('https://custom-deepseek-proxy.internal'),
        );
      },
    );

    test(
      'dynamically detects provider from LLM_BASE_URL if ACTIVE_PROVIDER is omitted',
      () async {
        final envFile = File('${tempSanadHome.path}/.env');
        await envFile.writeAsString('''
LLM_BASE_URL=https://openrouter.ai/api/v1
''');

        final config = Config(environment: const {});
        expect(config.resolveProviderName(), equals('openrouter'));
      },
    );

    test(
      'resolves specific provider model and base URL if configured',
      () async {
        final envFile = File('${tempSanadHome.path}/.env');
        await envFile.writeAsString('''
ACTIVE_PROVIDER=openai
OPENAI_MODEL=gpt-4o-latest
OPENAI_API_BASE=https://custom-openai-proxy.com/v1
LLM_MODEL=gpt-3.5-turbo
LLM_BASE_URL=https://generic-api.com/v1
''');

        final config = Config(environment: const {});
        expect(config.llmModel, equals('gpt-4o-latest'));
        expect(config.llmBaseUrl, equals('https://custom-openai-proxy.com/v1'));
      },
    );
  });

  group('Live env reload via mtime invalidation (_ensureFreshEnv)', () {
    test(
      'picks up new ACTIVE_PROVIDER after the .env file is modified on disk',
      () async {
        final envFile = File('${tempSanadHome.path}/.env');
        await envFile.writeAsString('''
ACTIVE_PROVIDER=openai
LLM_MODEL=gpt-4o
''');

        final config = Config(environment: const {});
        expect(config.activeProvider, equals('openai'));
        expect(config.llmModel, equals('gpt-4o'));

        // Ensure the mtime advances by at least 1 second on filesystems with
        // second-resolution mtime (HFS+/FAT). Await a delay then rewrite.
        await Future<void>.delayed(const Duration(seconds: 1));
        await envFile.writeAsString('''
ACTIVE_PROVIDER=anthropic
LLM_MODEL=claude-3-5-sonnet
''');

        expect(config.activeProvider, equals('anthropic'));
        expect(config.llmModel, equals('claude-3-5-sonnet'));
      },
    );

    test(
      'does NOT reload when the .env file is unchanged between two reads',
      () async {
        final envFile = File('${tempSanadHome.path}/.env');
        await envFile.writeAsString('''
ACTIVE_PROVIDER=openai
LLM_MODEL=gpt-4o
''');

        final config = Config(environment: const {});
        final firstModel = config.llmModel;
        // Read again immediately — no disk change → same value, no reload.
        final secondModel = config.llmModel;
        expect(secondModel, equals(firstModel));
        expect(secondModel, equals('gpt-4o'));
      },
    );

    test('reload() forces a fresh read of the .env file', () async {
      final envFile = File('${tempSanadHome.path}/.env');
      await envFile.writeAsString('''
ACTIVE_PROVIDER=openai
LLM_MODEL=gpt-4o
''');

      final config = Config(environment: const {});
      expect(config.llmModel, equals('gpt-4o'));

      // Rewrite with the same mtime bucket (no forced delay) and call reload().
      await envFile.writeAsString('''
ACTIVE_PROVIDER=openai
LLM_MODEL=gpt-4o-mini
''');
      config.reload();

      expect(config.llmModel, equals('gpt-4o-mini'));
    });
  });

  group('model_capabilities exact-route configuration', () {
    const validConfigYaml = '''
model_capabilities:
  "claude-3-5-haiku:beta":
    supports_image_input: true
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        low: low
        medium: medium
        high: high
      default_option: medium
  "text-only-model":
    supports_image_input: false
    thinking_control:
      status: unsupported
  "llama3.2:3b":
    thinking_control:
      status: unknown
''';

    test(
      'parses model-only model_capabilities with exact model ID containing colons',
      () {
        File(
          '${tempSanadHome.path}/config.yaml',
        ).writeAsStringSync(validConfigYaml);
        final config = Config(environment: const {});

        final override1 = config.modelAwarePolicy.capabilityOverrideFor(
          'claude-3-5-haiku:beta',
        );
        expect(override1, isNotNull);
        expect(override1!.supportsImageInput, isTrue);
        expect(
          override1.thinkingControl?.status,
          ThinkingCapabilityStatus.supported,
        );
        expect(override1.thinkingControl?.wire, 'openai_chat_effort');
        expect(override1.thinkingControl?.options, {
          'low': 'low',
          'medium': 'medium',
          'high': 'high',
        });
        expect(override1.thinkingControl?.defaultOption, 'medium');

        final override2 = config.modelAwarePolicy.capabilityOverrideFor(
          'text-only-model',
        );
        expect(override2, isNotNull);
        expect(override2!.supportsImageInput, isFalse);
        expect(
          override2.thinkingControl?.status,
          ThinkingCapabilityStatus.unsupported,
        );
        expect(override2.thinkingControl?.wire, isNull);
        expect(override2.thinkingControl?.options, isEmpty);

        final override3 = config.modelAwarePolicy.capabilityOverrideFor(
          'llama3.2:3b',
        );
        expect(override3, isNotNull);
        expect(override3!.supportsImageInput, isNull);
        expect(
          override3.thinkingControl?.status,
          ThinkingCapabilityStatus.unknown,
        );
      },
    );

    test('offline lookup for unconfigured model returns null', () {
      File(
        '${tempSanadHome.path}/config.yaml',
      ).writeAsStringSync(validConfigYaml);
      final config = Config(environment: const {});

      expect(
        config.modelAwarePolicy.capabilityOverrideFor(
          'unconfigured-model',
        ),
        isNull,
      );
    });

    test('actionably rejects retired nested provider-instance format in model_capabilities', () {
      const nestedYaml = '''
model_capabilities:
  "inst-uuid-1":
    "claude-3-5-haiku:beta":
      supports_image_input: true
''';
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync(nestedYaml);
      expect(
        () => Config(environment: const {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Nested provider-instance format in model_capabilities is no longer supported'),
          ),
        ),
      );
    });

    test('supports colon IDs in model map', () {
      const colonYaml = '''
model_capabilities:
  "urn:model:beta:1":
    supports_image_input: true
''';
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync(colonYaml);
      final config = Config(environment: const {});
      final override = config.modelAwarePolicy.capabilityOverrideFor(
        'urn:model:beta:1',
      );
      expect(override?.supportsImageInput, isTrue);
    });

    test('preserves case-distinct model IDs without lowercase conflation', () {
      const caseYaml = '''
model_capabilities:
  "Model-A":
    supports_image_input: true
  "model-a":
    supports_image_input: false
''';
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync(caseYaml);
      final config = Config(environment: const {});
      expect(
        config.modelAwarePolicy
            .capabilityOverrideFor('Model-A')
            ?.supportsImageInput,
        isTrue,
      );
      expect(
        config.modelAwarePolicy
            .capabilityOverrideFor('model-a')
            ?.supportsImageInput,
        isFalse,
      );
      expect(
        config.modelAwarePolicy.capabilityOverrideFor('MODEL-A'),
        isNull,
      );
    });

    test('single model override applies across multiple provider routes, rename and recreation', () {
      const sharedYaml = '''
model_capabilities:
  "claude-haiku-4.5":
    supports_image_input: true
''';
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync(sharedYaml);
      final config = Config(environment: const {});
      final override = config.modelAwarePolicy.capabilityOverrideFor('claude-haiku-4.5');
      expect(override?.supportsImageInput, isTrue);
    });

    test('preserves unrelated root entries in config.yaml', () {
      const unrelatedYaml = '''
unrelated_root_feature:
  enabled: true
context:
  modelLimits:
    gpt-4o: 128000
model_capabilities:
  "model-1":
    supports_image_input: true
''';
      File(
        '${tempSanadHome.path}/config.yaml',
      ).writeAsStringSync(unrelatedYaml);
      final config = Config(environment: const {});
      expect(
        config.modelAwarePolicy
            .capabilityOverrideFor('model-1')
            ?.supportsImageInput,
        isTrue,
      );
      expect(config.contextModelLimit('gpt-4o'), 128000);
    });

    test(
      'deterministic fingerprint changes when options change on same wire',
      () {
        const tc1 = ThinkingControlOverride(
          status: ThinkingCapabilityStatus.supported,
          wire: 'openai_chat_effort',
          options: {'low': 'low', 'high': 'high'},
        );
        const tc2 = ThinkingControlOverride(
          status: ThinkingCapabilityStatus.supported,
          wire: 'openai_chat_effort',
          options: {'low': 'low', 'high': 'high', 'medium': 'medium'},
        );
        const tc3 = ThinkingControlOverride(
          status: ThinkingCapabilityStatus.supported,
          wire: 'openai_chat_effort',
          options: {'low': 'low', 'high': 'high'},
          defaultOption: 'high',
        );
        expect(tc1.fingerprint, isNot(equals(tc2.fingerprint)));
        expect(tc1.fingerprint, isNot(equals(tc3.fingerprint)));
      },
    );

    test('rejects misleading off-conflict and tier escalation', () {
      for (final badYaml in [
        '''
model_capabilities:
  "gpt-4":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options: {off: high}
''',
        '''
model_capabilities:
  "gpt-4":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options: {low: high}
''',
        '''
model_capabilities:
  "claude-3-7":
    thinking_control:
      status: supported
      wire: anthropic_budget
      options: {budget: 500}
''',
      ]) {
        File('${tempSanadHome.path}/config.yaml').writeAsStringSync(badYaml);
        expect(
          () => Config(environment: const {}),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects wildcard model keys', () {
      for (final badYaml in [
        '''
model_capabilities:
  "*":
    supports_image_input: true
''',
        '''
model_capabilities:
  "gpt-*":
    supports_image_input: true
''',
      ]) {
        File('${tempSanadHome.path}/config.yaml').writeAsStringSync(badYaml);
        expect(
          () => Config(environment: const {}),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Wildcard'),
            ),
          ),
        );
      }
    });

    test(
      'rejects duplicated context limits or unknown keys in model_capabilities',
      () {
        const badYaml = '''
model_capabilities:
  "gpt-4":
    context_window: 128000
''';
        File('${tempSanadHome.path}/config.yaml').writeAsStringSync(badYaml);
        expect(
          () => Config(environment: const {}),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(
                'Unknown model_capabilities.gpt-4 key: context_window',
              ),
            ),
          ),
        );
      },
    );

    test('rejects unsupported/unknown status declaring wire or options', () {
      const badYaml = '''
model_capabilities:
  "gpt-4":
    thinking_control:
      status: unsupported
      wire: openai_chat_effort
''';
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync(badYaml);
      expect(
        () => Config(environment: const {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('cannot declare wire'),
          ),
        ),
      );
    });

    test(
      'rejects unknown wire policies and invalid budget/default options',
      () {
        for (final badYaml in [
          '''
model_capabilities:
  "gpt-4":
    thinking_control:
      status: supported
      wire: unknown_wire
      options: {low: low}
''',
          '''
model_capabilities:
  "claude-3-7":
    thinking_control:
      status: supported
      wire: anthropic_budget
      options: {low: -500}
''',
          '''
model_capabilities:
  "gpt-4":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options: {low: low}
      default_option: missing
''',
        ]) {
          File('${tempSanadHome.path}/config.yaml').writeAsStringSync(badYaml);
          expect(
            () => Config(environment: const {}),
            throwsA(isA<FormatException>()),
          );
        }
      },
    );

    test(
      'reloadModelAwarePolicy retains prior validated snapshot on malformed reload',
      () {
        final configFile = File('${tempSanadHome.path}/config.yaml');
        configFile.writeAsStringSync(validConfigYaml);
        final config = Config(environment: const {});

        final initialOverride = config.modelAwarePolicy.capabilityOverrideFor(
          'claude-3-5-haiku:beta',
        );
        expect(initialOverride?.supportsImageInput, isTrue);

        // Now corrupt config.yaml on disk
        configFile.writeAsStringSync('corrupted: yaml: content: [');
        expect(
          () => config.reloadModelAwarePolicy(),
          throwsA(isA<FormatException>()),
        );

        // Prior validated snapshot is preserved
        final retainedOverride = config.modelAwarePolicy.capabilityOverrideFor(
          'claude-3-5-haiku:beta',
        );
        expect(retainedOverride?.supportsImageInput, isTrue);
      },
    );

    test(
      'ThinkingControlOverride.fingerprint uses deterministic structural SHA-256 digest',
      () {
        const tc1 = ThinkingControlOverride(
          status: ThinkingCapabilityStatus.supported,
          wire: 'openai_chat_effort',
          options: {'low': 'low', 'high': 'high'},
          defaultOption: 'low',
        );
        const tc2 = ThinkingControlOverride(
          status: ThinkingCapabilityStatus.supported,
          wire: 'openai_chat_effort',
          options: {'high': 'high', 'low': 'low'},
          defaultOption: 'low',
        );
        expect(tc1.fingerprint, equals(tc2.fingerprint));
        expect(tc1.fingerprint, hasLength(64));

        const cap1 = ModelCapabilityOverride(
          supportsImageInput: true,
          thinkingControl: tc1,
        );
        const cap2 = ModelCapabilityOverride(
          supportsImageInput: true,
          thinkingControl: tc2,
        );
        expect(cap1.fingerprint, equals(cap2.fingerprint));
        expect(cap1.fingerprint, hasLength(64));
      },
    );

    test('anthropic_budget admits only a Boolean false Off and '
        'native_toggle_effort validates toggles and efforts', () {
      final budget = ThinkingControlOverride.parse({
        'status': 'supported',
        'wire': 'anthropic_budget',
        'options': {'off': false, 'low': 2048},
      });
      expect(budget.options, {'off': false, 'low': 2048});

      final native = ThinkingControlOverride.parse({
        'status': 'supported',
        'wire': 'native_toggle_effort',
        'options': {'off': false, 'low': 'low', 'max': 'max'},
        'default_option': 'max',
      });
      expect(native.options, {'off': false, 'low': 'low', 'max': 'max'});
      for (final bad in [
        {'off': true},
        {'on': false},
        {'high': true},
        {'low': 'high'},
        {'off': 'low'},
        {'low': 'none'},
      ]) {
        expect(
          () => ThinkingControlOverride.parse({
            'status': 'supported',
            'wire': 'native_toggle_effort',
            'options': bad,
          }),
          throwsA(isA<FormatException>()),
          reason: '$bad',
        );
      }
    });

    test('the shipped config.example.yaml override parses', () {
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync(
        File.fromUri(
          Isolate.resolvePackageUriSync(
            Uri.parse('package:sanad_agent/'),
          )!.resolve('../config.example.yaml'),
        ).readAsStringSync(),
      );
      final config = Config(environment: const {});
      final control = config.modelAwarePolicy
          .capabilityOverrideFor('deepseek-v4.1-flash')
          ?.thinkingControl;
      expect(control?.wire, 'native_toggle_effort');
      expect(control?.defaultOption, 'high');
    });

    test('rejects off/none option under anthropic_budget wire', () {
      const badBudgetYaml = '''
model_capabilities:
  "claude":
    thinking_control:
      status: supported
      wire: anthropic_budget
      options:
        off: 1024
''';
      File(
        '${tempSanadHome.path}/config.yaml',
      ).writeAsStringSync(badBudgetYaml);
      expect(
        () => Config(environment: const {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(
              'anthropic_budget wire does not support disabling thinking',
            ),
          ),
        ),
      );
    });

    test('validates and rejects fake-off for toggle_effort, anthropic_adaptive, and google_thinking', () {
      for (final badYaml in [
        // toggle_effort fake-off
        '''
model_capabilities:
  "model-1":
    thinking_control:
      status: supported
      wire: toggle_effort
      options: {off: true}
''',
        '''
model_capabilities:
  "model-1":
    thinking_control:
      status: supported
      wire: toggle_effort
      options: {none: "on"}
''',
        '''
model_capabilities:
  "model-1":
    thinking_control:
      status: supported
      wire: toggle_effort
      options: {on: false}
''',
        // anthropic_adaptive fake-off and invalid values
        '''
model_capabilities:
  "claude":
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options: {off: high}
''',
        '''
model_capabilities:
  "claude":
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options: {none: low}
''',
        '''
model_capabilities:
  "claude":
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options: {low: off}
''',
        '''
model_capabilities:
  "claude":
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options: {low: true}
''',
        '''
model_capabilities:
  "claude":
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options: {low: high}
''',
        // google_thinking fake-off and invalid values
        '''
model_capabilities:
  "gemini":
    thinking_control:
      status: supported
      wire: google_thinking
      options: {off: 2048}
''',
        '''
model_capabilities:
  "gemini":
    thinking_control:
      status: supported
      wire: google_thinking
      options: {off: high}
''',
        '''
model_capabilities:
  "gemini":
    thinking_control:
      status: supported
      wire: google_thinking
      options: {none: low}
''',
        '''
model_capabilities:
  "gemini":
    thinking_control:
      status: supported
      wire: google_thinking
      options: {low: 0}
''',
        '''
model_capabilities:
  "gemini":
    thinking_control:
      status: supported
      wire: google_thinking
      options: {low: -1}
''',
        '''
model_capabilities:
  "gemini":
    thinking_control:
      status: supported
      wire: google_thinking
      options: {low: 10.5}
''',
        // openai_chat_effort fake-off
        '''
model_capabilities:
  "gpt-4":
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options: {low: none}
''',
      ]) {
        File('${tempSanadHome.path}/config.yaml').writeAsStringSync(badYaml);
        expect(
          () => Config(environment: const {}),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('accepts valid options for toggle_effort, anthropic_adaptive, and google_thinking', () {
      const goodYaml = '''
model_capabilities:
  "m-toggle":
    thinking_control:
      status: supported
      wire: toggle_effort
      options:
        off: "off"
        on: "on"
      default_option: off
  "m-adaptive":
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options:
        off: "off"
        low: "low"
        medium: "medium"
        high: "high"
      default_option: low
  "m-google":
    thinking_control:
      status: supported
      wire: google_thinking
      options:
        off: 0
        low: "low"
        high: "high"
        budget: 2048
      default_option: low
''';
      File('${tempSanadHome.path}/config.yaml').writeAsStringSync(goodYaml);
      final config = Config(environment: const {});
      final policy = config.modelAwarePolicy;

      final toggle = policy.capabilityOverrideFor('m-toggle')!.thinkingControl!;
      expect(toggle.wire, 'toggle_effort');
      expect(toggle.options, {'off': false, 'on': true});
      expect(toggle.defaultOption, 'off');

      final adaptive = policy.capabilityOverrideFor('m-adaptive')!.thinkingControl!;
      expect(adaptive.wire, 'anthropic_adaptive');
      expect(adaptive.options, {'off': 'off', 'low': 'low', 'medium': 'medium', 'high': 'high'});
      expect(adaptive.defaultOption, 'low');

      final google = policy.capabilityOverrideFor('m-google')!.thinkingControl!;
      expect(google.wire, 'google_thinking');
      expect(google.options, {'off': 0, 'low': 'low', 'high': 'high', 'budget': 2048});
      expect(google.defaultOption, 'low');
    });
  });
}
