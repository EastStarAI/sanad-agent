import 'package:sanad_agent/capabilities/permissions/child_process_security_contract.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessEnvironmentPolicy', () {
    late ProcessEnvironmentPolicy policy;

    setUp(() {
      policy = const ProcessEnvironmentPolicy();
    });

    test('strips Sanad control-plane credentials from child environment', () {
      final inherited = {
        'PATH': '/usr/bin:/bin',
        'HOME': '/Users/test',
        'SANAD_AUTH_TOKEN': 'super_secret_auth_token',
        'SANAD_AGENT_KEY': 'agent_device_key_123',
        'SANAD_SECRET_KEY': 'master_secret_key',
        'SANAD_LOCAL_GATEWAY_TOKEN': 'local_token_999',
        'SANAD_DEVICE_CREDENTIAL': 'device_secret_abc',
        'SANAD_PAIRING_TOKEN': 'pairing_token_xyz',
        'SANAD_DEV_LAUNCHER_ID': 'launcher-dev-1',
      };

      final result = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: inherited,
      );

      expect(result['PATH'], '/usr/bin:/bin');
      expect(result['HOME'], '/Users/test');
      expect(result.containsKey('SANAD_AUTH_TOKEN'), isFalse);
      expect(result.containsKey('SANAD_AGENT_KEY'), isFalse);
      expect(result.containsKey('SANAD_SECRET_KEY'), isFalse);
      expect(result.containsKey('SANAD_LOCAL_GATEWAY_TOKEN'), isFalse);
      expect(result.containsKey('SANAD_DEVICE_CREDENTIAL'), isFalse);
      expect(result.containsKey('SANAD_PAIRING_TOKEN'), isFalse);
      expect(result.containsKey('SANAD_DEV_LAUNCHER_ID'), isFalse);
    });

    test('strips ambient provider API keys unless explicitly granted', () {
      final inherited = {
        'PATH': '/usr/bin:/bin',
        'OPENAI_API_KEY': 'sk-secret-openai-12345',
        'ANTHROPIC_API_KEY': 'sk-ant-secret-67890',
        'GEMINI_API_KEY': 'ai-gemini-secret-abcde',
        'DEEPSEEK_API_KEY': 'sk-deepseek-secret',
      };

      // 1. Without grants: all stripped
      final ungrantedResult = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: inherited,
      );

      expect(ungrantedResult.containsKey('OPENAI_API_KEY'), isFalse);
      expect(ungrantedResult.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(ungrantedResult.containsKey('GEMINI_API_KEY'), isFalse);
      expect(ungrantedResult.containsKey('DEEPSEEK_API_KEY'), isFalse);

      // 2. With explicit grant for OPENAI_API_KEY: only granted key preserved
      final grantedResult = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: inherited,
        explicitGrants: {'OPENAI_API_KEY'},
      );

      expect(grantedResult['OPENAI_API_KEY'], 'sk-secret-openai-12345');
      expect(grantedResult.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(grantedResult.containsKey('GEMINI_API_KEY'), isFalse);
    });

    test('preserves developer environment, tools, and SDK roots (Developer Parity)', () {
      final developerEnv = {
        'PATH': '/Users/test/.fvm/default/bin:/opt/homebrew/bin:/usr/bin',
        'HOME': '/Users/test',
        'USER': 'testdeveloper',
        'SHELL': '/bin/zsh',
        'FVM_HOME': '/Users/test/.fvm',
        'FLUTTER_ROOT': '/Users/test/.fvm/versions/3.24.0',
        'JAVA_HOME': '/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home',
        'ANDROID_HOME': '/Users/test/Library/Android/sdk',
        'GOPATH': '/Users/test/go',
        'CARGO_HOME': '/Users/test/.cargo',
        'NVM_DIR': '/Users/test/.nvm',
        'PUB_CACHE': '/Users/test/.pub-cache',
        'SSH_AUTH_SOCK': '/private/tmp/com.apple.launchd.xxx/Listeners',
        'HTTP_PROXY': 'http://127.0.0.1:8080',
        'HTTPS_PROXY': 'http://127.0.0.1:8080',
        'NO_PROXY': 'localhost,127.0.0.1',
      };

      final result = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: developerEnv,
      );

      for (final entry in developerEnv.entries) {
        expect(result[entry.key], equals(entry.value));
      }
    });

    test('strips daemon VIRTUAL_ENV marker to prevent user project pollution', () {
      final inherited = {
        'PATH': '/opt/daemon/venv/bin:/usr/bin',
        'VIRTUAL_ENV': '/opt/daemon/venv',
        'USER': 'test',
      };

      final result = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: inherited,
      );

      expect(result['USER'], 'test');
      expect(result['PATH'], '/opt/daemon/venv/bin:/usr/bin');
      expect(result.containsKey('VIRTUAL_ENV'), isFalse);
    });

    test('rejects dangerous request overrides for PATH and dynamic loader hooks', () {
      final inherited = {
        'PATH': '/usr/bin:/bin',
        'HOME': '/Users/test',
      };

      final rejectedKeys = <String>[];
      final rejectedReasons = <String>[];

      final overrides = {
        'PATH': '/malicious/bin',
        'HOME': '/malicious/home',
        'LD_PRELOAD': '/tmp/evil.so',
        'DYLD_INSERT_LIBRARIES': '/tmp/evil.dylib',
        'NODE_OPTIONS': '--require /tmp/evil.js',
        'PYTHONSTARTUP': '/tmp/evil.py',
        'SANAD_AUTH_TOKEN': 'injected_token',
        'SAFE_CUSTOM_VAR': 'safe_value_123',
      };

      final result = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: inherited,
        requestOverrides: overrides,
        onRejectedOverride: (key, reason) {
          rejectedKeys.add(key);
          rejectedReasons.add(reason);
        },
      );

      // Protected keys must NOT be overridden
      expect(result['PATH'], '/usr/bin:/bin');
      expect(result['HOME'], '/Users/test');
      expect(result.containsKey('LD_PRELOAD'), isFalse);
      expect(result.containsKey('DYLD_INSERT_LIBRARIES'), isFalse);
      expect(result.containsKey('NODE_OPTIONS'), isFalse);
      expect(result.containsKey('PYTHONSTARTUP'), isFalse);
      expect(result.containsKey('SANAD_AUTH_TOKEN'), isFalse);

      // Safe overrides are permitted
      expect(result['SAFE_CUSTOM_VAR'], 'safe_value_123');

      // Check rejection callbacks
      expect(rejectedKeys, containsAll([
        'PATH',
        'HOME',
        'LD_PRELOAD',
        'DYLD_INSERT_LIBRARIES',
        'NODE_OPTIONS',
        'PYTHONSTARTUP',
        'SANAD_AUTH_TOKEN',
      ]));
      expect(rejectedKeys, isNot(contains('SAFE_CUSTOM_VAR')));
    });
  });
}
