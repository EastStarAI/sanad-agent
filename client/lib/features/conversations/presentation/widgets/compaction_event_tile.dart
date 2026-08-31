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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(child: Divider(color: colorScheme.outlineVariant)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.75),
              child: Semantics(
                label: '${snapshot.timelineLabel}, ${snapshot.detailTriggerLabel}',
                button: true,
                child: Tooltip(
                  key: _tooltipKey,
                  message: _detailText(snapshot),
                  child: InkWell(
                    key: ValueKey('compaction-label-${snapshot.compactionId}'),
                    onTap: () => _tooltipKey.currentState?.ensureTooltipVisible(),
                    onFocusChange: (focused) {
                      if (focused) {
                        _tooltipKey.currentState?.ensureTooltipVisible();
                      } else {
                        Tooltip.dismissAllToolTips();
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            indicator,
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                snapshot.timelineLabel,
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: Divider(color: colorScheme.outlineVariant)),
          ],
        ),
      ),
    );
  }

  String _detailText(CompactionEventSnapshot snapshot) {
    final lines = <String>[];
    final percentageBudget = snapshot.effectiveInputBudgetTokens ?? snapshot.contextWindowTokens;
    if (snapshot.estimatedRequestTokensBefore != null) {
      lines.add(
        _tokenLine(
          'Before compaction',
          snapshot.estimatedRequestTokensBefore!,
          percentageBudget,
        ),
      );
    }
    if (snapshot.providerConfirmedRequestTokensAfter != null) {
      lines.add(
        '${_tokenLine('After compaction', snapshot.providerConfirmedRequestTokensAfter!, percentageBudget)} ✓ Confirmed',
      );
    } else if (snapshot.estimatedRequestTokensAfter != null) {
      lines.add(
        _tokenLine(
          'After compaction',
          snapshot.estimatedRequestTokensAfter!,
          percentageBudget,
        ),
      );
    }
    final before = snapshot.estimatedRequestTokensBefore;
    final confirmedAfter = snapshot.providerConfirmedRequestTokensAfter;
    final reclaimed = before != null && confirmedAfter != null
        ? (before - confirmedAfter).clamp(0, before).toInt()
        : snapshot.reclaimedTokens;
    if (reclaimed != null && before != null) {
      lines.add(
        'Context reclaimed: ${_formatTokens(reclaimed)} tokens (${_percentage(reclaimed, before)})',
      );
    }
    if (snapshot.retainedTailTokens != null) {
      lines.add(
        'Retained tail: ~${_formatTokens(snapshot.retainedTailTokens!)} tokens',
      );
    }
    final threshold = snapshot.autoThresholdTokens;
    final usableInput = snapshot.effectiveInputBudgetTokens;
    if (threshold != null) {
      lines.add(
        _tokenLine('Auto threshold', threshold, usableInput),
      );
    }
    if (usableInput != null) {
      lines.add('Usable input: ${_formatTokens(usableInput)} tokens');
    }
    if (snapshot.contextWindowTokens != null) {
      lines.add(
        'Context window: ${_formatTokens(snapshot.contextWindowTokens!)} tokens',
      );
    }
    if (snapshot.failureReason != null) {
      lines.add('Failure: ${snapshot.failureReason}');
    }
    return lines.join('\n');
  }

  String _tokenLine(String label, int tokens, int? contextWindowTokens) {
    final window = contextWindowTokens;
    if (window == null || window <= 0) {
      return '$label: ${_formatTokens(tokens)} tokens';
    }
    return '$label: ${_formatTokens(tokens)} tokens (${_percentage(tokens, window)})';
  }

  String _percentage(int numerator, int denominator) {
    return '${(numerator / denominator * 100).toStringAsFixed(1)}%';
  }

  String _formatTokens(int tokens) {
    final digits = tokens.toString();
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[index]);
    }
    return buffer.toString();
  }
}
