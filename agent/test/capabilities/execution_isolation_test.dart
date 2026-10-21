import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/execution/direct_execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend_resolver.dart';
import 'package:sanad_agent/capabilities/execution/protected_execution_backend.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/host_capability_discovery_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:test/test.dart';

import '../support/memory_workspace_policy_store.dart';

const _fakeProviderKey = 'sk-test-provider-0000000000000000';
const _fakeSearchKey = 'test-search-key-000000';

Map<String, String> _daemonEnvironment() => {
  ...Platform.environment,
  'OPENAI_API_KEY': _fakeProviderKey,
  'anthropic_api_key': _fakeProviderKey,
  'LLM_API_KEY': _fakeProviderKey,
  'SERPER_API_KEY': _fakeSearchKey,
  'MY_PROJECT_TOKEN': 'project-owned-value',
  'ANDROID_HOME': '/opt/android-sdk',
  'JAVA_HOME': '/opt/jdk',
  'SSH_AUTH_SOCK': '/tmp/ssh-agent.sock',
  'DOCKER_CONTEXT': 'colima',
  'HTTPS_PROXY': 'http://proxy.example.test:3128',
  'SSL_CERT_FILE': '/etc/ssl/custom.pem',
  'SANAD_HOME': '/tmp/sanad-home',
  'SANAD_DEV_LAUNCHER_ID': 'launcher-1',
  'SANAD_DEV_RUNTIME_NONCE': 'nonce-1',
};

