import 'ansi_styles.dart';
import 'terminal_theme.dart';

/// Lightweight, deterministic terminal syntax highlighter for common programming languages.
class SyntaxHighlighter {
  final TerminalTheme theme;

  const SyntaxHighlighter(this.theme);

  /// Highlights [code] according to [language].
  /// If language is unknown or colors are disabled, returns unformatted [code].
  String highlight(String code, {String? language}) {
    if (!theme.enableColor || code.isEmpty) {
      return code;
    }

    final lang = (language ?? '').trim().toLowerCase();
    switch (lang) {
      case 'dart':
        return _highlightDart(code);
      case 'py':
      case 'python':
        return _highlightPython(code);
      case 'sh':
      case 'bash':
      case 'shell':
      case 'zsh':
        return _highlightBash(code);
      case 'json':
        return _highlightJson(code);
      case 'yaml':
      case 'yml':
        return _highlightYaml(code);
      case 'js':
      case 'javascript':
      case 'ts':
      case 'typescript':
        return _highlightJavaScript(code);
      case 'sql':
        return _highlightSql(code);
      default:
        return code;
    }
  }

  // --- Dart Highlighting ---
  String _highlightDart(String code) {
    const keywords = {
      'abstract',
      'as',
      'assert',
      'async',
      'await',
      'break',
      'case',
      'catch',
      'class',
      'const',
      'continue',
      'covariant',
      'default',
      'deferred',
      'do',
      'dynamic',
      'else',
      'enum',
      'export',
      'extends',
      'extension',
      'external',
      'factory',
      'false',
      'final',
      'finally',
      'for',
      'Function',
      'get',
      'hide',
      'if',
      'implements',
      'import',
      'in',
      'interface',
      'is',
      'late',
      'library',
      'mixin',
      'new',
      'null',
      'of',
      'on',
      'operator',
      'part',
      'required',
      'rethrow',
      'return',
      'sealed',
      'set',
      'show',
      'static',
      'super',
      'switch',
      'sync',
      'this',
      'throw',
      'true',
      'try',
      'typedef',
      'var',
      'void',
      'while',
      'with',
      'yield',
    };

    const types = {
      'int',
      'double',
      'num',
      'String',
      'bool',
      'List',
      'Map',
      'Set',
      'Future',
      'Stream',
      'DateTime',
      'Duration',
      'Object',
      'Iterable',
      'Completer',
      'StreamSubscription',
      'Uri',
      'BigInt',
      'RegExp',
    };

    return _tokenizeAndHighlight(
      code,
      keywords: keywords,
      types: types,
      lineCommentPrefix: '//',
      blockCommentStart: '/*',
      blockCommentEnd: '*/',
    );
  }

  // --- Python Highlighting ---
  String _highlightPython(String code) {
    const keywords = {
      'and',
      'as',
      'assert',
      'async',
      'await',
      'break',
      'class',
      'continue',
      'def',
      'del',
      'elif',
      'else',
      'except',
      'False',
      'finally',
      'for',
      'from',
      'global',
      'if',
      'import',
      'in',
      'is',
      'lambda',
      'None',
      'nonlocal',
      'not',
      'or',
      'pass',
      'raise',
      'return',
      'True',
      'try',
      'while',
      'with',
      'yield',
    };

    const types = {
      'int',
      'float',
      'str',
      'bool',
      'list',
      'dict',
      'set',
      'tuple',
      'bytes',
      'object',
      'print',
      'len',
      'range',
      'enumerate',
      'zip',
      'map',
      'filter',
      'isinstance',
      'issubclass',
      'type',
      'super',
    };

    return _tokenizeAndHighlight(
      code,
      keywords: keywords,
      types: types,
      lineCommentPrefix: '#',
    );
  }

