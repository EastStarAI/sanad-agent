import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:sanad_client/core/theme/app_typography.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

import '../../utils/text_utils.dart';

class AskUserToolTile extends StatelessWidget {
  final CanonicalEvent event;

  const AskUserToolTile({
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

    final output = event.toolOutput;
    final input = event.toolInput;

    // Try decoding the answer list from output
    List<dynamic>? qaList;
    if (output is String) {
      try {
        final decoded = jsonDecode(output);
        if (decoded is List) {
          qaList = decoded;
        }
      } catch (_) {}
    } else if (output is List) {
      qaList = output;
    }

    if (qaList != null && qaList.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: qaList.map((item) {
          if (item is! Map) return const SizedBox.shrink();
          final question = item['question']?.toString() ?? '';
          final answer = item['answer']?.toString() ?? '';
          final questionDirection = TextUtils.getTextDirection(question);
          final answerDirection = TextUtils.getTextDirection(answer);

          return Container(
            margin: const EdgeInsets.symmetric(vertical: 4.0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.15),
              ),
            ),
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  textDirection: questionDirection,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.help_outline_rounded,
                      size: 15,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        question,
                        textDirection: questionDirection,
                        textAlign: questionDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
                        style: AppTypography.text(context,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  textDirection: answerDirection,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 15,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        answer,
                        textDirection: answerDirection,
                        textAlign: answerDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
                        style: AppTypography.text(context,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }).toList(),
      );
    }

    // Fallback if no parsed QA list is available but we have output text
    final fallbackQuestion = input == null ? null : _getQuestionText(input);
    final fallbackAnswer = output?.toString() ?? 'No answer provided.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fallbackQuestion != null) ...[
          Text(
            'Question:',
            style: AppTypography.text(context,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            fallbackQuestion,
            textDirection: TextUtils.getTextDirection(fallbackQuestion),
            textAlign: TextUtils.getTextDirection(fallbackQuestion) == TextDirection.rtl
                ? TextAlign.right
                : TextAlign.left,
            style: AppTypography.text(context, fontSize: 13),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          'User Answer:',
          style: AppTypography.text(context,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          fallbackAnswer,
          textDirection: TextUtils.getTextDirection(fallbackAnswer),
          textAlign: TextUtils.getTextDirection(fallbackAnswer) == TextDirection.rtl ? TextAlign.right : TextAlign.left,
          style: AppTypography.text(context,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  String _getQuestionText(dynamic input) {
    if (input is Map) {
      final qList = input['questions'];
      if (qList is List && qList.isNotEmpty) {
        final firstQ = qList.first;
        if (firstQ is Map) {
          return firstQ['question']?.toString() ?? '';
        }
      }
      return input['question']?.toString() ?? input.toString();
    }
    return input.toString();
  }

  Widget _buildRunningIndicator(BuildContext context) {
    return const SizedBox.shrink();
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
        event.text.isNotEmpty ? event.text : (event.toolOutput?.toString() ?? 'Clarifying question failed.'),
        style: AppTypography.mono(fontSize: 11, color: errorColor),
      ),
    );
  }
}
