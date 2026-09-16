import 'dart:convert';

/// Utilities for formatting tool presentations, permission cards, running indicators,
/// and execution results in the Sanad CLI terminal interface to match the Flutter Desktop Client.
class CliToolFormatter {
  /// Returns a clean action name removing any MCP prefixes.
  static String cleanToolName(String rawName) {
    if (rawName.isEmpty) return 'tool';
    if (rawName.startsWith('mcp__filesystem__')) {
      return rawName.replaceFirst('mcp__filesystem__', '');
    }
    if (rawName.startsWith('mcp__')) {
      final parts = rawName.split('__');
      if (parts.length >= 3) {
        return '${parts[1]} / ${parts.sublist(2).join('__')}';
      }
    }
    return rawName;
  }

  /// Generates a human-friendly action-aware title matching Flutter client.
  static String formatPermissionTitle(
    String toolName, {
    Map<String, dynamic>? toolInput,
  }) {
    final clean = cleanToolName(toolName);
    final action = toolInput?['action']?.toString().trim();
    final effectiveAction = (action != null && action.isNotEmpty)
        ? action
        : clean;

    if (toolName.startsWith('mcp__') || effectiveAction.startsWith('mcp__')) {
      return 'Allow Sanad to use this MCP tool?';
    }

    switch (effectiveAction) {
      case 'shell_execute':
        return 'Allow Sanad to run this command?';
      case 'file_read':
        return 'Allow Sanad to read this file?';
      case 'file_write':
        return 'Allow Sanad to write to this file?';
      case 'file_edit':
        return 'Allow Sanad to edit this file?';
      case 'search_glob':
        return 'Allow Sanad to search for matching files?';
      case 'search_grep':
        return 'Allow Sanad to search these files?';
      default:
        return 'Allow Sanad to use this tool?';
    }
  }

  /// Extracts formatted detail entries matching Flutter client presentation.
  static List<MapEntry<String?, String>> formatPermissionDetails({
    required String toolName,
    required Map<String, dynamic> toolInput,
    String? workspaceName,
    String? workspacePath,
  }) {
    final details = <MapEntry<String?, String>>[];
    final clean = cleanToolName(toolName);
    final action = (toolInput['action']?.toString().trim() ?? '').isNotEmpty
        ? toolInput['action'].toString().trim()
        : clean;

    if (action.startsWith('mcp__')) {
      final parts = action.split('__');
      final server = parts.length >= 3 ? parts[1] : 'mcp';
      final name = parts.length >= 3 ? parts.sublist(2).join('__') : action;
      details.add(MapEntry(null, '$server / $name'));
      _addRemainingInputs(details, toolInput, excluded: {'action'});
      return details;
    }

    if (action == 'shell_execute') {
      final cmd = toolInput['command']?.toString().trim();
      if (cmd != null && cmd.isNotEmpty) {
        details.add(MapEntry('Command', cmd));
      }
      final cwd = toolInput['cwd']?.toString().trim() ?? workspacePath;
      if (cwd != null && cwd.isNotEmpty) {
        details.add(MapEntry('Directory', cwd));
      }
      if (workspaceName != null && workspaceName.isNotEmpty) {
        details.add(MapEntry('Workspace', workspaceName));
      }
      _addRemainingInputs(
        details,
        toolInput,
        excluded: {'action', 'command', 'cwd'},
      );
    } else if (action == 'file_read' ||
        action == 'file_write' ||
        action == 'file_edit') {
      final path =
          toolInput['path']?.toString() ?? toolInput['file']?.toString();
      if (path != null && path.isNotEmpty) {
        final rel = _toRelativePath(path, workspacePath);
        details.add(MapEntry('File', rel));
      }
      if (action == 'file_read') {
        final offset = toolInput['offset'];
        final limit = toolInput['limit'];
        if (offset is num) {
          final start = offset.toInt() + 1;
          final end = limit is num ? start + limit.toInt() - 1 : null;
          details.add(
            MapEntry('Lines', end != null ? '#L$start-$end' : '#L$start'),
          );
        }
      } else if (action == 'file_write') {
        final content = toolInput['content']?.toString();
        if (content != null) {
          final lines = '\n'.allMatches(content).length + 1;
          details.add(MapEntry('Content', '+$lines lines'));
        }
      } else if (action == 'file_edit') {
        final patch = toolInput['patch']?.toString();
        final oldStr = toolInput['old_string']?.toString();
        final newStr = toolInput['new_string']?.toString();
        if (oldStr != null || newStr != null) {
          final del = oldStr != null ? '\n'.allMatches(oldStr).length + 1 : 0;
          final add = newStr != null ? '\n'.allMatches(newStr).length + 1 : 0;
          details.add(MapEntry('Changes', '+$add -$del lines'));
        } else if (patch != null && patch.isNotEmpty) {
          details.add(
            MapEntry(
              'Patch',
              patch.length > 80 ? '${patch.substring(0, 80)}...' : patch,
            ),
          );
        }
      }
      if (workspaceName != null && workspaceName.isNotEmpty) {
        details.add(MapEntry('Workspace', workspaceName));
      }
      _addRemainingInputs(
        details,
        toolInput,
        excluded: {
          'action',
          'path',
          'file',
          'content',
          'patch',
          'old_string',
          'new_string',
          'offset',
          'limit',
        },
      );
    } else if (action == 'search_glob' || action == 'search_grep') {
      final pattern = toolInput['pattern']?.toString();
      if (pattern != null && pattern.isNotEmpty) {
        details.add(MapEntry('Pattern', pattern));
      }
      final path = toolInput['path']?.toString() ?? workspacePath;
      if (path != null && path.isNotEmpty) {
        details.add(
          MapEntry('Search Path', _toRelativePath(path, workspacePath)),
        );
      }
      if (workspaceName != null && workspaceName.isNotEmpty) {
        details.add(MapEntry('Workspace', workspaceName));
      }
      _addRemainingInputs(
        details,
        toolInput,
        excluded: {'action', 'pattern', 'path'},
      );
    } else {
      details.add(MapEntry('Tool', clean));
      if (workspaceName != null && workspaceName.isNotEmpty) {
        details.add(MapEntry('Workspace', workspaceName));
      }
      _addRemainingInputs(details, toolInput, excluded: {'action'});
    }

    return details;
  }