  // --- Bash Highlighting ---
  String _highlightBash(String code) {
    const keywords = {
      'if',
      'then',
      'else',
      'elif',
      'fi',
      'case',
      'esac',
      'for',
      'select',
      'while',
      'until',
      'do',
      'done',
      'in',
      'function',
      'time',
      'return',
      'exit',
      'export',
      'source',
      'local',
      'readonly',
      'alias',
      'set',
    };

    const types = {
      'echo',
      'cat',
      'grep',
      'sed',
      'awk',
      'find',
      'mkdir',
      'rm',
      'cp',
      'mv',
      'curl',
      'wget',
      'git',
      'chmod',
      'chown',
      'tar',
      'gzip',
      'docker',
      'fvm',
      'dart',
      'flutter',
      'python',
      'sanad',
    };

    return _tokenizeAndHighlight(
      code,
      keywords: keywords,
      types: types,
      lineCommentPrefix: '#',
    );
  }

  // --- JavaScript / TypeScript Highlighting ---
  String _highlightJavaScript(String code) {
    const keywords = {
      'async',
      'await',
      'break',
      'case',
      'catch',
      'class',
      'const',
      'continue',
      'debugger',
      'default',
      'delete',
      'do',
      'else',
      'export',
      'extends',
      'false',
      'finally',
      'for',
      'function',
      'if',
      'import',
      'in',
      'instanceof',
      'let',
      'new',
      'null',
      'return',
      'super',
      'switch',
      'this',
      'throw',
      'true',
      'try',
      'typeof',
      'var',
      'void',
      'while',
      'with',
      'yield',
    };

    const types = {
      'Array',
      'Boolean',
      'Date',
      'Error',
      'Function',
      'JSON',
      'Math',
      'Number',
      'Object',
      'Promise',
      'RegExp',
      'String',
      'Symbol',
      'console',
      'window',
      'document',
      'any',
      'number',
      'string',
      'boolean',
      'never',
      'unknown',
    };

    return _tokenizeAndHighlight(
      code,
      keywords: keywords,
      types: types,
      lineCommentPrefix: '//',
      blockCommentStart: '/*',
      blockCommentEnd: '*/',
    );
  }

  // --- SQL Highlighting ---
  String _highlightSql(String code) {
    const keywords = {
      'SELECT',
      'FROM',
      'WHERE',
      'INSERT',
      'INTO',
      'VALUES',
      'UPDATE',
      'SET',
      'DELETE',
      'CREATE',
      'TABLE',
      'DROP',
      'ALTER',
      'INDEX',
      'JOIN',
      'LEFT',
      'RIGHT',
      'INNER',
      'OUTER',
      'FULL',
      'ON',
      'AS',
      'AND',
      'OR',
      'NOT',
      'NULL',
      'IS',
      'IN',
      'BETWEEN',
      'LIKE',
      'GROUP',
      'BY',
      'ORDER',
      'ASC',
      'DESC',
      'HAVING',
      'LIMIT',
      'OFFSET',
      'UNION',
      'ALL',
      'CASE',
      'WHEN',
      'THEN',
      'ELSE',
      'END',
      'PRIMARY',
      'KEY',
      'FOREIGN',
      'REFERENCES',
      'select',
      'from',
      'where',
      'insert',
      'into',
      'values',
      'update',
      'set',
      'delete',
      'create',
      'table',
      'drop',
      'alter',
      'index',
      'join',
      'left',
      'right',
      'inner',
      'outer',
      'full',
      'on',
      'as',
      'and',
      'or',
      'not',
      'null',
      'is',
      'in',
      'between',
      'like',
      'group',
      'by',
      'order',
      'asc',
      'desc',
      'having',
      'limit',
      'offset',
      'union',
      'all',
      'case',
      'when',
      'then',
      'else',
      'end',
      'primary',
      'key',
      'foreign',
      'references',
    };

    const types = {
      'INTEGER',
      'TEXT',
      'REAL',
      'BLOB',
      'VARCHAR',
      'BOOLEAN',
      'TIMESTAMP',
      'COUNT',
      'SUM',
      'AVG',
      'MIN',
      'MAX',
      'COALESCE',
    };

    return _tokenizeAndHighlight(
      code,
      keywords: keywords,
      types: types,
      lineCommentPrefix: '--',
      blockCommentStart: '/*',
      blockCommentEnd: '*/',
    );
  }

