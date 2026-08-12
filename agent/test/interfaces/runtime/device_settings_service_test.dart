import 'dart:io';

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/runtime/device_settings_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late AgentStateDatabase state;
  late RuntimeRecoveryService recovery;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-device-settings');
    setSanadHomeOverride(home.path);
    state = AgentStateDatabase.inMemory();
    recovery = RuntimeRecoveryService(
      ProviderInstanceRepository.fromDatabase(state.db),
      ProviderRateLimiter(),
      autoFailoverEnabled: true,
    );
  });

  tearDown(() async {
    state.dispose();
    setSanadHomeOverride(null);
    await home.delete(recursive: true);
  });

  DeviceSettingsService createService({Map<String, String>? environment}) {
    final envPath = '${home.path}/.env';
    return DeviceSettingsService(
      config: Config(environment: environment ?? const {}),
      envFileService: EnvFileService(envPath: envPath),
      runtimeRecovery: recovery,
    );
  }

  test(
    'updates live settings atomically and never returns the Serper key',
    () async {
      final env = File('${home.path}/.env');
      await env.writeAsString('WEB_SEARCH_PROVIDER=ddg\n');
      final service = createService();

      final result = await service.update({
        'web_search_provider': 'serper',
        'serper_api_key': 'secret-value',
        'provider_auto_failover_enabled': false,
      });

      expect(result.restartRequired, isFalse);
      expect(result.snapshot['web_search']['provider'], 'serper');
      expect(result.snapshot['web_search']['serper_configured'], isTrue);
      expect(result.snapshot.toString(), isNot(contains('secret-value')));
      expect(recovery.autoFailoverEnabled, isFalse);
      expect(await env.readAsString(), contains('SERPER_API_KEY=secret-value'));
    },
  );

  test(
    'validates every change before writing and marks gateway restart',
    () async {
      final env = File('${home.path}/.env');
      await env.writeAsString('ENABLE_GATEWAY=true\nWEB_SEARCH_PROVIDER=ddg\n');
      final service = createService();

      await expectLater(
        service.update({
          'cloud_connection_enabled': false,
          'web_search_provider': 'unsupported',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(await env.readAsString(), contains('ENABLE_GATEWAY=true'));

      final result = await service.update({'cloud_connection_enabled': false});
      expect(result.restartRequired, isTrue);
      expect(result.snapshot['cloud_connection']['enabled'], isFalse);
    },
  );

  test('rejects settings managed by the process environment', () async {
    final service = createService(
      environment: const {'ENABLE_GATEWAY': 'true'},
    );

    expect(
      service.snapshot()['cloud_connection']['managed_externally'],
      isTrue,
    );
    await expectLater(
      service.update({'cloud_connection_enabled': false}),
      throwsA(isA<StateError>()),
    );
  });
}