  /// Formats the in-flight calling indicator.
  static String formatToolCalling(
    String toolName,
    Map<String, dynamic> arguments, {
    String? workspacePath,
    bool ansi = false,
  }) {
    final clean = cleanToolName(toolName);
    final cyan = ansi ? '\x1b[36m' : '';
    final bold = ansi ? '\x1b[1m' : '';
    final reset = ansi ? '\x1b[0m' : '';

    if (clean == 'shell_execute') {
      final cmd = arguments['command']?.toString().trim() ?? '';
      return '$cyan🔧 Running command:$reset $bold$cmd$reset';
    } else if (clean == 'file_read') {
      final path = _toRelativePath(
        arguments['path']?.toString() ?? '',
        workspacePath,
      );
      return '$cyan🔧 Reading file:$reset $bold$path$reset';
    } else if (clean == 'file_write') {
      final path = _toRelativePath(
        arguments['path']?.toString() ?? '',
        workspacePath,
      );
      return '$cyan🔧 Writing file:$reset $bold$path$reset';
    } else if (clean == 'file_edit') {
      final path = _toRelativePath(
        arguments['path']?.toString() ?? '',
        workspacePath,
      );
      return '$cyan🔧 Editing file:$reset $bold$path$reset';
    } else if (clean == 'search_glob') {
      final pat = arguments['pattern']?.toString() ?? '';
      return '$cyan🔧 Searching files (glob):$reset $bold$pat$reset';
    } else if (clean == 'search_grep') {
      final pat = arguments['pattern']?.toString() ?? '';
      return '$cyan🔧 Grep searching files:$reset $bold"$pat"$reset';
    } else if (clean == 'web_search' || clean == 'search_web') {
      final q =
          arguments['query']?.toString() ??
          arguments['q']?.toString() ??
          arguments['search']?.toString() ??
          '';
      return '$cyan🌐 Web Search:$reset $bold"$q"$reset';
    } else if (clean == 'web_fetch' ||
        clean == 'fetch_web' ||
        clean == 'fetch' ||
        clean == 'fetch_web_page') {
      final urlsRaw =
          arguments['urls'] ??
          arguments['url'] ??
          arguments['link'] ??
          arguments['uri'];
      String url = '';
      if (urlsRaw is List && urlsRaw.isNotEmpty) {
        url = urlsRaw.first.toString();
      } else if (urlsRaw != null) {
        url = urlsRaw.toString();
      }
      return '$cyan🌐 Web Fetch:$reset $bold$url$reset';
    } else {
      return '$cyan🔧 Calling tool: $bold$clean$reset';
    }
  }

