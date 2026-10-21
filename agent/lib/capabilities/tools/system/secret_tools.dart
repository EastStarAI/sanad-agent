import 'dart:convert';

import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/runtime/interactive_user_input.dart';
import 'package:sanad_agent/capabilities/secrets/secret_acquisition.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';

const _systemSource = {'type': 'builtin_local', 'id': 'sanad-agent.system'};

bool _isOwner(ToolContext? context) => CommandAuthority.fromStamped(
  context?.metadata[CommandAuthority.payloadKey],
).isOwner;

ToolExecutionResult _ownerRequired() => ToolExecutionResult.text(
  jsonEncode({
    'status': 'refused',
    'message':
        'User secrets are available only on a turn from the device '
        'owner.',
  }),
  isError: true,
  errorCode: ToolResultErrorCode.permissionDenied,
);

/// Asks the user for one or more secrets through the Sanad Client
/// (Plan 84). The client collects the values outside the conversation and
/// the Agent stores them in its vault; the model receives names and an
/// outcome only.
class RequestSecretTool extends SpecBackedTool {
  RequestSecretTool({
    required InteractiveUserInput userInput,
    UserSecretVault? userSecrets,
  }) : _userInput = userInput,
       _userSecrets = userSecrets ?? UserSecretVault();

  final InteractiveUserInput _userInput;
  final UserSecretVault _userSecrets;

  static const maxReasonLength = 500;

  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: SecretToolNames.request,
    displayName: 'Request Secret',
    description:
        'Ask the user to enter secrets (API keys, passwords, tokens) in a '
        'secure Sanad Client form. Values are stored in the Agent vault and '
        'are never shown to you; you receive only the stored names. Use a '
        'name later in shell_execute "secrets". Never ask for secrets in chat.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'reason': {
          'type': 'string',
          'description': 'Why the secrets are needed, shown to the user.',
        },
        'fields': {
          'type': 'array',
          'minItems': 1,
          'maxItems': SecretRequestField.maxFields,
          'items': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description':
                    'Environment variable name the value is stored and '
                    'injected under, for example DATABASE_PASSWORD.',
              },
              'label': {
                'type': 'string',
                'description': 'Short label shown to the user.',
              },
              'description': {
                'type': 'string',
                'description': 'Where the user can find this value.',
              },
              'masked': {
                'type': 'boolean',
                'description':
                    'Hide the typed value (default true). Use false only '
                    'for non-sensitive inputs such as a username.',
              },
              'required': {
                'type': 'boolean',
                'description': 'Whether a value is required (default true).',
              },
            },
            'required': ['name', 'label'],
            'additionalProperties': false,
          },
        },
      },
      'required': ['reason', 'fields'],
      'additionalProperties': false,
    },
    source: _systemSource,
    category: 'system',
    workspaceRequired: false,
    approval: {'mode': 'default', 'sensitive': false},
    execution: {'target': 'local_runtime', 'timeout_ms': 86400000},
    serverName: 'system',
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    if (!_isOwner(context)) return _ownerRequired();
    final fields = SecretRequestField.parseAll(args['fields']);
    final reason = args['reason'];
    if (reason is! String ||
        reason.trim().isEmpty ||
        reason.length > maxReasonLength) {
      throw const FormatException(
        'reason must be text of at most $maxReasonLength characters.',
      );
    }
    if (!_userSecrets.available) {
      final failed = SecretAcquisition.resultFor(const {
        SecretAcquisition.outcomeKey: 'failed',
      });
      return ToolExecutionResult.text(
        failed.text,
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
    }
    final stored = _userSecrets.names().toSet();
    final decision = await _userInput.request(
      toolName: SecretToolNames.request,
      checkpointPrefix: 'secret',
      context: context,
      args: args,
      fields: {
        'reason': reason.trim(),
        'fields': [for (final field in fields) field.toJson()],
        'replaces': [
          for (final field in fields)
            if (stored.contains(field.name)) field.name,
        ],
      },
    );
    // Only the bridge-sanitized shape counts; any other decision (for
    // example a terminal handler's plain allow) stored nothing.
    final result = SecretAcquisition.resultFor(decision);
    return ToolExecutionResult.text(
      result.text,
      isError: result.isError,
      errorCode: result.isError ? ToolResultErrorCode.executionFailed : null,
    );
  }
}

/// Lists stored user secret names. Never values, never other vault owners.
class ListSecretsTool extends SpecBackedTool {
  ListSecretsTool({UserSecretVault? userSecrets})
    : _userSecrets = userSecrets ?? UserSecretVault();

  final UserSecretVault _userSecrets;

  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: SecretToolNames.list,
    displayName: 'List Secrets',
    description:
        'List the names of user secrets stored in the Agent vault. Values '
        'are never returned.',
    inputSchema: {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
    source: _systemSource,
    category: 'system',
    workspaceRequired: false,
    approval: {'mode': 'default', 'sensitive': false},
    execution: {
      'target': 'local_runtime',
      'timeout_ms': 10000,
      'restart_replay_safe': true,
    },
    serverName: 'system',
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    if (!_isOwner(context)) return _ownerRequired();
    final names = _userSecrets.names();
    return ToolExecutionResult.text(
      jsonEncode({'secrets': names, 'count': names.length}),
    );
  }
}

/// Deletes stored user secrets after the user approves the exact names.
class DeleteSecretTool extends SpecBackedTool {
  DeleteSecretTool({
    required PermissionManager permissionManager,
    UserSecretVault? userSecrets,
  }) : _permissionManager = permissionManager,
       _userSecrets = userSecrets ?? UserSecretVault();

  final PermissionManager _permissionManager;
  final UserSecretVault _userSecrets;

  static const maxNames = 16;

  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: SecretToolNames.delete,
    displayName: 'Delete Secret',
    description:
        'Permanently delete user secrets from the Agent vault by name. The '
        'user must approve.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'names': {
          'type': 'array',
          'minItems': 1,
          'maxItems': maxNames,
          'items': {'type': 'string'},
        },
      },
      'required': ['names'],
      'additionalProperties': false,
    },
    source: _systemSource,
    category: 'system',
    workspaceRequired: false,
    approval: {
      'mode': 'default',
      'sensitive': true,
      'scope': 'once',
      'permission_class': 'secret_management',
    },
    execution: {'target': 'local_runtime', 'timeout_ms': 60000},
    serverName: 'system',
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    if (context == null || !_isOwner(context)) return _ownerRequired();
    final raw = args['names'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > maxNames ||
        raw.any(
          (name) =>
              name is! String || UserSecretVault.nameRejection(name) != null,
        )) {
      throw const FormatException(
        'names must list between 1 and $maxNames valid secret names.',
      );
    }
    final names = (raw.cast<String>().toSet().toList()..sort());
    await _permissionManager.ensureAuthorized(
      tool: toolSpec,
      arguments: {'names': names},
      context: context,
    );
    final List<String> deleted;
    try {
      deleted = await _userSecrets.remove(names);
    } catch (error) {
      return ToolExecutionResult.text(
        jsonEncode({
          'status': 'failed',
          'message': 'The Agent vault could not delete the secrets.',
        }),
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
    }
    return ToolExecutionResult.text(
      jsonEncode({
        'status': 'deleted',
        'deleted': deleted,
        'not_found': [
          for (final name in names)
            if (!deleted.contains(name)) name,
        ],
      }),
    );
  }
}
