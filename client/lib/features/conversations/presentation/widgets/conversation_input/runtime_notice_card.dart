import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';

class RuntimeNoticeCard extends StatefulWidget {
  final RuntimeNotice notice;
  final Color borderColor;
  final Color inputBgColor;
  final Color dimTextColor;
  final VoidCallback? onStop;
  final VoidCallback? onRetry;
  final VoidCallback? onChangeProvider;

  const RuntimeNoticeCard({
    super.key,
    required this.notice,
    required this.borderColor,
    required this.inputBgColor,
    required this.dimTextColor,
    this.onStop,
    this.onRetry,
    this.onChangeProvider,
  });

  @override
  State<RuntimeNoticeCard> createState() => _RuntimeNoticeCardState();
}

class _RuntimeNoticeCardState extends State<RuntimeNoticeCard> {
  Timer? _ticker;
  DateTime _now = DateTime.now();
  DateTime? _retryDeadline;

  @override
  void initState() {
    super.initState();
    _configureTicker();
  }

  @override
  void didUpdateWidget(covariant RuntimeNoticeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notice.resumeAt != widget.notice.resumeAt ||
        oldWidget.notice.retryAfterMs != widget.notice.retryAfterMs) {
      _configureTicker();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _configureTicker() {
    _ticker?.cancel();
    _retryDeadline = _deriveRetryDeadline();
    if (_hasCountdown) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {
            _now = DateTime.now();
          });
        }
      });
    }
  }

  bool get _hasCountdown => _remaining != null;

  Duration? get _remaining {
    final resumeAt = widget.notice.resumeAt;
    if (resumeAt != null) {
      final delta = resumeAt.difference(_now);
      // Hide the countdown once the deadline has passed instead of pinning
      // the notice at "0s" forever.
      return delta.isNegative ? null : delta;
    }
    final retryDeadline = _retryDeadline;
    if (retryDeadline != null) {
      final delta = retryDeadline.difference(_now);
      return delta.isNegative ? null : delta;
    }
    return null;
  }

  DateTime? _deriveRetryDeadline() {
    if (widget.notice.resumeAt != null) {
      return null;
    }
    final retryAfterMs = widget.notice.retryAfterMs;
    if (retryAfterMs == null || retryAfterMs <= 0) {
      return null;
    }
    return DateTime.now().add(Duration(milliseconds: retryAfterMs));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isError = widget.notice.isBlocked || widget.notice.isFatal;
    final accent = isError ? colorScheme.error : colorScheme.tertiary;
    final titleStyle = GoogleFonts.inter(
      color: colorScheme.onSurface,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    final bodyStyle = GoogleFonts.inter(
      color: widget.dimTextColor,
      fontSize: 12,
      height: 1.4,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // color: widget.inputBgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.schedule_outlined,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.notice.title, style: titleStyle),
              ),
            ],
          ),
          if ((widget.notice.message ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(widget.notice.message!, style: bodyStyle),
          ],
          if (_remaining != null) ...[
            const SizedBox(height: 6),
            Text(
              'Continuing automatically in ${_formatDuration(_remaining!)}.',
              style: bodyStyle,
            ),
          ],
          if (widget.notice.requestsPerMinuteLimit != null) ...[
            const SizedBox(height: 4),
            Text(
              'Limit: ${widget.notice.requestsPerMinuteLimit} requests/min.',
              style: bodyStyle,
            ),
          ],
          if (widget.notice.actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.notice.actions.contains('stop'))
                  _ActionChip(
                    label: 'Stop',
                    onPressed: widget.onStop,
                  ),
                if (widget.notice.actions.contains('retry'))
                  _ActionChip(
                    label: 'Retry',
                    onPressed: widget.onRetry,
                  ),
                if (widget.notice.actions.contains('change_provider') ||
                    widget.notice.actions.contains('continue_with_provider'))
                  _ActionChip(
                    label: 'Change Provider',
                    onPressed: widget.onChangeProvider,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    if (totalSeconds <= 0) {
      return '0s';
    }
    final days = totalSeconds ~/ Duration.secondsPerDay;
    final hours = (totalSeconds % Duration.secondsPerDay) ~/ Duration.secondsPerHour;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (days > 0) {
      if (hours > 0) {
        return '${days}d ${hours}h';
      }
      return '${days}d';
    }
    if (hours > 0) {
      final remainingMinutes = (totalSeconds % Duration.secondsPerHour) ~/ Duration.secondsPerMinute;
      if (remainingMinutes > 0) {
        return '${hours}h ${remainingMinutes}m';
      }
      return '${hours}h';
    }
    if (minutes <= 0) {
      return '${seconds}s';
    }
    if (seconds == 0) {
      return '${minutes}m';
    }
    return '${minutes}m ${seconds}s';
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _ActionChip({
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Text(label),
    );
  }
}