  /// Formats the tool result execution block.
  static String formatToolResult({
    required String toolName,
    required dynamic result,
    required bool isError,
    Map<String, dynamic>? arguments,
    Duration? duration,
    bool ansi = false,
    int maxLines = 25,
  }) {
    final clean = cleanToolName(toolName);
    final green = ansi ? '\x1b[32m' : '';
    final red = ansi ? '\x1b[31m' : '';
    final dim = ansi ? '\x1b[90m' : '';
    final bold = ansi ? '\x1b[1m' : '';
    final reset = ansi ? '\x1b[0m' : '';

    final statusText = isError ? 'failed ❌' : 'completed ✓';
    final statusColor = isError ? red : green;
    final durStr = duration != null
        ? ' (${(duration.inMilliseconds / 1000).toStringAsFixed(2)}s)'
        : '';

    /*
    // --- TEMPORARILY COMMENTED OUT: Full tool result box output ---
    final buffer = StringBuffer();
    final parsedOutput = _extractOutputText(result);
    final content = parsedOutput.text.trim();
    final stderrText = parsedOutput.stderr.trim();

    buffer.writeln('$dim┌── [$clean] ──────────────────────────────────────────$reset');

    if (clean == 'shell_execute') {
      final cmd = arguments?['command']?.toString().trim() ?? '';
      if (cmd.isNotEmpty) {
        buffer.writeln('$dim│$reset $green' r'$' ' $bold$cmd$reset');
      }
    }

    if (content.isNotEmpty) {
      final lines = content.split('\n');
      final displayLines = lines.take(maxLines).toList();
      for (final line in displayLines) {
        buffer.writeln('$dim│$reset $line');
      }
      if (lines.length > maxLines) {
        buffer.writeln('$dim│ ... (${lines.length - maxLines} more lines truncated)$reset');
      }
    } else if (!isError && stderrText.isEmpty) {
      buffer.writeln('$dim│$reset $dim(completed)$reset');
    }

    if (stderrText.isNotEmpty) {
      buffer.writeln('$dim│$reset $red[STDERR]:$reset');
      for (final line in stderrText.split('\n')) {
        buffer.writeln('$dim│$reset $red$line$reset');
      }
    }

    buffer.writeln('$dim└──$reset $statusColor[$clean $statusText$durStr]$reset');
    return buffer.toString().trimRight();
    // -------------------------------------------------------------
    */

    // Compact title-only presentation mode:
    String detail = '';
    if (clean == 'web_fetch' ||
        clean == 'fetch_web' ||
        clean == 'fetch' ||
        clean == 'fetch_web_page') {
      final urlsRaw =
          arguments?['urls'] ??
          arguments?['url'] ??
          arguments?['link'] ??
          arguments?['uri'];
      String url = '';
      if (urlsRaw is List && urlsRaw.isNotEmpty) {
        url = urlsRaw.first.toString();
      } else if (urlsRaw != null) {
        url = urlsRaw.toString();
      }
      if (url.isEmpty) {
        final parsed = _extractOutputText(result);
        final match = RegExp(r'https?://[^\s",\]]+').firstMatch(parsed.text);
        if (match != null) {
          url = match.group(0) ?? '';
        }
      }
      if (url.isNotEmpty) detail = ' $url';
    } else if (clean == 'web_search' || clean == 'search_web') {
      final q =
          arguments?['query'] ?? arguments?['q'] ?? arguments?['search'] ?? '';
      if (q.toString().isNotEmpty) detail = ' "$q"';
    } else if (clean == 'shell_execute') {
      final cmd = arguments?['command']?.toString().trim() ?? '';
      if (cmd.isNotEmpty) detail = ' $cmd';
    } else if (clean == 'file_read' ||
        clean == 'file_write' ||
        clean == 'file_edit') {
      final path = arguments?['path']?.toString() ?? '';
      if (path.isNotEmpty) detail = ' $path';
    }

    final parsedOutput = _extractOutputText(result);
    if (isError && detail.isEmpty && parsedOutput.stderr.isNotEmpty) {
      detail = ' (${parsedOutput.stderr.trim().split('\n').first})';
    }

    return '  $dim[$reset$statusColor$bold$clean$reset$detail $statusColor$statusText$durStr$reset$dim]$reset';
  }

  static void _addRemainingInputs(
    List<MapEntry<String?, String>> details,
    Map<String, dynamic> inputs, {
    required Set<String> excluded,
  }) {
    for (final entry in inputs.entries) {
      if (excluded.contains(entry.key)) continue;
      final val = entry.value;
      if (val == null) continue;
      final formatted = _formatValue(val);
      if (formatted.isNotEmpty) {
        details.add(MapEntry(_humanize(entry.key), formatted));
      }
    }
  }