  // --- JSON Highlighting ---
  String _highlightJson(String code) {
    final buffer = StringBuffer();
    int i = 0;
    final len = code.length;

    while (i < len) {
      final ch = code[i];

      // String (key or value)
      if (ch == '"') {
        int start = i;
        i++;
        while (i < len && code[i] != '"') {
          if (code[i] == '\\' && i + 1 < len) i++;
          i++;
        }
        if (i < len) i++; // consume closing quote
        final str = code.substring(start, i);

        // Check if this string is a JSON key (followed by optional spaces and ':')
        int peek = i;
        while (peek < len &&
            (code[peek] == ' ' ||
                code[peek] == '\t' ||
                code[peek] == '\n' ||
                code[peek] == '\r')) {
          peek++;
        }
        if (peek < len && code[peek] == ':') {
          buffer.write('${theme.syntaxType}$str${Ansi.reset}');
        } else {
          buffer.write('${theme.syntaxString}$str${Ansi.reset}');
        }
        continue;
      }

      // Numbers
      if (_isDigit(ch) || (ch == '-' && i + 1 < len && _isDigit(code[i + 1]))) {
        int start = i;
        i++;
        while (i < len &&
            (_isDigit(code[i]) ||
                code[i] == '.' ||
                code[i] == 'e' ||
                code[i] == 'E' ||
                code[i] == '+' ||
                code[i] == '-')) {
          i++;
        }
        final numStr = code.substring(start, i);
        buffer.write('${theme.syntaxNumber}$numStr${Ansi.reset}');
        continue;
      }

      // Keywords: true, false, null
      if (code.startsWith('true', i)) {
        buffer.write('${theme.syntaxKeyword}true${Ansi.reset}');
        i += 4;
        continue;
      }
      if (code.startsWith('false', i)) {
        buffer.write('${theme.syntaxKeyword}false${Ansi.reset}');
        i += 5;
        continue;
      }
      if (code.startsWith('null', i)) {
        buffer.write('${theme.syntaxKeyword}null${Ansi.reset}');
        i += 4;
        continue;
      }

      // Punctuation: { } [ ] : ,
      if (ch == '{' ||
          ch == '}' ||
          ch == '[' ||
          ch == ']' ||
          ch == ':' ||
          ch == ',') {
        buffer.write('${theme.syntaxPunctuation}$ch${Ansi.reset}');
        i++;
        continue;
      }

      buffer.write(ch);
      i++;
    }

    return buffer.toString();
  }

  // --- YAML Highlighting ---
  String _highlightYaml(String code) {
    final lines = code.split('\n');
    final outLines = <String>[];

    for (final line in lines) {
      if (line.trim().startsWith('#')) {
        outLines.add('${theme.syntaxComment}$line${Ansi.reset}');
        continue;
      }

      final colonIdx = line.indexOf(':');
      if (colonIdx != -1) {
        final keyPart = line.substring(0, colonIdx);
        final valPart = line.substring(colonIdx + 1);

        final coloredKey = '${theme.syntaxType}$keyPart${Ansi.reset}';
        final coloredColon = '${theme.syntaxPunctuation}:${Ansi.reset}';

        String coloredVal = valPart;
        final trimmedVal = valPart.trim();
        if (trimmedVal == 'true' ||
            trimmedVal == 'false' ||
            trimmedVal == 'null') {
          coloredVal = valPart.replaceFirst(
            trimmedVal,
            '${theme.syntaxKeyword}$trimmedVal${Ansi.reset}',
          );
        } else if (RegExp(r'^-?\d+(\.\d+)?$').hasMatch(trimmedVal)) {
          coloredVal = valPart.replaceFirst(
            trimmedVal,
            '${theme.syntaxNumber}$trimmedVal${Ansi.reset}',
          );
        } else if (trimmedVal.startsWith('"') || trimmedVal.startsWith("'")) {
          coloredVal = valPart.replaceFirst(
            trimmedVal,
            '${theme.syntaxString}$trimmedVal${Ansi.reset}',
          );
        }

        outLines.add('$coloredKey$coloredColon$coloredVal');
      } else {
        outLines.add(line);
      }
    }

    return outLines.join('\n');
  }

