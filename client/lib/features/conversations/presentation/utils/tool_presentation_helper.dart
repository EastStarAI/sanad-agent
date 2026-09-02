import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';

class ToolPresentationHelper {
  static String getEventTitle(CanonicalEvent event) {
    switch (event.kind) {
      case EventKind.toolCall:
        final cleanTitle = displayToolTitle(event);

        final input = event.toolInput;
        final output = event.toolOutput;

        Map<String, dynamic> mapInput = {};
        if (input is Map) {
          mapInput = Map<String, dynamic>.from(input);
        } else if (input is String) {
          try {
            final decoded = jsonDecode(input);
            if (decoded is Map) mapInput = Map<String, dynamic>.from(decoded);
          } catch (_) {}
        }

        Map<String, dynamic> mapOutput = {};
        if (output is Map) {
          mapOutput = Map<String, dynamic>.from(output);
        } else if (output is String) {
          try {
            final decoded = jsonDecode(output);
            if (decoded is Map) mapOutput = Map<String, dynamic>.from(decoded);
          } catch (_) {}
        }

        String details = '';
        if (cleanTitle == 'Read') {
          final path = mapInput['path'] ?? mapOutput['filePath'] ?? mapOutput['path'];
          String fileName = '';
          if (path != null) {
            fileName = path.toString().split(RegExp(r'[\\/]')).last;
          }
          details = fileName;

          int? startLine;
          int? endLine;
          final offsetVal = mapInput['offset'];
          final limitVal = mapInput['limit'];
          if (offsetVal is num) {
            startLine = offsetVal.toInt() + 1;
            if (limitVal is num) {
              endLine = startLine + limitVal.toInt() - 1;
            }
          }

          if (startLine != null) {
            details += endLine != null ? '#L$startLine-$endLine' : '#L$startLine';
          }
        } else if (cleanTitle == 'Write') {
          final path = mapInput['path'] ?? mapOutput['filePath'] ?? mapOutput['path'];
          String fileName = '';
          if (path != null) {
            fileName = path.toString().split(RegExp(r'[\\/]')).last;
          }
          details = fileName;

          final content = mapInput['content']?.toString();
          if (content != null) {
            final lineCount = '\n'.allMatches(content).length + 1;
            details += ' +$lineCount';
          }
        } else if (cleanTitle == 'Edit') {
          final path = mapInput['path'] ?? mapOutput['filePath'] ?? mapOutput['path'];
          String fileName = '';
          if (path != null) {
            fileName = path.toString().split(RegExp(r'[\\/]')).last;
          }
          details = fileName;

          final patch = mapOutput['patch']?.toString();
          final oldString = mapInput['old_string']?.toString();
          final newString = mapInput['new_string']?.toString();

          int addedCount = 0;
          int deletedCount = 0;

          if (oldString != null || newString != null) {
            if (oldString != null) {
              deletedCount = '\n'.allMatches(oldString).length + 1;
            }
            if (newString != null) {
              addedCount = '\n'.allMatches(newString).length + 1;
            }
          } else if (patch != null && patch.trim().isNotEmpty) {
            if (patch.startsWith('-') && patch.contains('\n+')) {
              final parts = patch.split('\n+');
              if (parts.length >= 2) {
                deletedCount = '\n'.allMatches(parts[0]).length + 1;
                addedCount = '\n'.allMatches(parts[1]).length + 1;
              }
            } else {
              final lines = const LineSplitter().convert(patch);
              for (final line in lines) {
                if (line.startsWith('+') && !line.startsWith('+++')) {
                  addedCount++;
                } else if (line.startsWith('-') && !line.startsWith('---')) {
                  deletedCount++;
                }
              }
            }
          }

          if (addedCount > 0) details += ' +$addedCount';
          if (deletedCount > 0) details += ' -$deletedCount';
        } else {
          details = getToolDetailSuffix(event);
        }

        if (details.isNotEmpty) {
          return '$cleanTitle: $details';
        }
        return cleanTitle;
      case EventKind.plan:
        return event.text.isNotEmpty ? event.text : 'Execution Plan';
      case EventKind.error:
        return 'Error';
      case EventKind.reasoning:
        return 'Reasoning';
      case EventKind.thinking:
        return event.text.isNotEmpty ? 'Thoughts' : 'Thinking...';
      default:
        return '';
    }
  }

