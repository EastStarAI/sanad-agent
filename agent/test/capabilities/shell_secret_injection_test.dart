import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';
import '../support/memory_workspace_policy_store.dart';

/// Plan 84: a user secret reaches a real child process only when that exact
/// secret is requested for the call, and a verbatim echo never reaches the
/// tool result.
void main() {
  const requestedValue = 'dummy-requested-value-84';
  const unrequestedValue = 'dummy-unrequested-value-84';

  late Directory root;
  late Directory workspace;
  late SecretVaults vaults;

  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-shell-secrets')
          .resolveSymbolicLinksSync(),
    );
    final home = Directory('${root.path}/home')..createSync();
    workspace = Directory('${root.path}/workspace')..createSync();
    setSanadHomeOverride(home.path);
    await SanadHomeBootstrap.identity().prepare();
    vaults = await SecretVaults.open(store: MemoryAgentSecretStore());
    await vaults.put(vaults.custom, {
      'DEMO_REQUESTED': requestedValue,
      'DEMO_UNREQUESTED': unrequestedValue,
    });
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    root.deleteSync(recursive: true);
  });

  ToolContext ownerContext() => ToolContext(
    sessionId: 'shell-secrets',
    metadata: {CommandAuthority.payloadKey: CommandAuthority.owner.value},
  );

  ShellExecuteTool shell({PermissionManager? permissionManager}) =>
      ShellExecuteTool(
        workspacePath: workspace.path,
        permissionManager: permissionManager,
        userSecrets: UserSecretVault(vaults: () => vaults),
      );

  Map<String, dynamic> decode(ToolExecutionResult result) =>
      jsonDecode(result.displayText) as Map<String, dynamic>;

  test(
    'a shell call that requests no secret never sees any user secret',
    () async {
      final envFile = File('${workspace.path}/env.txt');
      final result = await shell().executeResult({
        'command': 'env > env.txt',
        'description': 'dump env',
      }, context: ownerContext());

      expect(result.isError, isFalse, reason: result.displayText);
      final env = envFile.readAsStringSync();
      expect(env, isNot(contains(unrequestedValue)));
      expect(env, isNot(contains(requestedValue)));
      expect(env, isNot(contains('DEMO_UNREQUESTED=')));
      expect(env, isNot(contains('DEMO_REQUESTED=')));
    },
    skip: Platform.isWindows ? 'uses the POSIX env command' : false,
  );

  test(
    'only the requested secret reaches the child and its echo is redacted',
    () async {
      final envFile = File('${workspace.path}/env.txt');
      final result = await shell().executeResult({
        'command': r'env > env.txt; echo "token=$DEMO_REQUESTED"',
        'description': 'use token',
        'secrets': ['DEMO_REQUESTED'],
      }, context: ownerContext());

      expect(result.isError, isFalse, reason: result.displayText);
      final env = envFile.readAsStringSync();
      expect(env, contains('DEMO_REQUESTED=$requestedValue'));
      expect(env, isNot(contains(unrequestedValue)));
      expect(result.displayText, isNot(contains(requestedValue)));
      expect(
        decode(result)['output'],
        contains('token=[REDACTED:DEMO_REQUESTED]'),
      );
    },
    skip: Platform.isWindows ? 'uses the POSIX env command' : false,
  );

  test('an unknown secret name fails before the command runs', () async {
    final marker = File('${workspace.path}/ran.txt');
    final result = await shell().executeResult({
      'command': 'echo ran > ran.txt',
      'description': 'marker',
      'secrets': ['DEMO_NOT_STORED'],
    }, context: ownerContext());

    expect(result.isError, isTrue);
    expect(result.errorCode, ToolResultErrorCode.notFound);
    expect(result.displayText, contains('DEMO_NOT_STORED'));
    expect(marker.existsSync(), isFalse);
  });

  test('a non-owner turn cannot inject a secret', () async {
    final marker = File('${workspace.path}/ran.txt');
    final result = await shell().executeResult(
      {
        'command': 'echo ran > ran.txt',
        'description': 'marker',
        'secrets': ['DEMO_REQUESTED'],
      },
      context: ToolContext(
        sessionId: 'shell-secrets',
        metadata: {
          CommandAuthority.payloadKey: CommandAuthority.unverified.value,
        },
      ),
    );

    expect(result.isError, isTrue);
    expect(result.errorCode, ToolResultErrorCode.permissionDenied);
    expect(marker.existsSync(), isFalse);
  });

  test('a reserved or malformed secret name is rejected', () async {
    for (final secrets in [
      ['PATH'],
      ['OPENAI_API_KEY'],
      ['not-a-name'],
      'DEMO_REQUESTED',
      [42],
    ]) {
      await expectLater(
        shell().executeResult({
          'command': 'true',
          'description': 'noop',
          'secrets': secrets,
        }, context: ownerContext()),
        throwsA(isA<FormatException>()),
        reason: '$secrets',
      );
    }
  });

  test(
    'a grant for a command without secrets does not cover the same command with secrets',
    () async {
      final bridge = _CountingBridge();
      final permissions = PermissionManager(
        policyStore: MemoryWorkspacePolicyStore(),
        platformRuntimeBridge: bridge,
        checkpointStore: _NoopCheckpointStore(),
      );
      final tool = shell(permissionManager: permissions);

      await tool.executeResult({
        'command': 'true',
        'description': 'noop',
      }, context: ownerContext());
      await tool.executeResult({
        'command': 'true',
        'description': 'noop',
      }, context: ownerContext());
      expect(bridge.requests, hasLength(1));

      await tool.executeResult({
        'command': 'true',
        'description': 'noop',
        'secrets': ['DEMO_REQUESTED'],
      }, context: ownerContext());
      expect(bridge.requests, hasLength(2));
      final input = bridge.requests.last['tool_input'] as Map;
      expect(input['secrets'], ['DEMO_REQUESTED']);
      expect(jsonEncode(bridge.requests), isNot(contains(requestedValue)));
    },
  );
}

class _CountingBridge extends PlatformRuntimeBridge {
  final requests = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requests.add(payload);
    return const {'allowed': true, 'scope': 'session'};
  }
}

class _NoopCheckpointStore extends SuspendedCheckpointStore {
  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {}

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async => null;

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}

  @override
  Future<void> deleteByRequestId(String requestId) async {}
}
