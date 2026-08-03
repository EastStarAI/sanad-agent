import 'dart:io';

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
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
    if (tempWorkDir.existsSync()) {
      await tempWorkDir.delete(recursive: true);
    }
    if (tempSanadHome.existsSync()) {
      await tempSanadHome.delete(recursive: true);
    }
  });

  test('reads local gateway configuration from environment', () async {
    final envFile = File('${tempSanadHome.path}/.env');
    await envFile.writeAsString('''
ENABLE_LOCAL_GATEWAY=true
LOCAL_GATEWAY_PORT=59123
LLM_BASE_URL=http://127.0.0.1:11434
LLM_MODEL=gemma:2b
''');

    final config = Config();

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

    expect(Config().localGatewayUrl, 'http://[::1]:59123');
  });

  test(
    'source worktree always uses global env from SANAD_HOME even if local env exists',
    () {
      expect(getEnvPath(), '${tempSanadHome.path}/.env');

      File('${tempWorkDir.path}/.env').writeAsStringSync('LLM_MODEL=local');

      expect(getEnvPath(), '${tempSanadHome.path}/.env');
    },
  );

  test('treats local LLM setups as valid without an API key', () async {
    final envFile = File('${tempSanadHome.path}/.env');
    await envFile.writeAsString('''
LLM_BASE_URL=http://127.0.0.1:11434
LLM_MODEL=llama3
''');

    final config = Config();

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

  test('reads logging configuration from environment', () async {
    final envFile = File('${tempSanadHome.path}/.env');
    await envFile.writeAsString('''
LOG_LEVEL=ALL
LOG_COLOR=false
LOG_MAX_LENGTH=1000
''');

    final config = Config();

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
        'GATEWAY_URL': 'https://dev.api.sanad.eaststarai.com',
        'PORTAL_URL': 'https://dev.portal.sanad.eaststarai.com',
      },
    );
    expect(overridden.gatewayUrl, 'https://dev.api.sanad.eaststarai.com');
    expect(overridden.portalUrl, 'https://dev.portal.sanad.eaststarai.com');
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

      final config = Config();

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

      final config = Config();
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

        final config = Config();
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

        final config = Config();
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

        final config = Config();
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

        final config = Config();
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

        final config = Config();
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

        final config = Config();
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

        final config = Config();
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

      final config = Config();
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
}