  static String _humanize(String key) {
    final words = key
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (m) => '${m[1]} ${m[2]}',
        )
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
    if (words.isEmpty) return 'Value';
    return '${words[0].toUpperCase()}${words.substring(1)}';
  }

  static String _formatValue(Object? value) {
    if (value == null) return '';
    if (value is Map) {
      if (value.isEmpty) return '';
      return value.entries
          .map(
            (e) => '${_humanize(e.key.toString())}: ${_formatValue(e.value)}',
          )
          .join(', ');
    }
    if (value is Iterable) {
      if (value.isEmpty) return '';
      return value.map(_formatValue).join(', ');
    }
    return value.toString();
  }

  static String _toRelativePath(String path, String? workspacePath) {
    if (workspacePath != null &&
        workspacePath.isNotEmpty &&
        path.startsWith(workspacePath)) {
      String relative = path.substring(workspacePath.length);
      if (relative.startsWith('/') || relative.startsWith('\\')) {
        relative = relative.substring(1);
      }
      return relative.isEmpty ? '.' : relative;
    }
    return path;
  }

  static ({String text, String stderr}) _extractOutputText(dynamic output) {
    if (output == null) return (text: '', stderr: '');
    if (output is Map) {
      return _extractFromMap(output);
    }
    if (output is List) {
      return (text: _formatListOutput(output), stderr: '');
    }
    if (output is String) {
      final trimmed = output.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            return _extractFromMap(decoded);
          } else if (decoded is List) {
            return (text: _formatListOutput(decoded), stderr: '');
          }
        } catch (_) {}
      }
      return (text: output, stderr: '');
    }
    return (text: output.toString(), stderr: '');
  }

  static ({String text, String stderr}) _extractFromMap(Map map) {
    final err = map['stderr']?.toString() ?? (map['error']?.toString() ?? '');
    if (map.containsKey('output') && map['output'] != null) {
      return (text: _formatOutputValue(map['output']), stderr: err);
    }
    if (map.containsKey('stdout') && map['stdout'] != null) {
      return (text: _formatOutputValue(map['stdout']), stderr: err);
    }
    if (map.containsKey('result') && map['result'] != null) {
      return (text: _formatOutputValue(map['result']), stderr: err);
    }
    if (map.containsKey('results') && map['results'] != null) {
      return (text: _formatOutputValue(map['results']), stderr: err);
    }
    if (map.containsKey('content') && map['content'] != null) {
      return (text: _formatOutputValue(map['content']), stderr: err);
    }
    if (map.containsKey('items') && map['items'] != null) {
      return (text: _formatOutputValue(map['items']), stderr: err);
    }
    try {
      final formatted = const JsonEncoder.withIndent('  ').convert(map);
      return (text: formatted, stderr: err);
    } catch (_) {
      return (text: map.toString(), stderr: err);
    }
  }

  static String _formatOutputValue(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is List) return _formatListOutput(value);
    if (value is Map) {
      try {
        return const JsonEncoder.withIndent('  ').convert(value);
      } catch (_) {
        return value.toString();
      }
    }
    return value.toString();
  }

  static String _formatListOutput(List list) {
    if (list.isEmpty) return '';
    final buffer = StringBuffer();
    for (final item in list) {
      if (item is Map) {
        if (item['type'] == 'text' && item.containsKey('text')) {
          buffer.writeln(item['text']);
        } else if (item.containsKey('result')) {
          final code = item['code'];
          final codeText = item['codeText'] ?? '';
          final res = item['result']?.toString() ?? '';
          if (code != null) {
            buffer.writeln('[$code $codeText] $res');
          } else {
            buffer.writeln(res);
          }
        } else if (item.containsKey('title') || item.containsKey('url')) {
          final title = item['title'] ?? '';
          final url = item['url'] ?? '';
          final snippet = item['snippet'] ?? item['description'] ?? '';
          buffer.writeln('• $title ($url)');
          if (snippet.toString().isNotEmpty) {
            buffer.writeln('  $snippet');
          }
        } else {
          try {
            buffer.writeln(const JsonEncoder.withIndent('  ').convert(item));
          } catch (_) {
            buffer.writeln(item.toString());
          }
        }
      } else {
        buffer.writeln(item.toString());
      }
    }
    return buffer.toString().trim();
  }
}
