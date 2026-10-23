// Plan 138 (138-03) — model-visible tool schema snapshot.
//
// Tool names and JSON schemas are what the model sees, so a move-only split of
// the per-turn catalog must not reword either. Each literal below is the exact
// schema the catalog produced when 138-03 landed; it is a characterization
// snapshot, not a specification. Change it only when a change is meant to alter
// the model-visible contract, never to make a move pass.

import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

/// Keeps the snapshot hermetic: the real manager reads the Sanad Home settings
/// document, which a Dart test must never open.
class _NoMcpRuntimeManager extends McpRuntimeManager {
  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}

const Map<String, Object> _platformTool = {
  'name': 'client_screenshot',
  'display_name': 'Client Screenshot',
  'description': 'Capture the client window.',
  'input_schema': {
    'type': 'object',
    'properties': {
      'target': {'type': 'string'},
    },
  },
  'platform_id': 'client-1',
  'category': 'platform_capture',
  'approval': {'mode': 'ask', 'sensitive': true},
};

/// Model-visible schemas for a workspace turn, in catalog order.
const Map<String, Map<String, Object?>> _workspaceTurnSchemas = {
  'web_search': {
    'description':
        'Search the web from the local runtime with optional domain filtering and result limits.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'allowed_domains': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Optional list of domains to restrict search results to (e.g. ["wikipedia.org"]).',
        },
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 10,
          'description':
              'Optional limit on the number of search hits returned.',
        },
      },
      'required': ['query'],
      'additionalProperties': false,
    },
  },
  'web_fetch': {
    'description':
        'Fetch the content of specific URLs concurrently and summarize them.',
    'parameters': {
      'type': 'object',
      'properties': {
        'urls': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'List of URLs to fetch content from (max 5 URLs).',
        },
        'prompt': {'type': 'string'},
      },
      'required': ['urls'],
      'additionalProperties': false,
    },
  },
  'skill_load': {
    'description':
        'Load a local skill definition from workspace or user skill directories.',
    'parameters': {
      'type': 'object',
      'properties': {
        'skill': {'type': 'string'},
      },
      'required': ['skill'],
      'additionalProperties': false,
    },
  },
  'system_ask_user': {
    'description':
        'Ask the user one or more clarifying questions (up to 5) to resolve design ambiguity, missing details, or decision-making. Halts session execution until the user responds. Each question must have exactly 3 options.',
    'parameters': {
      'type': 'object',
      'properties': {
        'questions': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 5,
          'items': {
            'type': 'object',
            'properties': {
              'question': {
                'type': 'string',
                'description': 'The clarifying question text.',
              },
              'options': {
                'type': 'array',
                'minItems': 3,
                'maxItems': 3,
                'items': {'type': 'string'},
                'description':
                    'Exactly 3 predefined options for the user to choose from.',
              },
            },
            'required': ['question', 'options'],
            'additionalProperties': false,
          },
        },
      },
      'required': ['questions'],
      'additionalProperties': false,
    },
  },
  'shell_execute': {
    'description':
        'Execute a shell command. Starts inside the active workspace; do not "cd" to it.',
    'parameters': {
      'type': 'object',
      'properties': {
        'command': {'type': 'string'},
        'cwd': {
          'type': 'string',
          'description':
              'Optional subdirectory relative to workspace root. Do not use for root.',
        },
        'timeout_ms': {'type': 'integer'},
        'description': {
          'type': 'string',
          'description':
              'A concise sentence of no more than seven words that explains to the user, in their own language, the purpose or goal of executing this command.',
        },
        'secrets': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': 16,
          'description':
              'Names of stored user secrets to expose to this command as environment variables. Only these are injected; values never appear in the result.',
        },
      },
      'required': ['command', 'description'],
      'additionalProperties': false,
    },
  },
  'file_read': {
    'description':
        'Read a file or list a directory. Paths inside the workspace execute directly; external paths require full access or user approval. Files return up to 2000 lines, with offset for later sections, and directories return paginated entries.',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'offset': {'type': 'integer', 'minimum': 0},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 2000},
      },
      'required': ['path'],
      'additionalProperties': false,
    },
  },
  'file_write': {
    'description':
        'Create or replace a text file inside the workspace or at an authorized external path.',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
      'additionalProperties': false,
    },
  },
  'file_edit': {
    'description':
        'Perform exact string replacements inside the workspace or in an authorized external file. Provide either old_string and new_string for a single replacement, or edits for multiple non-contiguous replacements in the same file. Each old_string must preserve indentation and must not include file_read line-number prefixes. Fails atomically if any match is missing or ambiguous unless replace_all is true, or if edits overlap.',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'old_string': {'type': 'string'},
        'new_string': {'type': 'string'},
        'replace_all': {'type': 'boolean'},
        'edits': {
          'type': 'array',
          'description':
              'Optional list of edits to apply in one call. Each edit requires old_string and new_string.',
          'items': {
            'type': 'object',
            'properties': {
              'old_string': {'type': 'string'},
              'new_string': {'type': 'string'},
              'replace_all': {'type': 'boolean'},
            },
            'required': ['old_string', 'new_string'],
            'additionalProperties': false,
          },
        },
      },
      'required': ['path'],
      'additionalProperties': false,
    },
  },
  'search_glob': {
    'description':
        'Match file patterns in the workspace or an authorized external directory. Supports patterns like "**/*.dart" and returns matches sorted by modification time.',
    'parameters': {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string'},
        'path': {'type': 'string'},
      },
      'required': ['pattern'],
      'additionalProperties': false,
    },
  },
  'search_grep': {
    'description':
        'Search file contents in the workspace or an authorized external path using regular expressions, with optional glob filtering and line-numbered matches.',
    'parameters': {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string'},
        'path': {'type': 'string'},
        'glob': {'type': 'string'},
        'line_numbers': {'type': 'boolean'},
        'case_insensitive': {'type': 'boolean'},
        'head_limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        'offset': {'type': 'integer', 'minimum': 0},
        'before': {'type': 'integer', 'minimum': 0, 'maximum': 20},
        'after': {'type': 'integer', 'minimum': 0, 'maximum': 20},
        'context': {'type': 'integer', 'minimum': 0, 'maximum': 20},
      },
      'required': ['pattern'],
      'additionalProperties': false,
    },
  },
  'view_image': {
    'description':
        'Inspect one local PNG, JPEG, or WebP image from the current workspace or admitted session attachments.',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'detail': {
          'type': 'string',
          'enum': ['low', 'auto', 'high', 'original'],
          'default': 'auto',
        },
      },
      'required': ['path'],
      'additionalProperties': false,
    },
  },
};

