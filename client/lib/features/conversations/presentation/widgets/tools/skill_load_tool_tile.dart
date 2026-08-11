import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/app_markdown_renderer.dart';
import 'package:sanad_client/utils/link_utils.dart';

class SkillLoadToolTile extends StatelessWidget {
  static const _sourcePrefix = 'Skill source: ';

  final CanonicalEvent event;

  const SkillLoadToolTile({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    if (event.status == EventStatus.running) {
      return _buildRunningIndicator(context);
    }

    if (event.status == EventStatus.error) {
      return _buildErrorState(context);
    }

    final document = _SkillDocument.parse(event.toolOutput);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (document.path.isNotEmpty) ...[
          _buildInfoRow(context, 'Target Path', document.path),
          const SizedBox(height: 8),
        ],
        if (document.markdown.isNotEmpty)
          SizedBox(
            key: const Key('skill_markdown_body'),
            width: double.infinity,
            child: AppMarkdownRenderer(
              data: document.markdown,
              isFinal: true,
              onTapLink: (text, href, title) => openExternalUrl(href),
            ),
          ),
      ],
    );
  }

  Widget _buildRunningIndicator(BuildContext context) {
    final skillName = _parseInput(event.toolInput)['skill']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (skillName.isNotEmpty) ...[
          _buildInfoRow(context, 'Skill', skillName),
          const SizedBox(height: 8),
        ],
        Text(
          'Loading skill...',
          style: GoogleFonts.roboto(
            fontSize: 12,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: errorColor.withValues(alpha: 0.2)),
      ),
      child: Text(
        event.text.isNotEmpty
            ? event.text
            : (event.toolOutput?.toString() ?? 'Failed to load skill.'),
        style: GoogleFonts.firaCode(fontSize: 11, color: errorColor),
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
}

class _SkillDocument {
  final String path;
  final String markdown;

  const _SkillDocument({required this.path, required this.markdown});

  factory _SkillDocument.parse(dynamic output) {
    if (output is Map) {
      return _SkillDocument.fromMap(Map<String, dynamic>.from(output));
    }

    final raw = output?.toString() ?? '';
    if (raw.startsWith(SkillLoadToolTile._sourcePrefix)) {
      final separator = raw.indexOf('\n\n');
      if (separator >= 0) {
        return _SkillDocument(
          path: raw
              .substring(SkillLoadToolTile._sourcePrefix.length, separator)
              .trim(),
          markdown: raw.substring(separator + 2),
        );
      }
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return _SkillDocument.fromMap(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}

    return _SkillDocument(path: '', markdown: raw);
  }

  factory _SkillDocument.fromMap(Map<String, dynamic> output) {
    return _SkillDocument(
      path: output['path']?.toString() ?? '',
      markdown:
          output['prompt']?.toString() ?? output['content']?.toString() ?? '',
    );
  }
}
