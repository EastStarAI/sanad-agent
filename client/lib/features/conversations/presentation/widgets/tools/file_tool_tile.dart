import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/app_markdown_renderer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/code_highlighting.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/diff/diff_block_view.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/diff/unified_diff_parser.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/link_utils.dart';

class FileToolTile extends StatefulWidget {
  final CanonicalEvent event;
  final bool isFullyExpanded;

  const FileToolTile({
    super.key,
    required this.event,
    this.isFullyExpanded = true,
  });

  @override
  State<FileToolTile> createState() => _FileToolTileState();
}

class _FileToolTileState extends State<FileToolTile> {
  static const double _readViewportHeight = 350;

  CanonicalEvent get event => widget.event;

  // Cached syntax highlighting results
  bool? _lastIsDark;
  final CodeHighlightCache _highlightCache = CodeHighlightCache();
  bool _showMarkdown = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_lastIsDark != isDark) {
      _lastIsDark = isDark;
      _clearCache();
    }
  }

  @override
  void didUpdateWidget(covariant FileToolTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.event.id != oldWidget.event.id) {
      _showMarkdown = true;
    }
    if (widget.event.id != oldWidget.event.id ||
        widget.event.toolOutput != oldWidget.event.toolOutput ||
        widget.isFullyExpanded != oldWidget.isFullyExpanded) {
      _clearCache();
    }
  }

  void _clearCache() {
    _highlightCache.clear();
  }

  @override
  Widget build(BuildContext context) {
    if (event.status == EventStatus.running) {
      return _buildRunningIndicator(context);
    }

    if (event.status == EventStatus.error) {
      return _buildErrorState(context);
    }

    final toolName = event.toolName ?? '';
    final input = event.toolInput;
    final output = event.toolOutput;

    // Normalize tool names (remove MCP prefixes if present)
    final cleanName = _getCleanToolName(toolName);

    // Try parsing the output if it's a JSON string
    Map<String, dynamic>? parsedOutput;
    if (output is String) {
      try {
        final decoded = jsonDecode(output);
        if (decoded is Map<String, dynamic>) {
          parsedOutput = decoded;
        }
      } catch (_) {
        // Not a JSON map string, keep parsedOutput null
      }
    } else if (output is Map<String, dynamic>) {
      parsedOutput = output;
    }

    if (cleanName == 'file_read') {
      return _buildFileRead(context, input, parsedOutput, output);
    } else if (cleanName == 'file_write') {
      return _buildFileWrite(context, input, parsedOutput, output);
    } else if (cleanName == 'file_edit') {
      return _buildFileEdit(context, input, parsedOutput, output);
    } else if (cleanName == 'search_glob') {
      return _buildSearchGlob(context, input, parsedOutput, output);
    } else if (cleanName == 'search_grep') {
      return _buildSearchGrep(context, input, parsedOutput, output);
    }

    // Fallback if none of the specific layouts matched
    return _buildFallback(context, input, output);
  }

  String _getCleanToolName(String name) {
    if (name.startsWith('mcp__filesystem__')) {
      return name.replaceFirst('mcp__filesystem__', '');
    }
    return name;
  }

  String _toRelativePath(BuildContext context, String filePath) {
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

  Widget _buildRunningIndicator(BuildContext context) {
    final toolName = event.toolName ?? '';
    final cleanName = _getCleanToolName(toolName);
    final mapInput = _parseInput(event.toolInput);

    final path = mapInput['path'] ?? '';
    final pattern = mapInput['pattern'] ?? '';
    final searchPath = mapInput['path'] ?? '';

    final l10n = AppLocalizations.of(context);
    String statusText = 'Running file operation...';
    if (cleanName == 'file_read') {
      statusText = l10n?.toolReadingFile ?? 'Reading file...';
    } else if (cleanName == 'file_write') {
      statusText = l10n?.toolWritingFile ?? 'Writing file...';
    } else if (cleanName == 'file_edit') {
      statusText = l10n?.toolEditingFile ?? 'Editing file...';
    } else if (cleanName == 'search_glob') {
      statusText = l10n?.toolSearchingFiles ?? 'Searching files (glob)...';
    } else if (cleanName == 'search_grep') {
      statusText = l10n?.toolSearchingFiles ?? 'Grep searching files...';
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (path.toString().isNotEmpty) ...[
            _buildInfoRow(context, 'Target Path', path.toString()),
            const SizedBox(height: 8),
          ],
          if (pattern.toString().isNotEmpty) ...[
            _buildInfoRow(context, 'Pattern', pattern.toString()),
            const SizedBox(height: 8),
          ],
          if (searchPath.toString().isNotEmpty) ...[
            _buildInfoRow(context, 'Search Path', searchPath.toString()),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: AppProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                statusText,
                style: GoogleFonts.roboto(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: errorColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 16, color: errorColor),
              const SizedBox(width: 8),
              Text(
                'File Operation Failed',
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: errorColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event.text.isNotEmpty ? event.text : (event.toolOutput?.toString() ?? 'Unknown error occurred.'),
            style: GoogleFonts.firaCode(
              fontSize: 11,
              color: errorColor,
            ),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _parseInput(dynamic input) {
    if (input is Map) {
      return Map<String, dynamic>.from(input);
    }
    if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return const {};
  }

  Widget _buildFileRead(BuildContext context, dynamic input, Map<String, dynamic>? parsedOutput, dynamic rawOutput) {
    final mapInput = _parseInput(input);
    final path = mapInput['path'] ?? '';
    final type = parsedOutput != null ? parsedOutput['type'] : 'text';
    final fileData = parsedOutput != null ? parsedOutput['file'] as Map? : null;
    final content = fileData != null ? fileData['content']?.toString() ?? '' : (rawOutput?.toString() ?? '');

    if (type == 'directory') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (path.toString().isNotEmpty) ...[
            _buildInfoRow(context, 'Target Path', path.toString()),
            const SizedBox(height: 8),
          ],
          Text(
            'Directory Listing',
            style: GoogleFonts.outfit(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              content,
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }

    int startLine = 1;
    final offsetVal = mapInput['offset'];
    if (offsetVal is num) {
      startLine = offsetVal.toInt() + 1;
    } else if (offsetVal is String) {
      startLine = (int.tryParse(offsetVal) ?? 0) + 1;
    }

    final isMarkdown = _isMarkdownPath(path.toString());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (path.toString().isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: _buildInfoRow(
                  context,
                  'Target Path',
                  _toRelativePath(context, path.toString()),
                ),
              ),
              if (isMarkdown) ...[
                const SizedBox(width: 12),
                _buildReadViewSwitch(context),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          key: const Key('file_read_content_viewport'),
          width: double.infinity,
          height: _readViewportHeight,
          child: isMarkdown && _showMarkdown
              ? SingleChildScrollView(
                  key: const Key('file_read_markdown_body'),
                  child: AppMarkdownRenderer(
                    data: content,
                    isFinal: true,
                    onTapLink: (text, href, title) {
                      unawaited(openExternalUrl(href));
                    },
                  ),
                )
              : KeyedSubtree(
                  key: const Key('file_read_raw_body'),
                  child: _buildCodeBlock(
                    context,
                    code: content,
                    filePath: path.toString(),
                    startLine: startLine,
                  ),
                ),
        ),
      ],
    );
  }

  bool _isMarkdownPath(String path) {
    final normalized = path.toLowerCase();
    return normalized.endsWith('.md') || normalized.endsWith('.markdown');
  }

  Widget _buildReadViewSwitch(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment<bool>(
          value: false,
          label: Text('Raw', key: Key('file_read_raw_toggle')),
        ),
        ButtonSegment<bool>(
          value: true,
          label: Text('MD', key: Key('file_read_md_toggle')),
        ),
      ],
      selected: {_showMarkdown},
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        setState(() {
          _showMarkdown = selection.first;
        });
      },
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? colors.primary.withValues(alpha: 0.2) : Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? colors.primary : colors.onSurfaceVariant;
        }),
        side: WidgetStatePropertyAll(
          BorderSide(color: colors.onSurface.withValues(alpha: 0.05)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
        textStyle: WidgetStatePropertyAll(
          GoogleFonts.roboto(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildCodeBlock(
    BuildContext context, {
    required String code,
    required String filePath,
    required int startLine,
    double height = _readViewportHeight,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultStyle = GoogleFonts.firaCode(
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurface,
      height: 1.5,
    );

    if (!widget.isFullyExpanded) {
      final lineCount = '\n'.allMatches(code).length + 1;
      final lineNumbers = List.generate(lineCount, (i) => '${startLine + i}').join('\n');

      final lineNumbersStyle = GoogleFonts.firaCode(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
        height: 1.5,
      );

      return SizedBox(
        height: height,
        width: double.infinity,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isDark
                ? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.1)
                : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lineNumbers,
                  style: lineNumbersStyle,
                  textAlign: TextAlign.right,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText.rich(
                      TextSpan(text: code, style: defaultStyle),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final codeBlockSpan = _highlightCache.codeBlockSpan(
      code,
      filePath,
      baseStyle: defaultStyle,
      isDark: isDark,
    );

    final lineCount = '\n'.allMatches(code).length + 1;
    final lineNumbers = List.generate(lineCount, (i) => '${startLine + i}').join('\n');

    final lineNumbersStyle = GoogleFonts.firaCode(
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
      height: 1.5,
    );

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark
              ? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.1)
              : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                lineNumbers,
                style: lineNumbersStyle,
                textAlign: TextAlign.right,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText.rich(
                    codeBlockSpan,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileWrite(BuildContext context, dynamic input, Map<String, dynamic>? parsedOutput, dynamic rawOutput) {
    final mapInput = _parseInput(input);
    final path = mapInput['path'] ?? '';
    final type = parsedOutput != null ? parsedOutput['type'] : 'create';
    final length = parsedOutput != null ? parsedOutput['contentLength'] ?? 0 : 0;
    final patch = parsedOutput != null ? parsedOutput['patch']?.toString() : null;

    final actionLabel = type == 'create' ? 'Created file' : 'Updated file';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (path.toString().isNotEmpty) ...[
          _buildInfoRow(context, actionLabel, _toRelativePath(context, path.toString())),
          const SizedBox(height: 8),
        ],
        if (patch != null && patch.trim().isNotEmpty) ...[
          Text(
            'Changes applied:',
            style: GoogleFonts.outfit(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          DiffBlockView(
            patch: patch,
            filePath: path.toString(),
            startLine: 1,
            isFullyExpanded: widget.isFullyExpanded,
            highlightCache: _highlightCache,
          ),
        ] else if (mapInput['content'] != null) ...[
          Text(
            'File Content:',
            style: GoogleFonts.outfit(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          _buildCodeBlock(
            context,
            code: mapInput['content'].toString(),
            filePath: path.toString(),
            startLine: 1,
          ),
        ] else ...[
          Text(
            'File size: $length characters.',
            style: GoogleFonts.roboto(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFileEdit(BuildContext context, dynamic input, Map<String, dynamic>? parsedOutput, dynamic rawOutput) {
    final mapInput = _parseInput(input);
    final path = mapInput['path'] ?? '';
    final patch = parsedOutput != null ? parsedOutput['patch']?.toString() : null;
    final oldString = mapInput['old_string']?.toString();
    final newString = mapInput['new_string']?.toString();
    final rawEdits = mapInput['edits'];
    final startLine = parsedOutput != null ? parsedOutput['startLine'] as int? : null;
    final editStartLines = parseEditStartLines(parsedOutput);

    String? fallbackPatch;
    if (rawEdits is List && rawEdits.isNotEmpty) {
      final buffer = StringBuffer();
      for (var i = 0; i < rawEdits.length; i++) {
        final item = rawEdits[i];
        if (item is Map) {
          final o = item['old_string']?.toString();
          final n = item['new_string']?.toString();
          if (o != null || n != null) {
            if (i > 0) buffer.writeln('---');
            if (o != null) {
              for (final line in o.replaceAll('\r\n', '\n').split('\n')) {
                buffer.writeln('- $line');
              }
            }
            if (n != null) {
              for (final line in n.replaceAll('\r\n', '\n').split('\n')) {
                buffer.writeln('+ $line');
              }
            }
          }
        }
      }
      if (buffer.isNotEmpty) {
        fallbackPatch = buffer.toString().trimRight();
      }
    } else if (oldString != null && newString != null) {
      fallbackPatch =
          '${oldString.replaceAll('\r\n', '\n').split('\n').map((l) => '- $l').join('\n')}\n'
          '${newString.replaceAll('\r\n', '\n').split('\n').map((l) => '+ $l').join('\n')}';
    }

    final displayPatch = patch ?? fallbackPatch;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (path.toString().isNotEmpty) ...[
          _buildInfoRow(context, 'Edited File', _toRelativePath(context, path.toString())),
          const SizedBox(height: 8),
        ],
        if (rawEdits is List && rawEdits.isNotEmpty) ...[
          _buildInfoRow(context, 'Modifications', '${rawEdits.length} edits'),
          const SizedBox(height: 8),
        ],
        if (displayPatch != null && displayPatch.trim().isNotEmpty) ...[
          Text(
            'File Changes (Diff):',
            style: GoogleFonts.outfit(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          DiffBlockView(
            patch: displayPatch,
            filePath: path.toString(),
            startLine: startLine,
            editStartLines: editStartLines,
            isFullyExpanded: widget.isFullyExpanded,
            highlightCache: _highlightCache,
          ),
        ] else ...[
          _buildFallback(context, input, rawOutput),
        ],
      ],
    );
  }

  Widget _buildSearchGlob(BuildContext context, dynamic input, Map<String, dynamic>? parsedOutput, dynamic rawOutput) {
    Map<String, dynamic> mapInput = {};
    if (input is Map) {
      mapInput = Map<String, dynamic>.from(input);
    } else if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) mapInput = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }

    final pattern = mapInput['pattern'] ?? '';
    final searchPath = mapInput['path'] ?? '';
    final files = parsedOutput != null && parsedOutput['filenames'] is List
        ? List<String>.from(parsedOutput['filenames'])
        : <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pattern.toString().isNotEmpty) ...[
          _buildInfoRow(context, 'Glob Pattern', pattern.toString()),
          const SizedBox(height: 4),
        ],
        if (searchPath.toString().isNotEmpty) ...[
          _buildInfoRow(context, 'Search Path', _toRelativePath(context, searchPath.toString())),
          const SizedBox(height: 8),
        ],
        if (pattern.toString().isEmpty && searchPath.toString().isEmpty && mapInput.isNotEmpty) ...[
          _buildInfoRow(context, 'Arguments', mapInput.toString()),
          const SizedBox(height: 8),
        ],
        Text(
          'Matching Files (${files.length}):',
          style: GoogleFonts.outfit(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        if (files.isEmpty)
          Text(
            'No matching files found.',
            style: GoogleFonts.roboto(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: files
                  .map(
                    (f) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Row(
                        children: [
                          FileExtensionIcon(
                            fileName: f,
                            size: 14,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _toRelativePath(context, f),
                              style: GoogleFonts.firaCode(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildSearchGrep(BuildContext context, dynamic input, Map<String, dynamic>? parsedOutput, dynamic rawOutput) {
    Map<String, dynamic> mapInput = {};
    if (input is Map) {
      mapInput = Map<String, dynamic>.from(input);
    } else if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) mapInput = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }

    final query = mapInput['pattern'] ?? '';
    final searchPath = mapInput['path'] ?? '';
    final matches = parsedOutput != null && parsedOutput['content'] is List
        ? List<String>.from(parsedOutput['content'])
        : <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (query.toString().isNotEmpty) ...[
          _buildInfoRow(context, 'Grep Search Pattern', '"$query"'),
          const SizedBox(height: 4),
        ],
        if (searchPath.toString().isNotEmpty) ...[
          _buildInfoRow(context, 'Search Path', _toRelativePath(context, searchPath.toString())),
          const SizedBox(height: 8),
        ],
        if (query.toString().isEmpty && searchPath.toString().isEmpty && mapInput.isNotEmpty) ...[
          _buildInfoRow(context, 'Arguments', mapInput.toString()),
          const SizedBox(height: 8),
        ],
        Text(
          'Matching Lines (${matches.length}):',
          style: GoogleFonts.outfit(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        if (matches.isEmpty)
          Text(
            'No matches found.',
            style: GoogleFonts.roboto(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: matches
                  .map(
                    (m) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3.0),
                      child: SelectableText(
                        m,
                        style: GoogleFonts.firaCode(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    return SelectableText.rich(
      TextSpan(
        style: GoogleFonts.roboto(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          TextSpan(
            text: value,
            style: GoogleFonts.firaCode(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFallback(BuildContext context, dynamic input, dynamic output) {
    final prettyValue = _formatValue(output);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (input != null) ...[
          _buildInfoRow(context, 'Input Parameters', _formatValue(input)),
          const SizedBox(height: 8),
        ],
        Text(
          'Output Result',
          style: GoogleFonts.outfit(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.24),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            prettyValue,
            style: GoogleFonts.firaCode(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }

  String _formatValue(dynamic value) {
    try {
      if (value is String) {
        try {
          final decoded = jsonDecode(value);
          return const JsonEncoder.withIndent('  ').convert(decoded);
        } catch (_) {
          return value;
        }
      }
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}
