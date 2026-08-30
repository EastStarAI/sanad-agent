import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/missing_provider_adapter.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory sanadHome;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    sanadHome = await Directory.systemTemp.createTemp(
      'sanad-live-default-adapter-',
    );
    setSanadHomeOverride(sanadHome.path);
    setSanadStateHomeOverride(null);
    setupDI();
  });

  tearDown(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (sanadHome.existsSync()) {
      await sanadHome.delete(recursive: true);
    }
  });

  test(
    'first runner after onboarding resolves a live default without DI reset',
    () {
      final preOnboardingAdapter = getIt<LLMAdapter>();
      final titleService = getIt<TitleService>();

      expect(preOnboardingAdapter, isA<MissingProviderAdapter>());
      expect(titleService, isNotNull);

      getIt<ProviderInstanceRepository>().createInstance(
        ProviderInstance(
          id: 'provider-after-onboarding',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          baseUrl: 'https://api.openai.com/v1',
          defaultModel: 'gpt-4o',
          status: InstanceStatus.ready,
          isDefault: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final postOnboardingAdapter = getIt<LLMAdapter>();
      final runner = getIt<AgentRunner>();

      expect(postOnboardingAdapter, isA<BaseOpenAIAdapter>());
      expect(postOnboardingAdapter, isNot(same(preOnboardingAdapter)));
      expect(runner.adapter, same(postOnboardingAdapter));
    },
  );
}
