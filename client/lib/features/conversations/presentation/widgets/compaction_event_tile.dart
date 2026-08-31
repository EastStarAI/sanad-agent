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
          onFocusChange: (focused) {
            if (focused) {
              _tooltipKey.currentState?.ensureTooltipVisible();
            } else {
              Tooltip.dismissAllToolTips();
            }
          },
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          child: Tooltip(
            key: _tooltipKey,
            message: _detailText(snapshot),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Expanded(
                      child: Divider(color: colorScheme.outlineVariant),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.75,
                      ),
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
                    Expanded(
                      child: Divider(color: colorScheme.outlineVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _detailText(CompactionEventSnapshot snapshot) {
    final lines = <String>[
      'Trigger: ${snapshot.detailTriggerLabel}',
      'Status: ${snapshot.status.name}',
    ];
    if (snapshot.contextWindowTokens != null) {
      lines.add('Context window: ${snapshot.contextWindowTokens}');
    }
    if (snapshot.estimatedRequestTokensBefore != null) {
      final measurement = switch (snapshot.beforeMeasurementKind) {
        'confirmed' => 'Provider confirmed before',
        'mixed' => 'Confirmed + estimated tail before',
        _ => 'Estimated before',
      };
      lines.add(
        _tokenLine(
          measurement,
          snapshot.estimatedRequestTokensBefore!,
          snapshot.contextWindowTokens,
        ),
      );
    }
    if (snapshot.providerConfirmedRequestTokensAfter != null) {
      lines.add(
        _tokenLine(
          'Provider confirmed after',
          snapshot.providerConfirmedRequestTokensAfter!,
          snapshot.contextWindowTokens,
        ),
      );
    }
    if (snapshot.estimatedRequestTokensAfter != null && snapshot.providerConfirmedRequestTokensAfter == null) {
      lines.add(
        _tokenLine(
          'Estimated after',
          snapshot.estimatedRequestTokensAfter!,
          snapshot.contextWindowTokens,
        ),
      );
    }
    final before = snapshot.estimatedRequestTokensBefore;
    final confirmedAfter = snapshot.providerConfirmedRequestTokensAfter;
    final reclaimed = before != null && confirmedAfter != null
        ? (before - confirmedAfter).clamp(0, before).toInt()
        : snapshot.reclaimedTokens;
    if (reclaimed != null && before != null) {
      final reclaimedLabel = snapshot.beforeMeasurementKind == 'confirmed' && confirmedAfter != null
          ? 'Provider confirmed reclaimed'
          : 'Estimated reclaimed';
      lines.add(
        '$reclaimedLabel: $reclaimed tokens (${_percentage(reclaimed, before)})',
      );
    }
    if (snapshot.retainedTailTokens != null) {
      lines.add('Retained tail: ${snapshot.retainedTailTokens} tokens');
    }
    if (snapshot.startedAt != null) {
      lines.add('Started: ${snapshot.startedAt!.toUtc().toIso8601String()}');
    }
    if (snapshot.completedAt != null) {
      lines.add(
        'Completed: ${snapshot.completedAt!.toUtc().toIso8601String()}',
      );
    }
    if (snapshot.durationMs != null) {
      lines.add('Duration: ${snapshot.durationMs} ms');
    }
    if (snapshot.failureReason != null) {
      lines.add('Failure: ${snapshot.failureReason}');
    }
    return lines.join('\n');
  }

  String _tokenLine(String label, int tokens, int? contextWindowTokens) {
    final window = contextWindowTokens;
    if (window == null || window <= 0) return '$label: $tokens tokens';
    return '$label: $tokens tokens (${_percentage(tokens, window)})';
  }

  String _percentage(int numerator, int denominator) {
    return '${(numerator / denominator * 100).toStringAsFixed(1)}%';
  }
}
