import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_clock_scope.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/presentation/utils/tool_presentation_helper.dart';

class ConversationActivityBar extends StatefulWidget {
  const ConversationActivityBar({
    super.key,
    this.activity,
    this.latestDescription,
    this.executionSnapshot,
    this.isRtl = false,
    this.random,
    this.now,
    this.clock,
  });

  final ConversationActivity? activity;
  final String? latestDescription;
  final SessionExecutionSnapshot? executionSnapshot;
  final bool isRtl;
  final Random? random;
  final DateTime Function()? now;
  final ValueListenable<DateTime>? clock;

  static const List<String> arabicPhrases = [
    'أفكر في الحل الأنسب…',
    'أعمل على إنجاز طلبك…',
    'أقوم بتحليل المعطيات…',
    'أعالج الخطوة التالية…',
    'أتفقد تفاصيل مساحة العمل…',
    'أراجع المعلومات المتاحة…',
    'أنسق الخطوات القادمة…',
    'أحضر الإجابة المناسبة…',
    'أتحقق من صحة النتائج…',
    'أتابع العمل الجاري…',
  ];

  static const List<String> englishPhrases = [
    'Thinking about the best approach…',
    'Working on your request…',
    'Analyzing the context…',
    'Processing the next step…',
    'Checking workspace details…',
    'Reviewing available information…',
    'Coordinating the next action…',
    'Preparing the response…',
    'Verifying the results…',
    'Continuing in-progress work…',
  ];

  static String formatElapsed(Duration elapsed) {
    final totalSeconds = elapsed.inSeconds;
    if (totalSeconds < Duration.secondsPerMinute) {
      return '${totalSeconds}s';
    }
    final totalMinutes = elapsed.inMinutes;
    final remainingSeconds = totalSeconds % Duration.secondsPerMinute;
    if (totalMinutes < Duration.minutesPerHour) {
      return '${totalMinutes}m ${remainingSeconds}s';
    }
    final hours = elapsed.inHours;
    final remainingMinutes = totalMinutes % Duration.minutesPerHour;
    return '${hours}h ${remainingMinutes}m ${remainingSeconds}s';
  }

  @override
  State<ConversationActivityBar> createState() => _ConversationActivityBarState();
}

class _ConversationActivityBarState extends State<ConversationActivityBar> {
  late final Random _random = widget.random ?? Random();
  Timer? _phraseTimer;
  int _phraseIndex = 0;

  @override
  void initState() {
    super.initState();
    _scheduleNextPhrase();
  }

  @override
  void dispose() {
    _phraseTimer?.cancel();
    super.dispose();
  }

  void _scheduleNextPhrase() {
    _phraseTimer?.cancel();
    final seconds = _random.nextInt(8) + 3; // Random duration between 3 and 10 seconds
    _phraseTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      setState(() {
        _phraseIndex = (_phraseIndex + 1) % ConversationActivityBar.englishPhrases.length;
      });
      _scheduleNextPhrase();
    });
  }

  String _currentText(BuildContext context) {
    // Priority 1: Model Reasoning / Thinking (first non-empty line, max 7 words + '...')
    final reasoningText = widget.activity?.event?.text.trim();
    if (reasoningText != null && reasoningText.isNotEmpty) {
      final firstLine = reasoningText.split('\n').firstWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => '',
      ).trim();
      if (firstLine.isNotEmpty) {
        final words = firstLine.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (words.length > 7) {
          return '${words.take(7).join(' ')}...';
        }
        return firstLine;
      }
    }

    // Priority 2: Tool Description / Intent (not shown when model is in thinking/idle state between tools)
    if (widget.activity?.kind != ConversationActivityKind.thinking) {
      final desc = widget.latestDescription?.trim();
      if (desc != null && desc.isNotEmpty) {
        return desc;
      }

      if (widget.activity?.kind == ConversationActivityKind.runningTool && widget.activity?.event != null) {
        final detail = ToolPresentationHelper.getToolDetailSuffix(widget.activity!.event!);
        if (detail.isNotEmpty) {
          final action = ToolPresentationHelper.cleanToolTitle(widget.activity!.event!.toolName ?? '');
          return action == 'Ran' || action.isEmpty ? detail : '$action: $detail';
        }
      }
    }

    // Priority 3: Rotating Conventional Phrases (strictly matches the App's current UI locale)
    final isAppArabic = Localizations.localeOf(context).languageCode == 'ar';
    final phrases = isAppArabic
        ? ConversationActivityBar.arabicPhrases
        : ConversationActivityBar.englishPhrases;
    return phrases[_phraseIndex % phrases.length];
  }

  Widget _buildElapsedText(BuildContext context, ColorScheme colors) {
    if (widget.executionSnapshot?.elapsedMs == null) {
      return const SizedBox.shrink();
    }
    final clock = widget.clock ?? ConversationClockScope.maybeOf(context);
    if (clock != null) {
      return ValueListenableBuilder<DateTime>(
        valueListenable: clock,
        builder: (context, now, _) {
          final elapsed = widget.executionSnapshot!.elapsedAt(now);
          if (elapsed == null) return const SizedBox.shrink();
          return _elapsedTextWidget(ConversationActivityBar.formatElapsed(elapsed), colors);
        },
      );
    }
    final elapsed = widget.executionSnapshot!.elapsedAt(
      widget.now?.call() ?? DateTime.now(),
    );
    if (elapsed == null) return const SizedBox.shrink();
    return _elapsedTextWidget(ConversationActivityBar.formatElapsed(elapsed), colors);
  }

  Widget _elapsedTextWidget(String text, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          text,
          key: const Key('conversation_activity_elapsed'),
          style: GoogleFonts.outfit(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: colors.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = _currentText(context);

    final isDark = theme.brightness == Brightness.dark;
    final containerColor = isDark
        ? colors.surface.withValues(alpha: 0.58)
        : colors.surfaceContainerHigh.withValues(alpha: 0.68);
    final borderColor = colors.outline.withValues(alpha: isDark ? 0.38 : 0.32);

    return Semantics(
      label: 'Session activity: $text',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            decoration: BoxDecoration(
              color: containerColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: borderColor,
                width: 1.0,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 23),
            child: Row(
              mainAxisSize: MainAxisSize.max,
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
                  child: Text(
                    text,
                    key: const Key('conversation_activity_text'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                      color: colors.primary,
                    ),
                  ),
                ),
                _buildElapsedText(context, colors),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