void main() {
  group('ProcessEnvironmentPolicy', () {
    const policy = ProcessEnvironmentPolicy();

    test('removes Sanad credentials and keeps the developer environment', () {
      final env = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: _daemonEnvironment(),
      );
      for (final key in [
        'OPENAI_API_KEY',
        'anthropic_api_key',
        'LLM_API_KEY',
        'SERPER_API_KEY',
      ]) {
        expect(env, isNot(contains(key)), reason: key);
      }
      expect(env.values, isNot(contains(_fakeProviderKey)));
      for (final key in [
        'PATH',
        'MY_PROJECT_TOKEN',
        'ANDROID_HOME',
        'JAVA_HOME',
        'SSH_AUTH_SOCK',
        'DOCKER_CONTEXT',
        'HTTPS_PROXY',
        'SSL_CERT_FILE',
        'SANAD_HOME',
        'SANAD_DEV_LAUNCHER_ID',
        'SANAD_DEV_RUNTIME_NONCE',
      ]) {
        expect(env[key], _daemonEnvironment()[key], reason: key);
      }
    });

    test('every provider registry credential name is stripped', () {
      final names = ChildProcessSecurityContract.sanadCredentialNames;
      expect(names, containsAll(['OPENAI_API_KEY', 'GEMINI_API_KEY']));
      final env = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: {for (final name in names) name: 'secret'},
      );
      expect(env, isEmpty);
    });

    test('rejects protected overrides by key without logging the value', () {
      final records = <LogRecord>[];
      final logger = Logger.detached('env-policy-test')
        ..level = Level.ALL
        ..onRecord.listen(records.add);
      final rejected = <RejectedEnvironmentOverride>[];
      final env = ProcessEnvironmentPolicy(logger: logger)
          .buildChildEnvironment(
            purpose: ChildProcessPurpose.directDeveloper,
            inheritedEnvironment: {'PATH': '/usr/bin'},
            requestOverrides: {
              'PATH': '/tmp/evil-bin',
              'LD_PRELOAD': '/tmp/evil.so',
              'DYLD_INSERT_LIBRARIES': '/tmp/evil.dylib',
              'NODE_OPTIONS': '--require /tmp/evil.js',
              'GIT_SSH_COMMAND': 'evil-ssh',
              'SSL_CERT_FILE': '/tmp/evil.pem',
              'SANAD_HOME': '/tmp/other-home',
              'OPENAI_API_KEY': _fakeProviderKey,
              'APP_MODE': 'test',
            },
            onRejectedOverride: rejected.add,
          );
      expect(env, {'PATH': '/usr/bin', 'APP_MODE': 'test'});
      expect(rejected.map((r) => r.key), hasLength(8));
      final logged = records.map((r) => r.message).join('\n');
      expect(logged, contains('key=PATH'));
      expect(logged, isNot(contains('/tmp/evil')));
      expect(logged, isNot(contains(_fakeProviderKey)));
    });

    test('rejects Git config injection and interpreter path pivots', () {
      const keys = [
        'GIT_CONFIG_COUNT',
        'GIT_CONFIG_KEY_0',
        'GIT_CONFIG_VALUE_0',
        'GIT_CONFIG_PARAMETERS',
        'GIT_PROXY_COMMAND',
        'JAVA_TOOL_OPTIONS',
        'PYTHONHOME',
        'NODE_PATH',
        'ZDOTDIR',
        'git_config_key_7',
      ];
      for (final key in keys) {
        expect(
          ChildProcessSecurityContract.isDangerousRequestOverride(key),
          isTrue,
          reason: key,
        );
      }
      final env = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: const {},
        requestOverrides: {for (final key in keys) key: 'x'},
      );
      expect(env, isEmpty);
    });

    test('the protected purpose never inherits the host environment', () {
      final env = policy.buildChildEnvironment(
        purpose: ChildProcessPurpose.protectedExecution,
        inheritedEnvironment: _daemonEnvironment(),
      );
      expect(env, isEmpty);
    });
  });

  group('execution backends', () {
    late Directory workspace;

    setUp(() {
      workspace = Directory(
        Directory.systemTemp
            .createTempSync('sanad-exec-isolation')
            .resolveSymbolicLinksSync(),
      );
    });

    tearDown(() => workspace.deleteSync(recursive: true));

    ShellExecuteTool shell({ExecutionBackendResolver? resolver}) =>
        ShellExecuteTool(
          workspacePath: workspace.path,
          backendResolver:
              resolver ??
              ExecutionBackendResolver(
                directBackend: DirectExecutionBackend(
                  inheritedEnvironment: _daemonEnvironment,
                ),
              ),
        );

    test(
      'a Direct shell child cannot read Sanad credentials but keeps the developer environment',
      () async {
        final result = await shell().executeResult({
          'command': 'env',
          'description': 'print environment',
        });
        expect(result.isError, isFalse);
        final output = result.displayText;
        expect(output, isNot(contains(_fakeProviderKey)));
        expect(output, isNot(contains(_fakeSearchKey)));
        expect(output, contains('MY_PROJECT_TOKEN=project-owned-value'));
        expect(output, contains('ANDROID_HOME=/opt/android-sdk'));
        expect(output, contains('SANAD_DEV_LAUNCHER_ID=launcher-1'));
      },
      skip: Platform.isWindows ? 'uses the POSIX env command' : false,
    );

    test(
      'Protected fails closed and never runs the command on the host',
      () async {
        final marker = File('${workspace.path}/ran.txt');
        final store = MemoryWorkspacePolicyStore();
        addTearDown(store.dispose);
        await store.seed(
          workspace.path,
          const WorkspacePolicy(
            executionMode: ExecutionMode.protected,
            permissionMode: WorkspacePermissionMode.fullAccess,
          ),
        );
        final tool = shell(
          resolver: ExecutionBackendResolver(policyStore: store),
        );
        final context = ToolContext(
          sessionId: 's1',
          metadata: {
            'workspace': {'id': workspace.path, 'path': workspace.path},
          },
        );
        final result = await tool.executeResult({
          'command': Platform.isWindows
              ? 'echo ran > ran.txt'
              : 'echo ran > ran.txt',
          'description': 'write marker',
        }, context: context);
        expect(result.isError, isTrue);
        expect(result.errorCode, ToolResultErrorCode.permissionDenied);
        expect(result.displayText, contains('protected_backend_unavailable'));
        expect(marker.existsSync(), isFalse);
      },
    );

    test(
      'a mode change applies to the next command of the same session',
      () async {
        final store = MemoryWorkspacePolicyStore();
        addTearDown(store.dispose);
        final calls = <String>[];
        final resolver = ExecutionBackendResolver(
          policyStore: store,
          directBackend: _RecordingBackend(ExecutionMode.direct, calls),
          protectedBackend: _RecordingBackend(ExecutionMode.protected, calls),
        );
        final context = ToolContext(
          sessionId: 'same-session',
          metadata: {
            'workspace': {'id': workspace.path, 'path': workspace.path},
          },
        );
        final tool = shell(resolver: resolver);
        Future<void> run(String command) => tool.executeResult({
          'command': command,
          'description': 'x',
        }, context: context);

        await run('first');
        await store.seed(
          workspace.path,
          const WorkspacePolicy(executionMode: ExecutionMode.protected),
        );
        await run('second');
        await store.seed(workspace.path, const WorkspacePolicy());
        await run('third');
        expect(calls, ['direct:first', 'protected:second', 'direct:third']);
      },
    );

    test(
      'cwd rejects a sibling root that shares the workspace prefix',
      () async {
        final sibling = Directory('${workspace.path}-evil')..createSync();
        addTearDown(() => sibling.deleteSync(recursive: true));
        await expectLater(
          shell().executeResult({
            'command': 'pwd',
            'cwd': sibling.path,
            'description': 'escape',
          }),
          throwsA(isA<FileSystemException>()),
        );
        final inside = Directory('${workspace.path}/pkg')..createSync();
        final ok = await shell().executeResult({
          'command': Platform.isWindows ? 'cd' : 'pwd',
          'cwd': 'pkg',
          'description': 'inside',
        });
        expect(
          ok.displayText,
          contains(inside.path.split(Platform.pathSeparator).last),
        );
      },
    );

    test('ProtectedExecutionBackend reports its fixed refusal', () async {
      final result = await const ProtectedExecutionBackend().execute(
        ShellCommandRequest(
          command: 'id',
          workingDirectory: workspace.path,
          timeoutMs: 1000,
          stopwatch: Stopwatch(),
        ),
      );
      final payload = jsonDecode(result.displayText) as Map<String, dynamic>;
      expect(payload['output'], ProtectedExecutionBackend.unavailableMessage);
    });
  });

  group('HostCapabilityDiscoveryTool', () {
    late Directory bin;

    setUp(() {
      bin = Directory(
        Directory.systemTemp
            .createTempSync('sanad-discovery-bin')
            .resolveSymbolicLinksSync(),
      );
    });

    tearDown(() => bin.deleteSync(recursive: true));

    Future<Map<String, dynamic>> lookup(
      Map<String, dynamic> args, {
      Map<String, String>? environment,
      bool isWindows = false,
    }) async {
      final result = await HostCapabilityDiscoveryTool(
        environment: environment ?? {'PATH': bin.path, 'SECRET': 'nope'},
        isWindows: isWindows,
      ).executeResult(args);
      return jsonDecode(result.displayText) as Map<String, dynamic>;
    }

    test(
      'finds an executable without running it and leaks no environment',
      () async {
        final tool = File('${bin.path}/sanadtool')
          ..writeAsStringSync('#!/bin/sh\ntouch "${bin.path}/executed"\n');
        Process.runSync('chmod', ['755', tool.path]);
        File('${bin.path}/notexec').writeAsStringSync('data');

        final found = await lookup({'executable_name': 'sanadtool'});
        final entry = (found['tools'] as List).single as Map<String, dynamic>;
        expect(entry['found'], isTrue);
        expect(entry['canonical_path'], tool.path);
        expect(File('${bin.path}/executed').existsSync(), isFalse);

        final plain = await lookup({'executable_name': 'notexec'});
        expect(((plain['tools'] as List).single as Map)['found'], isFalse);

        final common = jsonEncode(await lookup({'common_tools': true}));
        expect(common, isNot(contains('nope')));
        expect(common, isNot(contains('"PATH"')));
      },
      skip: Platform.isWindows ? 'uses POSIX permissions' : false,
    );

    test('rejects paths, traversal, whitespace and wildcards', () async {
      for (final name in [
        '../bin/sh',
        '/bin/sh',
        r'..\cmd',
        'git status',
        'gi*',
        '',
        '.hidden',
      ]) {
        final result = await HostCapabilityDiscoveryTool(
          environment: {'PATH': bin.path},
        ).executeResult({'executable_name': name});
        expect(result.isError, isTrue, reason: name);
      }
    });

    test('resolves Windows names through PATHEXT', () async {
      File('${bin.path}/tool.CMD').writeAsStringSync('@echo off');
      final found = await lookup(
        {'executable_name': 'tool'},
        environment: {'Path': bin.path, 'PATHEXT': '.EXE;.CMD'},
        isWindows: true,
      );
      final entry = (found['tools'] as List).single as Map<String, dynamic>;
      expect(entry['found'], isTrue);
    }, skip: Platform.isWindows ? false : 'Windows path separators and case');
  });
}

class _RecordingBackend implements ExecutionBackend {
  _RecordingBackend(this.mode, this.calls);

  @override
  final ExecutionMode mode;

  @override
  bool get runsCommands => true;
  final List<String> calls;

  @override
  Future<ToolExecutionResult> execute(ShellCommandRequest request) async {
    calls.add('${mode.value}:${request.command}');
    return ToolExecutionResult.text('ok');
  }
}
