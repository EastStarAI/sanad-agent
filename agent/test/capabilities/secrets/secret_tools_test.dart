import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/runtime/interactive_user_input.dart';
import 'package:sanad_agent/capabilities/secrets/secret_acquisition.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/secret_tools.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';
import '../../support/memory_workspace_policy_store.dart';

/// Plan 84 integration: model request -> client prompt -> vault -> explicit
/// shell injection, with no value in any model-visible result or event.
void main() {
  const secretValue = 'dummy-flow-secret-84';
  const sessionId = 'secret-tools-session';

  late Directory root;
  late Directory workspace;
  late SecretVaults vaults;
  late UserSecretVault userSecrets;
  late PlatformRuntimeBridge bridge;
  late _RecordingCheckpointStore checkpoints;
  late List<GatewayResponse> events;

  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-secret-tools')
          .resolveSymbolicLinksSync(),
    );
    final home = Directory('${root.path}/home')..createSync();
    workspace = Directory('${root.path}/workspace')..createSync();
    setSanadHomeOverride(home.path);
    await SanadHomeBootstrap.identity().prepare();
    vaults = await SecretVaults.open(store: MemoryAgentSecretStore());
    userSecrets = UserSecretVault(vaults: () => vaults);
    bridge = PlatformRuntimeBridge(
      secretAcquisition: SecretAcquisition(vault: userSecrets),
    );
    events = [];
    bridge.attachResponseSink(events.add);
    checkpoints = _RecordingCheckpointStore();
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    root.deleteSync(recursive: true);
  });

  ToolContext context({bool owner = true}) => ToolContext(
    sessionId: sessionId,
    toolCallId: 'call-secret',
    metadata: {
      CommandAuthority.payloadKey:
          (owner ? CommandAuthority.owner : CommandAuthority.unverified).value,
    },
  );

  RequestSecretTool requestTool() => RequestSecretTool(
    userInput: InteractiveUserInput(
      bridge: bridge,
      checkpointStore: () => checkpoints,
    ),
    userSecrets: userSecrets,
  );

  Map<String, dynamic> permissionRequest() {
    final event = events.firstWhere(
      (event) =>
          event.message.metadata?['canonical_event_type'] ==
          CanonicalEventTypes.toolPermissionRequest,
    );
    return Map<String, dynamic>.from(
      event.message.metadata!['canonical_payload'] as Map,
    );
  }

  Future<void> answer(Map<String, dynamic> body) async {
    final request = permissionRequest();
    final outcome = await bridge.handlePermissionResponse(
      CanonicalEvent(
        type: CanonicalEventTypes.toolPermissionResponse,
        sessionId: sessionId,
        payload: {
          'request_id': request['request_id'],
          'session_id': sessionId,
          CommandAuthority.payloadKey: CommandAuthority.owner.value,
          ...body,
        },
      ),
    );
    expect(outcome.isSuccess, isTrue, reason: outcome.errorMessage);
  }

  Future<void> untilPrompted() async {
    for (var i = 0; i < 100 && events.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  const args = {
    'reason': 'Connect to the demo database',
    'fields': [
      {'name': 'DEMO_DB_PASSWORD', 'label': 'Password'},
    ],
  };

  test(
    'request, store and inject a secret without any value reaching the model',
    () async {
      final pending = requestTool().executeResult(args, context: context());
      await untilPrompted();

      final request = permissionRequest();
      expect(request['tool_name'], SecretToolNames.request);
      expect(request['fields'], [
        {
          'name': 'DEMO_DB_PASSWORD',
          'label': 'Password',
          'masked': true,
          'required': true,
        },
      ]);
      expect(checkpoints.saved.single.toolName, SecretToolNames.request);

      await answer({
        'allowed': true,
        SecretAcquisition.valuesKey: {'DEMO_DB_PASSWORD': secretValue},
      });
      final result = await pending;

      expect(result.isError, isFalse);
      expect(jsonDecode(result.displayText), {
        'status': 'stored',
        'secrets': ['DEMO_DB_PASSWORD'],
        'usage': isA<String>(),
      });
      expect(checkpoints.deleted, [request['request_id']]);
      expect(
        jsonEncode(checkpoints.saved.map((c) => c.toRow()).toList()),
        isNot(contains(secretValue)),
      );

      final shell =
          await ShellExecuteTool(
            workspacePath: workspace.path,
            userSecrets: userSecrets,
          ).executeResult({
            'command':
                r'printf "%s" "$DEMO_DB_PASSWORD" > used.txt; echo "$DEMO_DB_PASSWORD"',
            'description': 'use password',
            'secrets': ['DEMO_DB_PASSWORD'],
          }, context: context());
      expect(
        File('${workspace.path}/used.txt').readAsStringSync(),
        secretValue,
      );
      expect(shell.displayText, isNot(contains(secretValue)));
      expect(shell.displayText, contains('[REDACTED:DEMO_DB_PASSWORD]'));

      final everyEvent = jsonEncode([
        for (final event in events) event.message.metadata,
      ]);
      expect(everyEvent, isNot(contains(secretValue)));
    },
    skip: Platform.isWindows ? 'uses a POSIX shell' : false,
  );

  test('a skip returns a clean skipped result and stores nothing', () async {
    final pending = requestTool().executeResult(args, context: context());
    await untilPrompted();
    await answer({'allowed': false, 'decision': 'deny'});
    final result = await pending;
    expect(result.isError, isFalse);
    expect(jsonDecode(result.displayText)['status'], 'skipped');
    expect(userSecrets.names(), isEmpty);
  });

  test('a non-owner turn is refused without prompting', () async {
    final result = await requestTool().executeResult(
      args,
      context: context(owner: false),
    );
    expect(result.errorCode, ToolResultErrorCode.permissionDenied);
    expect(events, isEmpty);
    expect(checkpoints.saved, isEmpty);
  });

  test('invalid fields are rejected before prompting', () async {
    for (final fields in [
      <Object>[],
      [
        {'name': 'PATH', 'label': 'Path'},
      ],
      [
        {'name': 'DEMO_A', 'label': 'A'},
        {'name': 'DEMO_A', 'label': 'A again'},
      ],
      [
        {'name': 'DEMO_A'},
      ],
    ]) {
      await expectLater(
        requestTool().executeResult({
          'reason': 'r',
          'fields': fields,
        }, context: context()),
        throwsA(isA<FormatException>()),
        reason: '$fields',
      );
    }
    expect(events, isEmpty);
  });

  test('an unavailable vault fails without prompting', () async {
    final tool = RequestSecretTool(
      userInput: InteractiveUserInput(
        bridge: bridge,
        checkpointStore: () => checkpoints,
      ),
      userSecrets: UserSecretVault(vaults: () => null),
    );
    final result = await tool.executeResult(args, context: context());
    expect(result.isError, isTrue);
    expect(jsonDecode(result.displayText)['status'], 'failed');
    expect(events, isEmpty);
  });

  test('a stored name is announced as replaced in the prompt', () async {
    await userSecrets.store({'DEMO_DB_PASSWORD': 'dummy-old'});
    final pending = requestTool().executeResult(args, context: context());
    await untilPrompted();
    expect(permissionRequest()['replaces'], ['DEMO_DB_PASSWORD']);
    await answer({'allowed': false});
    await pending;
  });

  test('list returns names only, for the owner only', () async {
    await userSecrets.store({'DEMO_B': 'dummy-b', 'DEMO_A': 'dummy-a'});
    final listed = await ListSecretsTool(
      userSecrets: userSecrets,
    ).executeResult(const {}, context: context());
    expect(jsonDecode(listed.displayText), {
      'secrets': ['DEMO_A', 'DEMO_B'],
      'count': 2,
    });
    expect(listed.displayText, isNot(contains('dummy-')));

    final refused = await ListSecretsTool(
      userSecrets: userSecrets,
    ).executeResult(const {}, context: context(owner: false));
    expect(refused.errorCode, ToolResultErrorCode.permissionDenied);
  });

  group('delete', () {
    late _DecidingBridge decisions;
    late DeleteSecretTool tool;

    setUp(() async {
      await userSecrets.store({'DEMO_A': 'dummy-a', 'DEMO_B': 'dummy-b'});
      decisions = _DecidingBridge();
      tool = DeleteSecretTool(
        permissionManager: PermissionManager(
          policyStore: MemoryWorkspacePolicyStore(),
          platformRuntimeBridge: decisions,
          checkpointStore: checkpoints,
        ),
        userSecrets: userSecrets,
      );
    });

    test('deletes the approved names and reports unknown ones', () async {
      final result = await tool.executeResult({
        'names': ['DEMO_A', 'DEMO_GONE'],
      }, context: context());
      expect(decisions.requests.single['tool_input'], {
        'names': ['DEMO_A', 'DEMO_GONE'],
      });
      expect(jsonDecode(result.displayText), {
        'status': 'deleted',
        'deleted': ['DEMO_A'],
        'not_found': ['DEMO_GONE'],
      });
      expect(userSecrets.names(), ['DEMO_B']);
    });

    test('a denial deletes nothing', () async {
      decisions.allow = false;
      await expectLater(
        tool.executeResult({
          'names': ['DEMO_A'],
        }, context: context()),
        throwsA(isA<ToolPermissionDeniedException>()),
      );
      expect(userSecrets.names(), ['DEMO_A', 'DEMO_B']);
    });
  });
}

class _RecordingCheckpointStore extends SuspendedCheckpointStore {
  final saved = <SuspendedCheckpoint>[];
  final deleted = <String>[];

  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async =>
      saved.add(checkpoint);

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async => null;

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}

  @override
  Future<void> deleteByRequestId(String requestId) async =>
      deleted.add(requestId);
}

class _DecidingBridge extends PlatformRuntimeBridge {
  bool allow = true;
  final requests = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requests.add(payload);
    return {'allowed': allow, 'scope': 'once'};
  }
}
