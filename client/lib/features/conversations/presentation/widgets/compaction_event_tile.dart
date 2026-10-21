import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/utils/compaction_failure_formatter.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

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
        child: AppProgressIndicator(
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
                  message: _detailText(snapshot, context),
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

  String _detailText(CompactionEventSnapshot snapshot, [BuildContext? context]) {
    final lines = <String>[];
    // Task 118: every public percentage uses the full resolved window W, the
    // same denominator as the daemon's threshold and complete-request target.
    // The internal usable-input budget is a safeguard, not a public metric.
    final percentageBudget = snapshot.contextWindowTokens;
    if (snapshot.estimatedRequestTokensBefore != null) {
      final beforeTokens = snapshot.estimatedRequestTokensBefore!;
      final isOverBudget = percentageBudget != null && beforeTokens > percentageBudget;
      final label = isOverBudget ? 'Before compaction (history)' : 'Before compaction';
      lines.add(
        _tokenLine(
          label,
          beforeTokens,
          percentageBudget,
        ),
      );
    }
    final afterTokens = snapshot.providerConfirmedRequestTokensAfter ?? snapshot.estimatedRequestTokensAfter;
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
    final reclaimed = before != null && afterTokens != null && before > afterTokens
        ? (before - afterTokens).clamp(0, before).toInt()
        : snapshot.reclaimedTokens;
    if (reclaimed != null && before != null) {
      lines.add(
        'Context reclaimed: ${_formatTokens(reclaimed)} tokens (${_percentage(reclaimed, before)})',
      );
    }
    if (snapshot.retainedTailTokens != null) {
      final rawTail = snapshot.retainedTailTokens!;
      final tailTokens = (afterTokens != null && rawTail > afterTokens)
          ? afterTokens
          : rawTail;
      lines.add(
        'Retained tail: ~${_formatTokens(tailTokens)} tokens',
      );
    }
    final threshold = snapshot.autoThresholdTokens;
    if (threshold != null) {
      lines.add(
        _tokenLine('Auto threshold', threshold, percentageBudget),
      );
    }
    if (snapshot.contextWindowTokens != null) {
      lines.add(
        'Context window: ${_formatTokens(snapshot.contextWindowTokens!)} tokens',
      );
    }
    if (snapshot.status == CompactionLifecycleStatus.failed ||
        snapshot.failureReason != null ||
        snapshot.failureStage != null ||
        snapshot.failureCause != null) {
      final l10n = context != null ? AppLocalizations.of(context) : null;
      final failure = CompactionFailureFormatter.resolveForSnapshot(
        snapshot,
        l10n: l10n,
      );
      lines.addAll(failure.toDetailLines(l10n: l10n));
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
