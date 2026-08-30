import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';

class CompactionEventTile extends StatefulWidget {
  final CompactionEventSnapshot snapshot;

  const CompactionEventTile({super.key, required this.snapshot});

  @override
  State<CompactionEventTile> createState() => _CompactionEventTileState();
}

class _CompactionEventTileState extends State<CompactionEventTile> {
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final snapshot = widget.snapshot;
    final indicator = switch (snapshot.status) {
      CompactionLifecycleStatus.started => SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colorScheme.primary,
        ),
      ),
      CompactionLifecycleStatus.completed => Icon(
        Icons.check_circle_outline,
        size: 16,
        color: colorScheme.primary,
      ),
      CompactionLifecycleStatus.failed => Icon(
        Icons.error_outline,
        size: 16,
        color: colorScheme.error,
      ),
    };

    return Semantics(
      label: '${snapshot.timelineLabel}, ${snapshot.detailTriggerLabel}',
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: InkWell(
          onTap: () => _tooltipKey.currentState?.ensureTooltipVisible(),
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          child: Tooltip(
            key: _tooltipKey,
            message: _detailText(snapshot),
            child: Row(
              children: [
                Expanded(child: Divider(color: colorScheme.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      indicator,
                      const SizedBox(width: 8),
                      Text(
                        snapshot.timelineLabel,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: Divider(color: colorScheme.outlineVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _detailText(CompactionEventSnapshot snapshot) {
    final lines = <String>[
      'Type: ${snapshot.trigger == CompactionTriggerKind.manual ? 'Manual' : 'Auto'}',
      'Trigger: ${snapshot.detailTriggerLabel}',
      'Status: ${snapshot.status.name}',
    ];
    if (snapshot.contextWindowTokens != null) {
      lines.add('Context window: ${snapshot.contextWindowTokens}');
    }
    if (snapshot.estimatedRequestTokensBefore != null) {
      lines.add('Before: ${snapshot.estimatedRequestTokensBefore} tokens');
    }
    if (snapshot.estimatedRequestTokensAfter != null) {
      lines.add('After: ${snapshot.estimatedRequestTokensAfter} tokens');
    }
    final reclaimed = snapshot.reclaimedTokens;
    if (reclaimed != null) {
      lines.add('Reclaimed: $reclaimed tokens');
    }
    if (snapshot.retainedTailTokens != null) {
      lines.add('Retained tail: ${snapshot.retainedTailTokens} tokens');
    }
    if (snapshot.durationMs != null) {
      lines.add('Duration: ${snapshot.durationMs} ms');
    }
    if (snapshot.failureReason != null) {
      lines.add('Failure: ${snapshot.failureReason}');
    }
    return lines.join('\n');
  }
}