  static Widget buildTitleWidget({
    required BuildContext context,
    required CanonicalEvent event,
    required Color titleColor,
    TextDirection? textDirection,
  }) {
    final title = getEventTitle(event);
    final resolvedDirection = textDirection ?? TextUtils.getTextDirection(title);

    if (event.kind != EventKind.toolCall) {
      return Text(
        title,
        textDirection: resolvedDirection,
        textAlign: resolvedDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
        style: GoogleFonts.outfit(
          color: titleColor,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
        overflow: TextOverflow.ellipsis,
      );
    }

    final rawName = event.toolName ?? 'Using Tool';
    final cleanTitle = cleanToolTitle(rawName);
    final displayTitle = displayToolTitle(event);

    // Parse input and output
    final input = event.toolInput;
    final output = event.toolOutput;

    Map<String, dynamic> mapInput = {};
    if (input is Map) {
      mapInput = Map<String, dynamic>.from(input);
    } else if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) mapInput = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }

    Map<String, dynamic> mapOutput = {};
    if (output is Map) {
      mapOutput = Map<String, dynamic>.from(output);
    } else if (output is String) {
      try {
        final decoded = jsonDecode(output);
        if (decoded is Map) mapOutput = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }

    final listSpans = <InlineSpan>[];

    // Category prefix (e.g. "Read: " or "Write: ")
    listSpans.add(
      TextSpan(
        text: '$displayTitle: ',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          fontWeight: FontWeight.w500,
        ),
      ),
    );

