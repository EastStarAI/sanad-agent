import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/presentation/utils/tool_presentation_helper.dart';

class ConversationActivityTile extends StatefulWidget {
  const ConversationActivityTile({
    super.key,
    required this.activity,
    this.executionSnapshot,
    this.now,
    this.onDisplayed,
  });

  final ConversationActivity activity;
  final SessionExecutionSnapshot? executionSnapshot;
  final DateTime Function()? now;
  final VoidCallback? onDisplayed;

  @override
  State<ConversationActivityTile> createState() => _ConversationActivityTileState();
}

class _ConversationActivityTileState extends State<ConversationActivityTile> {
  static const Duration _debounceDuration = Duration(seconds: 1);

  Timer? _debounceTimer;
  Timer? _elapsedTimer;
  _ActivityText? _displayedText;
  _ActivityText? _pendingText;
  String? _elapsedText;

  @override
  void initState() {
    super.initState();
    _queue(widget.activity);
    _startElapsedTimer();
  }

  @override
  void didUpdateWidget(covariant ConversationActivityTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    _queue(widget.activity);
    if (oldWidget.executionSnapshot != widget.executionSnapshot) {
      _startElapsedTimer();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _elapsedTimer?.cancel();
    super.dispose();
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _updateElapsedText(notify: false);
    if (widget.executionSnapshot?.elapsedMs == null) return;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateElapsedText(notify: true);
    });
  }

  void _updateElapsedText({required bool notify}) {
    final elapsed = widget.executionSnapshot?.elapsedAt(
      widget.now?.call() ?? DateTime.now(),
    );
    final next = elapsed == null ? null : _formatElapsed(elapsed);
    if (next == _elapsedText) return;
    if (notify && mounted) {
      setState(() => _elapsedText = next);
    } else {
      _elapsedText = next;
    }
  }

  void _queue(ConversationActivity activity) {
    final candidate = _ActivityText.fromActivity(activity);
    if (candidate == _displayedText || candidate == _pendingText) return;

    _debounceTimer?.cancel();
    _pendingText = candidate;
    _debounceTimer = Timer(_debounceDuration, () {
      if (!mounted) return;
      setState(() {
        _displayedText = _pendingText;
        _pendingText = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onDisplayed?.call();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayedText = _displayedText;
    if (displayedText == null) {
      return const SizedBox.shrink(key: ValueKey('activity-hidden'));
    }
    return _ActivityRow(text: displayedText, elapsedText: _elapsedText);
  }

  static String _formatElapsed(Duration elapsed) {
    final totalSeconds = elapsed.inSeconds;
    if (totalSeconds < Duration.secondsPerMinute) {
      return 'Working for ${totalSeconds}s';
    }
    final totalMinutes = elapsed.inMinutes;
    if (totalMinutes < Duration.minutesPerHour) {
      return 'Working for ${totalMinutes}m, ${totalSeconds % Duration.secondsPerMinute}s';
    }
    return 'Working for ${elapsed.inHours}h, ${totalMinutes % Duration.minutesPerHour}m';
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.text, required this.elapsedText});

  final _ActivityText text;
  final String? elapsedText;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: [
        text.detail.isEmpty ? text.label : '${text.label} ${text.detail}',
        if (elapsedText != null) elapsedText!,
      ].join(' '),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(
                key: const Key('conversation_activity_progress'),
                strokeWidth: 2,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Text.rich(
                  TextSpan(
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                    children: [
                      TextSpan(
                        text: text.label,
                        style: TextStyle(
                          color: colors.onSurface.withValues(alpha: 0.4),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (text.detail.isNotEmpty)
                        TextSpan(
                          text: text.detail,
                          style: TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (elapsedText != null) ...[
              const SizedBox(width: 12),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  elapsedText!,
                  key: const Key('conversation_activity_elapsed'),
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: colors.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityText {
  const _ActivityText({
    required this.label,
    required this.detail,
  });

  factory _ActivityText.fromActivity(ConversationActivity activity) {
    switch (activity.kind) {
      case ConversationActivityKind.reasoning:
        return _ActivityText(
          label: 'Thinking: ',
          detail: _firstWords(activity.event!.text, 5),
        );
      case ConversationActivityKind.runningTool:
        final event = activity.event!;
        final detail = ToolPresentationHelper.getToolDetailSuffix(event);
        if (detail.isNotEmpty) {
          final action = ToolPresentationHelper.cleanToolTitle(
            event.toolName ?? '',
          );
          return _ActivityText(
            label: 'Running: ',
            detail: action == 'Ran' ? detail : '$action: $detail',
          );
        }
        return _ActivityText(
          label: 'Running: ',
          detail: ToolPresentationHelper.cleanToolTitle(
            event.toolName ?? 'tool',
          ),
        );
      case ConversationActivityKind.thinking:
        return const _ActivityText(label: 'Working…', detail: '');
    }
  }

  final String label;
  final String detail;

  static String _firstWords(String text, int count) {
    final words = text.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    return words.take(count).join(' ');
  }

  @override
  bool operator ==(Object other) => other is _ActivityText && label == other.label && detail == other.detail;

  @override
  int get hashCode => Object.hash(label, detail);
}
