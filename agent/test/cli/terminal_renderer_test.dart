import 'package:test/test.dart';

import 'package:sanad_agent/cli/cli.dart';
import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();
  group('ANSI Utilities & TerminalTheme', () {
    test('Ansi.strip removes all ANSI sequences', () {
      final input =
          '\x1B[1m\x1B[31mBold Red Text\x1B[0m and \x1B[36mCyan\x1B[0m';
      expect(Ansi.strip(input), 'Bold Red Text and Cyan');
      expect(Ansi.visibleLength(input), 'Bold Red Text and Cyan'.length);
    });

    test('Ansi.wrap wraps text with style and reset', () {
      final styled = Ansi.wrap('Hello', Ansi.bold);
      expect(styled, '${Ansi.bold}Hello${Ansi.reset}');
      expect(Ansi.wrap('Hello', Ansi.bold, enabled: false), 'Hello');
    });

    test('TerminalTheme.plain emits no ANSI codes', () {
      final theme = TerminalTheme.plain();
      expect(theme.enableColor, isFalse);
      expect(theme.bold, '');
      expect(theme.h1, '');
      expect(theme.style('text', theme.h1), 'text');
    });

    test('TerminalTheme.dark and light have active ANSI color codes', () {
      final dark = TerminalTheme.dark();
      final light = TerminalTheme.light();
      expect(dark.enableColor, isTrue);
      expect(light.enableColor, isTrue);
      expect(dark.h1, contains('\x1B['));
      expect(light.h1, contains('\x1B['));
    });
  });

  group('SyntaxHighlighter', () {
    late TerminalTheme darkTheme;
    late SyntaxHighlighter highlighter;

    setUp(() {
      darkTheme = TerminalTheme.dark();
      highlighter = SyntaxHighlighter(darkTheme);
    });

    test('highlights Dart keywords, types, strings, numbers, and comments', () {
      final code = '''
// Main entry point
void main() {
  final int count = 42;
  String greeting = "Hello Dart";
  print(greeting);
}
''';
      final highlighted = highlighter.highlight(code, language: 'dart');
      expect(highlighted, contains(darkTheme.syntaxComment));
      expect(highlighted, contains(darkTheme.syntaxKeyword));
      expect(highlighted, contains(darkTheme.syntaxType));
      expect(highlighted, contains(darkTheme.syntaxString));
      expect(highlighted, contains(darkTheme.syntaxNumber));
      expect(Ansi.strip(highlighted).trim(), code.trim());
    });

    test('highlights Python syntax including comments and numbers', () {
      final code = '''
# Python script
def calculate_total(items):
    total = 100.50
    is_valid = True
    return total
''';
      final highlighted = highlighter.highlight(code, language: 'python');
      expect(highlighted, contains(darkTheme.syntaxComment));
      expect(highlighted, contains(darkTheme.syntaxKeyword));
      expect(highlighted, contains(darkTheme.syntaxNumber));
      expect(Ansi.strip(highlighted).trim(), code.trim());
    });

    test('highlights Bash commands, comments, and keywords', () {
      final code = '''
# Setup workspace
if [ ! -d "build" ]; then
  mkdir -p build
  echo "Created directory"
fi
''';
      final highlighted = highlighter.highlight(code, language: 'bash');
      expect(highlighted, contains(darkTheme.syntaxComment));
      expect(highlighted, contains(darkTheme.syntaxKeyword));
      expect(highlighted, contains(darkTheme.syntaxType)); // echo, mkdir
      expect(Ansi.strip(highlighted).trim(), code.trim());
    });

    test('highlights JSON keys, strings, booleans, and numbers', () {
      final code = '''
{
  "name": "sanad_agent",
  "version": 1,
  "active": true,
  "nullVal": null
}
''';
      final highlighted = highlighter.highlight(code, language: 'json');
      expect(highlighted, contains(darkTheme.syntaxType)); // JSON keys
      expect(highlighted, contains(darkTheme.syntaxString)); // string values
      expect(highlighted, contains(darkTheme.syntaxKeyword)); // true, null
      expect(highlighted, contains(darkTheme.syntaxNumber)); // 1
      expect(Ansi.strip(highlighted).trim(), code.trim());
    });

    test('highlights YAML keys, values, and comments', () {
      final code = '''
# Config
app_name: "sanad"
timeout_seconds: 30
debug: false
''';
      final highlighted = highlighter.highlight(code, language: 'yaml');
      expect(highlighted, contains(darkTheme.syntaxComment));
      expect(highlighted, contains(darkTheme.syntaxType)); // keys
      expect(highlighted, contains(darkTheme.syntaxNumber));
      expect(highlighted, contains(darkTheme.syntaxKeyword));
      expect(Ansi.strip(highlighted).trim(), code.trim());
    });

    test('returns plain unformatted code when color is disabled', () {
      final plainHighlighter = SyntaxHighlighter(TerminalTheme.plain());
      final code = 'void main() { print("hello"); }';
      expect(plainHighlighter.highlight(code, language: 'dart'), code);
    });
  });

  group('MarkdownRenderer', () {
    late MarkdownRenderer renderer;
    late MarkdownRenderer plainRenderer;

    setUp(() {
      renderer = MarkdownRenderer(theme: TerminalTheme.dark());
      plainRenderer = MarkdownRenderer(theme: TerminalTheme.plain());
    });

    test('renders headers (# H1, ## H2, ### H3)', () {
      final md = '''
# Heading 1
## Heading 2
### Heading 3
''';
      final rendered = renderer.render(md);
      expect(rendered, contains('Heading 1'));
      expect(rendered, contains('Heading 2'));
      expect(rendered, contains('Heading 3'));
      expect(rendered, contains('═')); // H1 bar
      expect(rendered, contains('─')); // H2 bar

      final plain = plainRenderer.render(md);
      expect(plain, contains('# Heading 1'));
      expect(plain, contains('## Heading 2'));
      expect(plain, contains('### Heading 3'));
      expect(plain, isNot(contains('\x1B[')));
    });

    test(
      'renders inline styles: bold, italic, bold+italic, strikethrough, and inline code',
      () {
        final md =
            'This is **bold**, *italic*, ***both***, ~~strike~~, and `code_snippet`.';
        final rendered = renderer.render(md);
        expect(rendered, contains('bold'));
        expect(rendered, contains('italic'));
        expect(rendered, contains('both'));
        expect(rendered, contains('strike'));
        expect(rendered, contains('code_snippet'));

        final stripped = Ansi.strip(rendered);
        expect(stripped, contains('bold'));
        expect(stripped, contains('italic'));
        expect(stripped, contains('both'));
        expect(stripped, contains('code_snippet'));

        final plain = plainRenderer.render(md);
        expect(plain, isNot(contains('\x1B[')));
        expect(plain, contains('`code_snippet`'));
      },
    );

    test('renders unordered and ordered lists with correct indentation', () {
      final md = '''
- Item A
- Item B
  - Nested B1
1. First step
2. Second step
''';
      final rendered = renderer.render(md);
      final stripped = Ansi.strip(rendered);
      expect(stripped, contains('• Item A'));
      expect(stripped, contains('• Item B'));
      expect(stripped, contains('⁃ Nested B1'));
      expect(stripped, contains('1. First step'));
      expect(stripped, contains('2. Second step'));

      final plain = plainRenderer.render(md);
      expect(plain, isNot(contains('\x1B[')));
      expect(plain, contains('Item A'));
      expect(plain, contains('1. First step'));
    });

    test('renders blockquotes with vertical borders', () {
      final md = '''
> This is a blockquote line 1
> This is line 2 of the quote
''';
      final rendered = renderer.render(md);
      expect(rendered, contains('│'));
      expect(rendered, contains('This is a blockquote line 1'));
      expect(rendered, contains('This is line 2 of the quote'));

      final plain = plainRenderer.render(md);
      expect(plain, isNot(contains('\x1B[')));
      expect(plain, contains('| This is a blockquote line 1'));
    });

    test('renders horizontal rules (---, ***, ___)', () {
      final md = '''
Text above
---
Text below
''';
      final rendered = renderer.render(md);
      expect(rendered, contains('───'));
      expect(rendered, contains('Text above'));
      expect(rendered, contains('Text below'));

      final plain = plainRenderer.render(md);
      expect(plain, isNot(contains('\x1B[')));
      expect(plain, contains('---'));
    });

    test('renders links formatted with label and url', () {
      final md = 'Visit [Sanad Docs](https://sanad.ai/docs) for information.';
      final rendered = renderer.render(md);
      expect(rendered, contains('Sanad Docs'));
      expect(rendered, contains('(https://sanad.ai/docs)'));

      final plain = plainRenderer.render(md);
      expect(plain, isNot(contains('\x1B[')));
      expect(
        plain,
        'Visit Sanad Docs (https://sanad.ai/docs) for information.',
      );
    });

    test('renders fenced code blocks with language header and borders', () {
      final md = '''
```dart
void main() {
  print("test");
}
```
''';
      final rendered = renderer.render(md);
      final stripped = Ansi.strip(rendered);
      expect(stripped, contains('╭─ dart'));
      expect(stripped, contains('│'));
      expect(stripped, contains('╰─'));
      expect(stripped, contains('void'));
      expect(stripped, contains('print'));

      final plain = plainRenderer.render(md);
      expect(plain, isNot(contains('\x1B[')));
      expect(plain, contains('```dart'));
      expect(plain, contains('void main()'));
      expect(plain, contains('```'));
    });

    test('renders Markdown tables with aligned columns and borders', () {
      final md = '''
| ID | Command | Status |
|---|:---:|---:|
| 1 | sanad run | ready |
| 2 | sanad chat | pending |
''';
      final rendered = renderer.render(md);
      expect(rendered, contains('┌'));
      expect(rendered, contains('ID'));
      expect(rendered, contains('Command'));
      expect(rendered, contains('Status'));
      expect(rendered, contains('sanad run'));
      expect(rendered, contains('sanad chat'));
      expect(rendered, contains('└'));

      final plain = plainRenderer.render(md);
      expect(plain, isNot(contains('\x1B[')));
      expect(plain, contains('+'));
      expect(plain, contains('ID'));
      expect(plain, contains('Command'));
      expect(plain, contains('Status'));
    });
  });

  group('ToolProgressSpinner', () {
    late StringBuffer stdoutBuffer;

    setUp(() {
      stdoutBuffer = StringBuffer();
    });

    test('emits static calling and success lines in non-TTY environment', () {
      final spinner = ToolProgressSpinner(
        stdoutSink: stdoutBuffer,
        theme: TerminalTheme.dark(),
        isTerminal: false,
        mode: ToolProgressMode.all,
      );

      spinner.start(
        toolCallId: 'call-1',
        toolName: 'read_workspace_file',
        arguments: {'path': 'README.md'},
      );

      spinner.success(toolCallId: 'call-1', result: 'file content');

      final out = stdoutBuffer.toString();
      final stripped = Ansi.strip(out);
      expect(stripped, contains('🔧 [Calling tool: read_workspace_file]'));
      expect(stripped, contains('[Tool read_workspace_file completed ✓]'));
      // Verifies no cursor movement sequences pollute stdout in non-TTY mode
      expect(out, isNot(contains('\r\x1B[2K')));
    });

    test('emits failure status line when tool fails', () {
      final spinner = ToolProgressSpinner(
        stdoutSink: stdoutBuffer,
        theme: TerminalTheme.dark(),
        isTerminal: false,
        mode: ToolProgressMode.all,
      );

      spinner.start(toolCallId: 'call-2', toolName: 'execute_shell');
      spinner.failure(toolCallId: 'call-2', error: 'Command not found');

      final out = stdoutBuffer.toString();
      final stripped = Ansi.strip(out);
      expect(stripped, contains('🔧 [Calling tool: execute_shell]'));
      expect(stripped, contains('[Tool execute_shell failed ❌]'));
    });

    test('emits cancelled status line when tool is cancelled', () {
      final spinner = ToolProgressSpinner(
        stdoutSink: stdoutBuffer,
        theme: TerminalTheme.dark(),
        isTerminal: false,
        mode: ToolProgressMode.all,
      );

      spinner.start(toolCallId: 'call-3', toolName: 'long_task');
      spinner.cancel(toolCallId: 'call-3');

      final out = stdoutBuffer.toString();
      expect(out, contains('[Tool long_task cancelled]'));
    });

    test('mode=off suppresses all output', () {
      final spinner = ToolProgressSpinner(
        stdoutSink: stdoutBuffer,
        mode: ToolProgressMode.off,
      );

      spinner.start(toolCallId: 'call-4', toolName: 'any_tool');
      spinner.success(toolCallId: 'call-4', result: 'ok');

      expect(stdoutBuffer.toString(), isEmpty);
    });

    test('mode=verbose outputs arguments and result preview', () {
      final spinner = ToolProgressSpinner(
        stdoutSink: stdoutBuffer,
        theme: TerminalTheme.dark(),
        isTerminal: false,
        mode: ToolProgressMode.verbose,
      );

      spinner.start(
        toolCallId: 'call-5',
        toolName: 'http_request',
        arguments: {'url': 'https://api.sanad.ai', 'method': 'GET'},
      );

      spinner.success(
        toolCallId: 'call-5',
        result: {'status': 200, 'body': 'OK'},
      );

      final out = stdoutBuffer.toString();
      expect(out, contains('Calling tool: http_request'));
      expect(out, contains('Tool http_request completed ✓'));
      expect(out, contains('↳ result:'));
    });

    test('interactive animated frames in simulated terminal', () async {
      final spinner = ToolProgressSpinner(
        stdoutSink: stdoutBuffer,
        theme: TerminalTheme.dark(),
        isTerminal: true,
        mode: ToolProgressMode.all,
        tickInterval: const Duration(milliseconds: 10),
      );

      spinner.start(toolCallId: 'call-sim', toolName: 'search_catalog');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      spinner.success(toolCallId: 'call-sim', result: 'done');
      spinner.dispose();

      final out = stdoutBuffer.toString();
      expect(out, contains('\r\x1B[2K')); // animated in-place line clearing
      expect(out, contains('search_catalog'));
      expect(out, contains('completed ✓'));
    });

    test('ToolProgressMode.fromString parses modes correctly', () {
      expect(ToolProgressMode.fromString('off'), ToolProgressMode.off);
      expect(ToolProgressMode.fromString('none'), ToolProgressMode.off);
      expect(ToolProgressMode.fromString('new'), ToolProgressMode.newOnly);
      expect(ToolProgressMode.fromString('newonly'), ToolProgressMode.newOnly);
      expect(ToolProgressMode.fromString('verbose'), ToolProgressMode.verbose);
      expect(ToolProgressMode.fromString('all'), ToolProgressMode.all);
      expect(ToolProgressMode.fromString(null), ToolProgressMode.all);
    });
  });

  group('ReasoningBox & ReasoningStreamHandler', () {
    late TerminalTheme darkTheme;
    late ReasoningBox box;

    setUp(() {
      darkTheme = TerminalTheme.dark();
      box = ReasoningBox(theme: darkTheme);
    });

    test('renders full stylized reasoning box with headers and borders', () {
      final thought = '''
1. Inspect requirements.
2. Formulate execution plan.
3. Validate output.
''';
      final rendered = box.render(
        thought,
        duration: const Duration(milliseconds: 1200),
        tokenCount: 45,
      );

      expect(rendered, contains('Thinking'));
      expect(rendered, contains('1.2s'));
      expect(rendered, contains('45 tokens'));
      expect(rendered, contains('╭─'));
      expect(rendered, contains('│'));
      expect(rendered, contains('╰─'));
      expect(rendered, contains('Inspect requirements'));
    });

    test('renders compact collapsible recap', () {
      final recap = box.renderRecap(
        duration: const Duration(milliseconds: 2500),
        tokenCount: 88,
        wordCount: 24,
        summary: 'Formulated plan',
      );

      expect(recap, contains('💭'));
      expect(recap, contains('Thought for 2.5s'));
      expect(recap, contains('24 words'));
      expect(recap, contains('88 tokens'));
      expect(recap, contains('Formulated plan'));
    });

    test('renders reasoning box in plain theme without ANSI', () {
      final plainBox = ReasoningBox(theme: TerminalTheme.plain());
      final rendered = plainBox.render('Analyzing query...');
      expect(rendered, isNot(contains('\x1B[')));
      expect(rendered, contains('+- Thinking'));
      expect(rendered, contains('| Analyzing query...'));
    });

    test(
      'ReasoningStreamHandler streams tokens and finishes with box or recap',
      () {
        final buffer = StringBuffer();
        final handler = ReasoningStreamHandler(
          stdoutSink: buffer,
          theme: darkTheme,
          isTerminal: false,
          collapsible: false,
        );

        handler.addChunk('Thinking through problem... ');
        handler.addChunk('Step 1 complete.');
        handler.finish();

        final out = buffer.toString();
        expect(out, contains('Thinking'));
        expect(out, contains('Thinking through problem... '));
        expect(out, contains('Step 1 complete.'));

        // Test collapsible handler
        final recapBuffer = StringBuffer();
        final collapsibleHandler = ReasoningStreamHandler(
          stdoutSink: recapBuffer,
          theme: darkTheme,
          isTerminal: false,
          collapsible: true,
        );

        collapsibleHandler.addChunk('Hidden inner thoughts');
        collapsibleHandler.finish(summary: 'Finished chain-of-thought');

        final recapOut = recapBuffer.toString();
        expect(recapOut, contains('Thought for'));
        expect(recapOut, contains('Finished chain-of-thought'));
        expect(
          recapOut,
          isNot(contains('Hidden inner thoughts')),
        ); // suppressed in recap mode
      },
    );
  });

  group('TerminalRenderer Unified API', () {
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;
    late TerminalRenderer renderer;

    setUp(() {
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
      renderer = TerminalRenderer(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        isTerminal: false,
        enableColor: true,
        theme: TerminalTheme.dark(),
        terminalWidth: 80,
      );
    });

    test('renders banner with title, subtitle, and metadata', () {
      renderer.renderBanner(
        title: 'Sanad Agent CLI',
        subtitle: 'Autonomous AI Terminal Assistant',
        metadata: {'Workspace': 'sanad-agent', 'Model': 'gpt-4o'},
      );

      final out = stdoutBuf.toString();
      final stripped = Ansi.strip(out);
      expect(stripped, contains('Sanad Agent CLI'));
      expect(stripped, contains('Autonomous AI Terminal Assistant'));
      expect(stripped, contains('Workspace: sanad-agent'));
      expect(stripped, contains('Model: gpt-4o'));
    });

    test('renders error, warning, notice, and success messages', () {
      renderer.renderError('Critical failure', code: 'E_FATAL', isFatal: true);
      renderer.renderWarning('Connection sluggish');
      renderer.renderNotice('Daemon connected on port 58085');
      renderer.renderSuccess('Operation completed successfully');

      final errOut = stderrBuf.toString();
      final stdOut = stdoutBuf.toString();

      expect(errOut, contains('FATAL ERROR'));
      expect(errOut, contains('E_FATAL'));
      expect(errOut, contains('Critical failure'));
      expect(errOut, contains('WARNING'));
      expect(errOut, contains('Connection sluggish'));

      expect(stdOut, contains('Daemon connected on port 58085'));
      expect(stdOut, contains('Operation completed successfully'));
    });

    test('formatTable formats matrix into table with borders', () {
      final table = renderer.formatTable(
        ['Tool', 'Calls', 'Duration'],
        [
          ['grep', '3', '0.4s'],
          ['write_file', '1', '0.1s'],
        ],
      );

      expect(table, contains('Tool'));
      expect(table, contains('Calls'));
      expect(table, contains('Duration'));
      expect(table, contains('grep'));
      expect(table, contains('write_file'));
      expect(table, contains('┌'));
      expect(table, contains('└'));
    });

    test('renderMarkdown delegates to MarkdownRenderer', () {
      final res = renderer.renderMarkdown('# Header\n**Bold Text**');
      expect(res, contains('Header'));
      expect(res, contains('Bold Text'));
    });

    test('createToolSpinner respects renderer configuration', () {
      final spinner = renderer.createToolSpinner();
      expect(spinner.isTerminal, isFalse);
      expect(spinner.mode, ToolProgressMode.all);
    });
  });
}
