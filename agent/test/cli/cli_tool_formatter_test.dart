import 'package:sanad_agent/cli/ui/cli_tool_formatter.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();
  group('CliToolFormatter', () {
    test(
      'formatPermissionTitle returns action-aware titles matching Flutter client',
      () {
        expect(
          CliToolFormatter.formatPermissionTitle('shell_execute'),
          'Allow Sanad to run this command?',
        );
        expect(
          CliToolFormatter.formatPermissionTitle('file_read'),
          'Allow Sanad to read this file?',
        );
        expect(
          CliToolFormatter.formatPermissionTitle('file_write'),
          'Allow Sanad to write to this file?',
        );
        expect(
          CliToolFormatter.formatPermissionTitle('file_edit'),
          'Allow Sanad to edit this file?',
        );
        expect(
          CliToolFormatter.formatPermissionTitle('search_glob'),
          'Allow Sanad to search for matching files?',
        );
        expect(
          CliToolFormatter.formatPermissionTitle('search_grep'),
          'Allow Sanad to search these files?',
        );
        expect(
          CliToolFormatter.formatPermissionTitle('mcp__github__create_issue'),
          'Allow Sanad to use this MCP tool?',
        );
        expect(
          CliToolFormatter.formatPermissionTitle('custom_unknown_tool'),
          'Allow Sanad to use this tool?',
        );
      },
    );

    test(
      'formatPermissionDetails formats shell_execute details with command and cwd',
      () {
        final details = CliToolFormatter.formatPermissionDetails(
          toolName: 'shell_execute',
          toolInput: {
            'command': 'git status',
            'cwd': '/repo/project',
            'timeout_ms': 5000,
          },
          workspaceName: 'my-workspace',
          workspacePath: '/repo/project',
        );

        final map = Map.fromEntries(details);
        expect(map['Command'], 'git status');
        expect(map['Directory'], '/repo/project');
        expect(map['Workspace'], 'my-workspace');
        expect(map['Timeout ms'], '5000');
      },
    );

    test(
      'formatPermissionDetails formats file tools with relative path and line numbers',
      () {
        final readDetails = CliToolFormatter.formatPermissionDetails(
          toolName: 'file_read',
          toolInput: {
            'path': '/repo/project/lib/main.dart',
            'offset': 9,
            'limit': 20,
          },
          workspaceName: 'my-workspace',
          workspacePath: '/repo/project',
        );
        final readMap = Map.fromEntries(readDetails);
        expect(readMap['File'], 'lib/main.dart');
        expect(readMap['Lines'], '#L10-29');

        final editDetails = CliToolFormatter.formatPermissionDetails(
          toolName: 'file_edit',
          toolInput: {
            'path': '/repo/project/lib/main.dart',
            'old_string': 'line 1\nline 2',
            'new_string': 'line 1\nline 2\nline 3',
          },
          workspacePath: '/repo/project',
        );
        final editMap = Map.fromEntries(editDetails);
        expect(editMap['File'], 'lib/main.dart');
        expect(editMap['Changes'], '+3 -2 lines');
      },
    );

    test(
      'formatPermissionDetails formats search tools with pattern and directory',
      () {
        final details = CliToolFormatter.formatPermissionDetails(
          toolName: 'search_grep',
          toolInput: {'pattern': 'TODO', 'path': '/repo/project/src'},
          workspacePath: '/repo/project',
        );
        final map = Map.fromEntries(details);
        expect(map['Pattern'], 'TODO');
        expect(map['Search Path'], 'src');
      },
    );

    test(
      'formatPermissionDetails formats MCP tools separating server and tool name',
      () {
        final details = CliToolFormatter.formatPermissionDetails(
          toolName: 'mcp__github__search_issues',
          toolInput: {'query': 'state:open label:bug'},
        );
        expect(details.first.value, 'github / search_issues');
        final map = Map.fromEntries(details);
        expect(map['Query'], 'state:open label:bug');
      },
    );

    test('formatToolCalling formats in-flight status strings', () {
      expect(
        CliToolFormatter.formatToolCalling('shell_execute', {
          'command': 'cargo build',
        }, ansi: false),
        '🔧 Running command: cargo build',
      );
      expect(
        CliToolFormatter.formatToolCalling(
          'file_read',
          {'path': '/app/README.md'},
          workspacePath: '/app',
          ansi: false,
        ),
        '🔧 Reading file: README.md',
      );
      expect(
        CliToolFormatter.formatToolCalling('search_grep', {
          'pattern': 'error',
        }, ansi: false),
        '🔧 Grep searching files: "error"',
      );
      expect(
        CliToolFormatter.formatToolCalling('web_search', {
          'query': 'canon 250d lenses',
        }, ansi: false),
        '🌐 Web Search: "canon 250d lenses"',
      );
      expect(
        CliToolFormatter.formatToolCalling('web_fetch', {
          'url': 'https://example.com',
        }, ansi: false),
        '🌐 Web Fetch: https://example.com',
      );
    });

    test(
      'formatToolResult formats title-only status summary with command and duration',
      () {
        final output = CliToolFormatter.formatToolResult(
          toolName: 'shell_execute',
          result: {
            'output': 'Files found:\nmain.dart\nhelper.dart',
            'stderr': 'warning: 1 deprecated api',
          },
          isError: false,
          arguments: {'command': 'find .'},
          duration: const Duration(milliseconds: 150),
          ansi: false,
        );

        expect(output, contains('shell_execute find .'));
        expect(output, contains('completed ✓ (0.15s)'));
      },
    );

    test(
      'formatToolResult formats title-only for web tools with query and url',
      () {
        final searchOutput = CliToolFormatter.formatToolResult(
          toolName: 'web_search',
          result: 'search results',
          arguments: {'query': 'canon 250d'},
          isError: false,
          duration: const Duration(milliseconds: 320),
          ansi: false,
        );
        expect(
          searchOutput,
          contains('web_search "canon 250d" completed ✓ (0.32s)'),
        );

        final fetchOutput = CliToolFormatter.formatToolResult(
          toolName: 'web_fetch',
          result: 'page content',
          arguments: {'url': 'https://noon.com/cameras'},
          isError: false,
          duration: const Duration(milliseconds: 450),
          ansi: false,
        );
        expect(
          fetchOutput,
          contains('web_fetch https://noon.com/cameras completed ✓ (0.45s)'),
        );
      },
    );

    test(
      'formatToolResult handles empty toolName gracefully without printing empty bracket',
      () {
        final output = CliToolFormatter.formatToolResult(
          toolName: '',
          result: 'Data received',
          isError: false,
          ansi: false,
        );

        expect(output, contains('[tool completed ✓]'));
      },
    );
  });
}
