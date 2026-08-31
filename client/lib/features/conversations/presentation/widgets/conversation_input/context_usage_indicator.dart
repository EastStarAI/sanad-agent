import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';

class ContextUsageIndicator extends StatefulWidget {
  final LlmUsageSnapshot usage;

  const ContextUsageIndicator({super.key, required this.usage});

  @override
  State<ContextUsageIndicator> createState() => _ContextUsageIndicatorState();
}

class _ContextUsageIndicatorState extends State<ContextUsageIndicator> {
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final fraction = widget.usage.usageFraction;
    if (fraction == null) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final color = switch (fraction) {
      >= ContextUsageThresholds.critical => colorScheme.error,
      >= ContextUsageThresholds.high => colorScheme.tertiary,
      _ => colorScheme.primary,
    };
    final tooltip = _tooltipText(widget.usage, fraction);

    return Semantics(
      label: tooltip.replaceAll('\n', ', '),
      button: true,
      child: InkWell(
        onTap: () => _tooltipKey.currentState?.ensureTooltipVisible(),
        customBorder: const CircleBorder(),
        child: Tooltip(
          key: _tooltipKey,
          message: tooltip,
          child: SizedBox(
            key: const Key('context_usage_indicator'),
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              value: fraction,
              strokeWidth: 2.2,
              backgroundColor: color.withValues(alpha: 0.16),
              color: color.withValues(alpha: 0.50),
            ),
          ),
        ),
      ),
    );
  }

  String _tooltipText(LlmUsageSnapshot usage, double fraction) {
    final lines = <String>[
      'Measurement: Provider confirmed',
      'Context window:${(fraction * 100).round()}% full',
      '${_formatTokens(usage.inputTokens!)} / ${_formatTokens(usage.contextWindowTokens!)} tokens used',
    ];
    if (usage.cachedTokens != null) {
      lines.add('Cached input: ${_formatTokens(usage.cachedTokens!)} tokens');
    }
    // if (usage.outputTokens != null) {
    //   lines.add('Output: ${_formatTokens(usage.outputTokens!)} tokens');
    // }
    // if (usage.totalTokens != null) {
    //   lines.add('Total: ${_formatTokens(usage.totalTokens!)} tokens');
    // }
    // if (usage.reasoningTokens != null) {
    //   lines.add('Reasoning: ${_formatTokens(usage.reasoningTokens!)} tokens');
    // }
    if (usage.modelId != null) lines.add('Model: ${usage.modelId}');
    // if (usage.observedAt != null) {
    //   lines.add(
    //     'Updated: ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(usage.observedAt!.toLocal()))}',
    //   );
    // }
    return lines.join('\n');
  }

  String _formatTokens(int value) {
    if (value >= 1000000) {
      final number = value / 1000000;
      return '${number.toStringAsFixed(number >= 10 ? 0 : 1).replaceFirst(RegExp(r'\.0$'), '')}M';
    }
    if (value >= 1000) {
      final number = value / 1000;
      return '${number.toStringAsFixed(number >= 10 ? 0 : 1).replaceFirst(RegExp(r'\.0$'), '')}k';
    }
    return value.toString();
  }
}

abstract final class ContextUsageThresholds {
  static const double high = 0.75;
  static const double critical = 0.9;
}
