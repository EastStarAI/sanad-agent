import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

class GenericToolTile extends StatelessWidget {
  final CanonicalEvent event;

  const GenericToolTile({
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

    final input = event.toolInput;
    final output = event.toolOutput;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (input != null) ...[
          Text(
            'Input Parameters',
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
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
              ),
            ),
            child: Text(
              _formatValue(input),
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (output != null) ...[
          Text(
            'Output Result',
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
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
              ),
            ),
            child: Text(
              _formatValue(output),
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRunningIndicator(BuildContext context) {
    final input = event.toolInput;

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (input != null) ...[
            Text(
              'Input Parameters',
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
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                ),
              ),
              child: Text(
                _formatValue(input),
                style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 10),
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
                AppLocalizations.of(context)?.toolExecuting ?? 'Executing tool...',
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
        event.text.isNotEmpty ? event.text : (event.toolOutput?.toString() ?? 'Tool execution failed.'),
        style: GoogleFonts.firaCode(fontSize: 11, color: errorColor),
      ),
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