  // --- Generic Tokenizer and Highlighter ---
  String _tokenizeAndHighlight(
    String code, {
    required Set<String> keywords,
    Set<String> types = const {},
    String? lineCommentPrefix,
    String? blockCommentStart,
    String? blockCommentEnd,
  }) {
    final buffer = StringBuffer();
    int i = 0;
    final len = code.length;

    while (i < len) {
      // Line comment
      if (lineCommentPrefix != null && code.startsWith(lineCommentPrefix, i)) {
        int start = i;
        while (i < len && code[i] != '\n') {
          i++;
        }
        final comment = code.substring(start, i);
        buffer.write('${theme.syntaxComment}$comment${Ansi.reset}');
        continue;
      }

      // Block comment
      if (blockCommentStart != null && code.startsWith(blockCommentStart, i)) {
        int start = i;
        i += blockCommentStart.length;
        if (blockCommentEnd != null) {
          final endIdx = code.indexOf(blockCommentEnd, i);
          if (endIdx != -1) {
            i = endIdx + blockCommentEnd.length;
          } else {
            i = len;
          }
        }
        final comment = code.substring(start, i);
        buffer.write('${theme.syntaxComment}$comment${Ansi.reset}');
        continue;
      }

      // Strings (triple quotes first)
      if (code.startsWith('"""', i) || code.startsWith("'''", i)) {
        final quote = code.substring(i, i + 3);
        int start = i;
        i += 3;
        final endIdx = code.indexOf(quote, i);
        if (endIdx != -1) {
          i = endIdx + 3;
        } else {
          i = len;
        }
        final str = code.substring(start, i);
        buffer.write('${theme.syntaxString}$str${Ansi.reset}');
        continue;
      }

      // Single or double quote strings
      final ch = code[i];
      if (ch == '"' || ch == "'" || ch == '`') {
        int start = i;
        final quoteChar = ch;
        i++;
        while (i < len && code[i] != quoteChar) {
          if (code[i] == '\\' && i + 1 < len) i++;
          if (code[i] == '\n' && quoteChar != '`') break; // unterminated line
          i++;
        }
        if (i < len && code[i] == quoteChar) i++;
        final str = code.substring(start, i);
        buffer.write('${theme.syntaxString}$str${Ansi.reset}');
        continue;
      }

      // Numbers
      if (_isDigit(ch) || (ch == '.' && i + 1 < len && _isDigit(code[i + 1]))) {
        int start = i;
        i++;
        while (i < len &&
            (_isAlphaNumeric(code[i]) || code[i] == '.' || code[i] == '_')) {
          i++;
        }
        final numStr = code.substring(start, i);
        buffer.write('${theme.syntaxNumber}$numStr${Ansi.reset}');
        continue;
      }

      // Identifiers / Keywords / Types
      if (_isIdentifierStart(ch)) {
        int start = i;
        i++;
        while (i < len && _isIdentifierPart(code[i])) {
          i++;
        }
        final word = code.substring(start, i);
        if (keywords.contains(word)) {
          buffer.write('${theme.syntaxKeyword}$word${Ansi.reset}');
        } else if (types.contains(word) ||
            (word.length > 1 &&
                word[0].toUpperCase() == word[0] &&
                _isIdentifierPart(word[1]))) {
          buffer.write('${theme.syntaxType}$word${Ansi.reset}');
        } else {
          buffer.write(word);
        }
        continue;
      }

      // Default character
      buffer.write(ch);
      i++;
    }

    return buffer.toString();
  }

  static bool _isDigit(String ch) =>
      ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;

  static bool _isIdentifierStart(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 65 && code <= 90) || // A-Z
        (code >= 97 && code <= 122) || // a-z
        code == 95 || // _
        code == 36; // $
  }

  static bool _isIdentifierPart(String ch) {
    final code = ch.codeUnitAt(0);
    return _isIdentifierStart(ch) || (code >= 48 && code <= 57);
  }

  static bool _isAlphaNumeric(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122);
  }
}
