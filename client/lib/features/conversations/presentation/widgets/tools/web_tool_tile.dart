import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

class WebToolTile extends StatelessWidget {
  final CanonicalEvent event;

  const WebToolTile({
    super.key,
    required this.event,
  });

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

    if (toolName.contains('search')) {
      return _buildWebSearch(context, input, output);
    } else if (toolName.contains('fetch')) {
      return _buildWebFetch(context, input, output);
    }

    return _buildFallback(context, input, output);
  }

  Widget _buildRunningIndicator(BuildContext context) {
    final toolName = event.toolName ?? '';
    final input = event.toolInput;

    Map<String, dynamic> mapInput = {};
    if (input is Map) {
      mapInput = Map<String, dynamic>.from(input);
    } else if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) {
          mapInput = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }

    final query = mapInput['query'] ?? '';
    final url = mapInput['urls'] ?? mapInput['url'] ?? '';

    String statusText = 'Working...';
    if (toolName.contains('search')) {
      statusText = 'Searching the web...';
    } else if (toolName.contains('fetch') || toolName.contains('url')) {
      statusText = 'Fetching webpage...';
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (query.toString().isNotEmpty) ...[
            RichText(
              text: TextSpan(
                style: GoogleFonts.roboto(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                children: [
                  const TextSpan(
                    text: 'Search Query: ',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(
                    text: '"$query"',
                    style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (url.toString().isNotEmpty) ...[
            RichText(
              text: TextSpan(
                style: GoogleFonts.roboto(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                children: [
                  const TextSpan(
                    text: 'URL: ',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(
                    text: url is List ? url.join(', ') : url.toString(),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
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
      child: Text(
        event.text.isNotEmpty ? event.text : (event.toolOutput?.toString() ?? 'Web operation failed.'),
        style: GoogleFonts.firaCode(fontSize: 11, color: errorColor),
      ),
    );
  }

  Widget _buildWebSearch(BuildContext context, dynamic input, dynamic output) {
    final query = input is Map ? (input['query'] ?? '') : '';
    final outputString = output?.toString() ?? '';

    // Attempt to parse Markdown formatted search results
    final blocks = outputString.split('\n\n').where((b) => b.trim().isNotEmpty).toList();
    final List<Map<String, String>> parsedHits = [];

    // The first block is typically "Search results for: ..."
    // Parse subsequent blocks
    for (var i = 1; i < blocks.length; i++) {
      final block = blocks[i].trim();
      final lines = block.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

      if (lines.length >= 2) {
        final rawTitle = lines[0];
        final title = (rawTitle.startsWith('**') && rawTitle.endsWith('**'))
            ? rawTitle.substring(2, rawTitle.length - 2)
            : rawTitle;

        final url = lines.last;
        final snippet = lines.length > 2 ? lines.sublist(1, lines.length - 1).join('\n') : '';

        // Validate URL format roughly
        if (url.startsWith('http://') || url.startsWith('https://')) {
          parsedHits.add({
            'title': title,
            'snippet': snippet,
            'url': url,
          });
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (query.toString().isNotEmpty) ...[
          RichText(
            text: TextSpan(
              style: GoogleFonts.roboto(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              children: [
                const TextSpan(
                  text: 'Search Query: ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: '"$query"',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          'Search Results',
          style: GoogleFonts.outfit(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        if (parsedHits.isEmpty)
          MarkdownBody(
            data: outputString,
            onTapLink: (text, href, title) => _launchUrl(href),
          )
        else
          Column(
            children: parsedHits.map((hit) {
              final title = hit['title'] ?? 'Result';
              final url = hit['url'] ?? '';
              final snippet = hit['snippet'] ?? '';

              return Container(
                margin: const EdgeInsets.symmetric(vertical: 4.0),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                  ),
                ),
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () => _launchUrl(url),
                      child: Text(
                        title,
                        style: GoogleFonts.roboto(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.roboto(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                    if (snippet.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        snippet,
                        style: GoogleFonts.roboto(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildWebFetch(BuildContext context, dynamic input, dynamic output) {
    Map<String, dynamic>? parsedOutput;
    if (output is String) {
      try {
        parsedOutput = jsonDecode(output);
      } catch (_) {}
    } else if (output is Map<String, dynamic>) {
      parsedOutput = output;
    }

    final resultsList = parsedOutput != null && parsedOutput['results'] is List ? parsedOutput['results'] as List : [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Fetched Pages',
          style: GoogleFonts.outfit(
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        if (resultsList.isEmpty)
          Text(
            output?.toString() ?? 'No fetch output available.',
            style: GoogleFonts.roboto(fontSize: 13),
          )
        else
          Column(
            children: resultsList.map((res) {
              if (res is! Map) return const SizedBox.shrink();
              final url = res['url']?.toString() ?? '';
              final result = res['result']?.toString() ?? '';
              final code = res['code'] ?? 200;

              return Container(
                margin: const EdgeInsets.symmetric(vertical: 6.0),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                  ),
                ),
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.link,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkWell(
                            onTap: () => _launchUrl(url),
                            child: Text(
                              url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.roboto(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'HTTP $code',
                          style: GoogleFonts.roboto(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: code == 200 ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 12),
                    MarkdownBody(
                      data: result,
                      onTapLink: (text, href, title) => _launchUrl(href),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildFallback(BuildContext context, dynamic input, dynamic output) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (input != null) ...[
          Text(
            'Input Parameters',
            style: GoogleFonts.outfit(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.24),
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            input.toString(),
            style: GoogleFonts.roboto(fontSize: 13),
          ),
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
        MarkdownBody(
          data: output?.toString() ?? '',
          onTapLink: (text, href, title) => _launchUrl(href),
        ),
      ],
    );
  }

  Future<void> _launchUrl(String? href) async {
    if (href != null) {
      final uri = Uri.tryParse(href);
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
    }
  }
}