    // Custom formatting for Read, Write, Edit
    if (cleanTitle == 'Read') {
      final path = mapInput['path'] ?? mapOutput['filePath'] ?? mapOutput['path'];
      String fileName = '';
      if (path != null) {
        fileName = path.toString().split(RegExp(r'[\\/]')).last;
      }

      listSpans.add(
        TextSpan(
          text: fileName,
          style: TextStyle(
            color: titleColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

      // Extract offset and limit to show line range
      int? startLine;
      int? endLine;
      final offsetVal = mapInput['offset'];
      final limitVal = mapInput['limit'];
      if (offsetVal is num) {
        startLine = offsetVal.toInt() + 1;
        if (limitVal is num) {
          endLine = startLine + limitVal.toInt() - 1;
        }
      }

      if (startLine != null) {
        final lineRangeStr = endLine != null ? '#L$startLine-$endLine' : '#L$startLine';
        listSpans.add(
          TextSpan(
            text: lineRangeStr,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      }
    } else if (cleanTitle == 'Write') {
      final path = mapInput['path'] ?? mapOutput['filePath'] ?? mapOutput['path'];
      String fileName = '';
      if (path != null) {
        fileName = path.toString().split(RegExp(r'[\\/]')).last;
      }

      listSpans.add(
        TextSpan(
          text: fileName,
          style: TextStyle(
            color: titleColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

      final content = mapInput['content']?.toString();
      if (content != null) {
        final lineCount = '\n'.allMatches(content).length + 1;
        listSpans.add(
          TextSpan(
            text: ' +$lineCount',
            style: const TextStyle(
              color: Colors.green,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
    } else if (cleanTitle == 'Edit') {
      final path = mapInput['path'] ?? mapOutput['filePath'] ?? mapOutput['path'];
      String fileName = '';
      if (path != null) {
        fileName = path.toString().split(RegExp(r'[\\/]')).last;
      }

      listSpans.add(
        TextSpan(
          text: fileName,
          style: TextStyle(
            color: titleColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

      final patch = mapOutput['patch']?.toString();
      final oldString = mapInput['old_string']?.toString();
      final newString = mapInput['new_string']?.toString();

      int addedCount = 0;
      int deletedCount = 0;

      if (patch != null && patch.trim().isNotEmpty) {
        final lines = const LineSplitter().convert(patch);
        for (final line in lines) {
          if (line.startsWith('+') && !line.startsWith('+++')) {
            addedCount++;
          } else if (line.startsWith('-') && !line.startsWith('---')) {
            deletedCount++;
          }
        }
      } else if (oldString != null || newString != null) {
        if (oldString != null) {
          deletedCount = '\n'.allMatches(oldString).length + 1;
        }
        if (newString != null) {
          addedCount = '\n'.allMatches(newString).length + 1;
        }
      }

      if (addedCount > 0) {
        listSpans.add(
          TextSpan(
            text: ' +$addedCount',
            style: const TextStyle(
              color: Colors.green,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
      if (deletedCount > 0) {
        listSpans.add(
          TextSpan(
            text: ' -$deletedCount',
            style: const TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      }
    } else if (cleanTitle == 'Search' || cleanTitle == 'Grep') {
      final pattern = mapInput['pattern'] ?? '';
      final searchPath = mapInput['path'] ?? '';
      final relPath = searchPath.toString().isNotEmpty ? _toRelativePath(context, searchPath.toString()) : '';

      listSpans.add(
        TextSpan(
          text: cleanTitle == 'Grep' ? '"$pattern"' : pattern.toString(),
          style: TextStyle(
            color: titleColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

      if (relPath.isNotEmpty) {
        listSpans.add(
          TextSpan(
            text: ' in ',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
              fontWeight: FontWeight.w500,
            ),
          ),
        );
        listSpans.add(
          TextSpan(
            text: relPath,
            style: TextStyle(
              color: titleColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
    } else {
      // Fallback details for other tools
      final details = getToolDetailSuffix(event);
      if (details.isNotEmpty) {
        listSpans.add(
          TextSpan(
            text: details,
            style: TextStyle(
              color: titleColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
    }

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textDirection: resolvedDirection,
      text: TextSpan(
        style: GoogleFonts.outfit(
          fontSize: 13,
          letterSpacing: 0.5,
        ),
        children: listSpans,
      ),
    );
  }

  static String _toRelativePath(BuildContext context, String filePath) {
    try {
      final messagesCubit = context.read<SessionMessagesCubit>();
      final workspacePath = messagesCubit.state.selectedWorkspace?.path;
      if (workspacePath != null && workspacePath.isNotEmpty) {
        if (filePath.startsWith(workspacePath)) {
          String relative = filePath.substring(workspacePath.length);
          if (relative.startsWith('/') || relative.startsWith('\\')) {
            relative = relative.substring(1);
          }
          return relative.isEmpty ? '.' : relative;
        }
      }
    } catch (_) {}
    return filePath;
  }

  static String getToolDetailSuffix(CanonicalEvent event) {
    final input = event.toolInput;
    final output = event.toolOutput;
    final rawName = event.toolName ?? '';

    Map<String, dynamic> mapInput = {};
    if (input is Map) {
      mapInput = Map<String, dynamic>.from(input);
    } else if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) mapInput = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }

    Map<String, dynamic> mapOutput = {};
    if (output is Map) {
      mapOutput = Map<String, dynamic>.from(output);
    } else if (output is String) {
      try {
        final decoded = jsonDecode(output);
        if (decoded is Map) mapOutput = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }

    final cleanName = rawName.startsWith('mcp__filesystem__') ? rawName.replaceFirst('mcp__filesystem__', '') : rawName;

    // 1. Check path (for read, write, edit, replace, patch) - return basename only
    if (cleanName.contains('file') || cleanName == 'patch' || cleanName.contains('content')) {
      final path = mapInput['path'] ?? mapOutput['filePath'] ?? mapOutput['path'];
      if (path != null) {
        return path.toString().split(RegExp(r'[\\/]')).last;
      }

      // Try nested file object (e.g. file: { filePath: ... }) in output
      final fileObj = mapOutput['file'];
      if (fileObj is Map) {
        final fPath = fileObj['filePath'] ?? fileObj['path'];
        if (fPath != null) {
          return fPath.toString().split(RegExp(r'[\\/]')).last;
        }
      }
    }

    // 2. Check pattern (for search_glob, search_files)
    if (cleanName.contains('search') && !cleanName.contains('web')) {
      final pattern = mapInput['pattern'];
      final searchPath = mapInput['path'] ?? '';
      if (pattern != null) {
        if (searchPath.toString().isNotEmpty) {
          final folder = searchPath.toString().split(RegExp(r'[\\/]')).last;
          return '$pattern in $folder';
        }
        return pattern.toString();
      }
    }

    // 3. Check pattern (for search_grep, grep_search)
    if (cleanName.contains('grep')) {
      final pattern = mapInput['pattern'];
      final searchPath = mapInput['path'] ?? '';
      if (pattern != null) {
        if (searchPath.toString().isNotEmpty) {
          final folder = searchPath.toString().split(RegExp(r'[\\/]')).last;
          return '"$pattern" in $folder';
        }
        return '"$pattern"';
      }
    }

    // 4. Check command (for shell_execute, run_command)
    if (cleanName.contains('shell') ||
        cleanName.contains('command') ||
        cleanName.contains('execute') ||
        cleanName == 'ran') {
      final cmd = mapInput['command'];
      if (cmd != null) {
        return cmd.toString().trim().replaceAll('\n', ' ');
      }
    }

    // 5. Check query (for web_search, search_web)
    if (cleanName.contains('web') && cleanName.contains('search')) {
      final query = mapInput['query'];
      if (query != null) return '"$query"';
    }

    // 6. Check URL (for web_fetch, read_url)
    if (cleanName.contains('web') && cleanName.contains('fetch') || cleanName.contains('url')) {
      final url = mapInput['urls'] ?? mapInput['url'];
      if (url is List && url.isNotEmpty) return url.first.toString();
      if (url != null) return url.toString();
    }

    // 7. Check question (for system_ask_user)
    if (cleanName.contains('ask_user')) {
      final q = mapInput['questions'] ?? mapInput['question'];
      if (q is List && q.isNotEmpty && q.first is Map) {
        final firstQ = q.first['question'];
        if (firstQ != null) return firstQ.toString();
      }
      if (q != null) {
        final qStr = q.toString();
        return qStr.length > 30 ? '${qStr.substring(0, 27)}...' : qStr;
      }
    }

    // 8. Check memory
    if (cleanName == 'memory') {
      final action = mapInput['action']?.toString();
      final target = mapInput['target']?.toString();
      if (action != null) {
        return target != null ? '$action ($target)' : action;
      }
    }

    // 9. Check skill_load
    if (cleanName == 'skill_load' || cleanName.contains('skill')) {
      final skill = mapInput['skill']?.toString();
      if (skill != null) return skill;
    }

    return '';
  }

  static String displayToolTitle(CanonicalEvent event) {
    final cleanTitle = cleanToolTitle(event.toolName ?? 'Using Tool');
    if (event.status == EventStatus.cancelled) {
      return 'Cancelled';
    }
    if (cleanTitle == 'Ran' && event.status == EventStatus.running) {
      return 'Running';
    }
    return cleanTitle;
  }

  static String cleanToolTitle(String rawName) {
    // 1. Remove MCP prefixes
    String name = rawName;
    if (name.startsWith('mcp__filesystem__')) {
      name = name.replaceFirst('mcp__filesystem__', '');
    } else if (name.startsWith('mcp__clickup__')) {
      name = name.replaceFirst('mcp__clickup__', 'ClickUp: ');
    } else if (name.startsWith('mcp__')) {
      final parts = name.split('__');
      if (parts.length >= 3) {
        final server = parts[1];
        final tool = parts.sublist(2).join('_');
        final serverCap = server[0].toUpperCase() + server.substring(1);
        return '$serverCap: ${formatToolWord(tool)}';
      }
    }

    // 2. Format names nicely
    if (name == 'file_read') return 'Read';
    if (name == 'file_write') return 'Write';
    if (name == 'file_edit') return 'Edit';
    if (name == 'search_glob') return 'Search';
    if (name == 'search_grep') return 'Grep';
    if (name == 'shell_execute') return 'Ran';
    if (name == 'web_search') return 'Search Web';
    if (name == 'web_fetch') return 'Fetch';
    if (name == 'system_ask_user') return 'Ask';
    if (name == 'tool_search') return 'Search Capabilities';
    if (name == 'skill_load') return 'Skill Load';
    if (name == 'memory') return 'Memory';

    return formatToolWord(name);
  }

  static String formatToolWord(String raw) {
    final words = raw.replaceAll(RegExp(r'[._-]'), ' ').split(' ');
    return words
        .map((w) {
          if (w.isEmpty) return '';
          return w[0].toUpperCase() + w.substring(1);
        })
        .join(' ');
  }

  static (IconData, Color) getEventIconData(BuildContext context, CanonicalEvent event) {
    if (event.status == EventStatus.cancelled) {
      return (Icons.cancel_outlined, Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6));
    }
    if (event.status == EventStatus.error) {
      return (Icons.error_outline, Theme.of(context).colorScheme.error);
    }
    return switch (event.kind) {
      EventKind.toolCall => getToolIconData(context, event.toolName ?? ''),
      EventKind.plan => (Icons.playlist_add_check_rounded, Colors.grey),
      EventKind.error => (Icons.error_outline, Theme.of(context).colorScheme.error),
      EventKind.reasoning => (Icons.psychology_outlined, Colors.grey),
      EventKind.thinking => (Icons.lightbulb_outline, Colors.grey),
      _ => (Icons.info_outline, Colors.grey),
    };
  }

  static (IconData, Color) getToolIconData(BuildContext context, String toolName) {
    final cleanName = toolName.startsWith('mcp__filesystem__')
        ? toolName.replaceFirst('mcp__filesystem__', '')
        : toolName;

    // 1. Web / Fetch
    if (cleanName.contains('web') || cleanName.contains('fetch') || cleanName.contains('read_url')) {
      return (Icons.language_outlined, Colors.grey);
    }

    // 2. File / Content
    if (cleanName.contains('file') ||
        cleanName.contains('read') ||
        cleanName.contains('write') ||
        cleanName.contains('edit') ||
        cleanName.contains('patch') ||
        cleanName.contains('content')) {
      return (Icons.insert_drive_file_outlined, Colors.grey);
    }

    // 3. Search / Grep / Glob
    if (cleanName.contains('search') || cleanName.contains('grep') || cleanName.contains('glob')) {
      return (Icons.search_rounded, Colors.grey);
    }

    // 4. Command / Shell
    if (cleanName.contains('shell') ||
        cleanName.contains('command') ||
        cleanName.contains('execute') ||
        cleanName == 'ran') {
      return (Icons.terminal_outlined, Colors.grey);
    }

    // 5. Ask user
    if (cleanName.contains('ask_user')) {
      return (Icons.help_outline_rounded, Colors.grey);
    }

    // 6. Memory
    if (cleanName.contains('memory')) {
      return (Icons.psychology_outlined, Colors.grey);
    }

    // 7. Skill Load
    if (cleanName.contains('skill')) {
      return (Icons.auto_awesome_outlined, Colors.grey);
    }

    return (Icons.construction_outlined, Colors.grey);
  }
}