/// Schemas a turn adds beyond the workspace set: the owner-only secret
/// tools and the platform tool mapping.
const Map<String, Map<String, Object?>> _ownerTurnAdditions = {
  'system_request_secret': {
    'description':
        'Ask the user to enter secrets (API keys, passwords, tokens) in a secure Sanad Client form. Values are stored in the Agent vault and are never shown to you; you receive only the stored names. Use a name later in shell_execute "secrets". Never ask for secrets in chat.',
    'parameters': {
      'type': 'object',
      'properties': {
        'reason': {
          'type': 'string',
          'description': 'Why the secrets are needed, shown to the user.',
        },
        'fields': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 10,
          'items': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description':
                    'Environment variable name the value is stored and injected under, for example DATABASE_PASSWORD.',
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
                    'Hide the typed value (default true). Use false only for non-sensitive inputs such as a username.',
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
  },
  'system_list_secrets': {
    'description':
        'List the names of user secrets stored in the Agent vault. Values are never returned.',
    'parameters': {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
  },
  'system_delete_secret': {
    'description':
        'Permanently delete user secrets from the Agent vault by name. The user must approve.',
    'parameters': {
      'type': 'object',
      'properties': {
        'names': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 16,
          'items': {'type': 'string'},
        },
      },
      'required': ['names'],
      'additionalProperties': false,
    },
  },
  'client_screenshot': {
    'description': 'Capture the client window.',
    'parameters': {
      'type': 'object',
      'properties': {
        'target': {'type': 'string'},
      },
    },
  },
};

void main() {
  useIsolatedSanadStateRoot();

  late Directory sanadHome;
  late LocalRuntimeCatalog catalog;

  setUp(() async {
    sanadHome = await Directory.systemTemp.createTemp('tool_schema_snapshot');
    catalog = LocalRuntimeCatalog(
      workspaceRuntimeService: LocalWorkspaceRuntimeService(
        sanadHomePath: sanadHome.path,
        currentWorkingDirectory: sanadHome.path,
      ),
      mcpRuntimeManager: _NoMcpRuntimeManager(),
    );
  });

  tearDown(() async {
    await sanadHome.delete(recursive: true);
  });

  test('a workspace turn exposes exactly these model-visible tools', () async {
    final tools = await catalog.buildTools(
      registry: ToolsRegistry(),
      request: AgentTurnRequest(
        sessionId: 'thread-schema',
        message: 'schema snapshot',
        workspaceId: sanadHome.path,
      ),
    );

    expect(tools.map((tool) => tool.schema.name).toList(), <String>[
      'web_search',
      'web_fetch',
      'skill_load',
      'system_ask_user',
      'shell_execute',
      'file_read',
      'file_write',
      'file_edit',
      'search_glob',
      'search_grep',
      'view_image',
    ]);
    _expectSchemas(tools, _workspaceTurnSchemas);
  });

  test(
    'an owner turn without a workspace adds only the owner and platform tools',
    () async {
      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 'thread-schema',
          message: 'schema snapshot',
          metadata: CommandAuthority.stampTurnMetadata({
            'platform_tools': [_platformTool],
          }, CommandAuthority.owner),
        ),
      );

      expect(tools.map((tool) => tool.schema.name).toList(), <String>[
        'web_search',
        'web_fetch',
        'skill_load',
        'system_ask_user',
        'system_request_secret',
        'system_list_secrets',
        'system_delete_secret',
        'client_screenshot',
      ]);
      _expectSchemas(tools, _ownerTurnAdditions);
    },
  );

  test('an attachment-only turn still offers view_image', () async {
    final attachmentCatalog = LocalRuntimeCatalog(
      workspaceRuntimeService: LocalWorkspaceRuntimeService(
        sanadHomePath: sanadHome.path,
        currentWorkingDirectory: sanadHome.path,
      ),
      mcpRuntimeManager: _NoMcpRuntimeManager(),
      admittedAttachmentPathsResolver: (sessionId) async => [
        '${sanadHome.path}/attachments/shot.png',
      ],
    );

    final tools = await attachmentCatalog.buildTools(
      registry: ToolsRegistry(),
      request: const AgentTurnRequest(
        sessionId: 'thread-schema',
        message: 'schema snapshot',
      ),
    );

    expect(tools.map((tool) => tool.schema.name).toList(), <String>[
      'web_search',
      'web_fetch',
      'skill_load',
      'system_ask_user',
      'view_image',
    ]);
    _expectSchemas(tools, {'view_image': _workspaceTurnSchemas['view_image']!});
  });
}

/// Asserts every expected tool kept its exact model-visible schema.
void _expectSchemas(
  List<BaseTool> tools,
  Map<String, Map<String, Object?>> expected,
) {
  final actual = <String, Map<String, Object?>>{
    for (final tool in tools)
      if (expected.containsKey(tool.schema.name))
        tool.schema.name: {
          'description': tool.schema.description,
          'parameters': tool.schema.parameters,
        },
  };

  expect(
    actual,
    expected,
    reason:
        'The model-visible tool schemas changed. A move-only split must not '
        'reword a name, description, or JSON schema.',
  );
}
