import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';

class MemoryToolTile extends StatelessWidget {
  final CanonicalEvent event;

  const MemoryToolTile({
    super.key,
    required this.event,
  });

  Map<String, dynamic> _parseInput(dynamic input) {
    if (input is Map<String, dynamic>) return input;
    if (input is Map) return Map<String, dynamic>.from(input);
    if (input is String) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  @override
  Widget build(BuildContext context) {
    if (event.status == EventStatus.running) {
      return _buildRunningIndicator(context);
    }

    if (event.status == EventStatus.error) {
      return _buildErrorState(context);
    }

    final mapInput = _parseInput(event.toolInput);
    final action = mapInput['action']?.toString().toLowerCase() ?? 'read';
    final target = mapInput['target']?.toString().toLowerCase() ?? 'memory';
    final content = mapInput['content']?.toString() ?? '';
    final oldText = mapInput['old_text']?.toString() ?? '';

    final targetLabel = target == 'user' ? 'User Memory' : 'Project Memory';
    final actionColor = _getActionColor(context, action);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: actionColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: actionColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  action.toUpperCase(),
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: actionColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  targetLabel,
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          if (oldText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Target Text to ${action == 'remove' ? 'Remove' : 'Replace'}:',
              style: GoogleFonts.roboto(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                oldText,
                style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
                textDirection: TextUtils.getTextDirection(oldText),
              ),
            ),
          ],
          if (content.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              action == 'replace' ? 'New Content:' : 'Content:',
              style: GoogleFonts.roboto(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              child: SelectableText(
                content,
                style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                textDirection: TextUtils.getTextDirection(content),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _getActionColor(BuildContext context, String action) {
    switch (action) {
      case 'add':
        return Colors.green;
      case 'replace':
        return Colors.orange;
      case 'remove':
        return Theme.of(context).colorScheme.error;
      case 'read':
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  Widget _buildRunningIndicator(BuildContext context) {
    final mapInput = _parseInput(event.toolInput);
    final action = mapInput['action']?.toString() ?? 'accessing';
    final target = mapInput['target']?.toString() ?? 'memory';

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: AppProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Updating persistent $target ($action)...',
            style: GoogleFonts.roboto(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        event.toolOutput?.toString() ?? 'Failed to perform memory operation.',
        style: GoogleFonts.roboto(
          fontSize: 12,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}
