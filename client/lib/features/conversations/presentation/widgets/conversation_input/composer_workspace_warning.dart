import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Reminder that the first message needs a selected workspace.
class ComposerWorkspaceWarning extends StatelessWidget {
  final VoidCallback onRefresh;

  const ComposerWorkspaceWarning({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onRefresh,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.error.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.error.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(Icons.folder_open_outlined, size: 16, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Select a workspace before your first Sanad Agent message.',
                style: GoogleFonts.inter(
                  color: colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 12, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

