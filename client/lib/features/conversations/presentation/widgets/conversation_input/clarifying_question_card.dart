import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/theme/app_typography.dart';

import '../../../../../utils/app_platform.dart';
import '../../../domain/models/device_suspended_request.dart';
import '../../bloc/conversation_input_cubit.dart';
import '../../utils/text_utils.dart';
import '../multiline_submission_shortcuts.dart';

class ClarifyingQuestionCard extends StatefulWidget {
  final DeviceSuspendedRequest request;
  final Color borderColor;

  const ClarifyingQuestionCard({
    super.key,
    required this.request,
    required this.borderColor,
  });

  @override
  State<ClarifyingQuestionCard> createState() => _ClarifyingQuestionCardState();
}

class _ClarifyingQuestionCardState extends State<ClarifyingQuestionCard> {
  final TextEditingController _clarifyingAnswerController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  int _currentQuestionIndex = 0;
  final Map<int, String> _userAnswers = {};
  bool _customInputMode = false;

  @override
  void initState() {
    super.initState();
    // Auto-request focus for key detection on desktop
    if (!AppPlatform.isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant ClarifyingQuestionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.requestId != widget.request.requestId) {
      _resetRequestState();
      if (!AppPlatform.isMobile) {
        _focusNode.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    _clarifyingAnswerController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _resetRequestState() {
    _currentQuestionIndex = 0;
    _userAnswers.clear();
    _customInputMode = false;
    _clarifyingAnswerController.clear();
  }

  bool get _isCustomAnswerVisible {
    if (_customInputMode) return true;
    final questions = widget.request.questions;
    if (_currentQuestionIndex < 0 || _currentQuestionIndex >= questions.length) return false;
    final options = questions[_currentQuestionIndex]['options'];
    return options is! List || options.isEmpty;
  }

  void _submitCustomAnswer() {
    final text = _clarifyingAnswerController.text.trim();
    if (text.isEmpty) return;
    unawaited(_handleAnswerSelected(widget.request, text));
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (AppPlatform.isMobile) {
      return KeyEventResult.ignored;
    }

    if (_isCustomAnswerVisible) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      final character = event.character;
      final logicalKey = event.logicalKey;

      final index = _matchDigit(character, logicalKey);
      if (index != null) {
        _triggerOption(index);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  int? _matchDigit(String? character, LogicalKeyboardKey logicalKey) {
    if (character == '1' || character == '١') return 0;
    if (character == '2' || character == '٢') return 1;
    if (character == '3' || character == '٣') return 2;
    if (character == '4' || character == '٤') return 3;
    if (character == '5' || character == '٥') return 4;

    if (logicalKey == LogicalKeyboardKey.digit1 || logicalKey == LogicalKeyboardKey.numpad1) return 0;
    if (logicalKey == LogicalKeyboardKey.digit2 || logicalKey == LogicalKeyboardKey.numpad2) return 1;
    if (logicalKey == LogicalKeyboardKey.digit3 || logicalKey == LogicalKeyboardKey.numpad3) return 2;
    if (logicalKey == LogicalKeyboardKey.digit4 || logicalKey == LogicalKeyboardKey.numpad4) return 3;
    if (logicalKey == LogicalKeyboardKey.digit5 || logicalKey == LogicalKeyboardKey.numpad5) return 4;

    return null;
  }

  void _triggerOption(int index) {
    final questionsList = widget.request.questions;
    if (_currentQuestionIndex >= questionsList.length) return;

    final currentQuestionData = questionsList[_currentQuestionIndex];
    final optionsRaw = currentQuestionData['options'];
    final List<String> options = [];
    if (optionsRaw is List) {
      options.addAll(optionsRaw.map((o) => o.toString()));
    }

    final hasPredefinedOptions = options.isNotEmpty;

    if (hasPredefinedOptions) {
      if (index < options.length) {
        unawaited(_handleAnswerSelected(widget.request, options[index]));
      } else if (index == options.length) {
        // Custom Option (e.g. 4)
        setState(() {
          _customInputMode = true;
          _clarifyingAnswerController.clear();
        });
      } else if (index == options.length + 1) {
        // Skip Option (e.g. 5)
        unawaited(_handleAnswerSelected(widget.request, 'user skipped this question'));
      }
    } else {
      // No predefined options: Custom mode only
      if (index == 0) {
        // Skip option is the only numbered button (1)
        unawaited(_handleAnswerSelected(widget.request, 'user skipped this question'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final questionsList = widget.request.questions;
    if (questionsList.isEmpty) {
      return const SizedBox.shrink();
    }

    if (_currentQuestionIndex >= questionsList.length) {
      _currentQuestionIndex = questionsList.length - 1;
    }
    if (_currentQuestionIndex < 0) {
      _currentQuestionIndex = 0;
    }

    final currentQuestionData = questionsList[_currentQuestionIndex];
    final questionText = currentQuestionData['question']?.toString() ?? 'Clarifying Question';
    final questionDirection = TextUtils.getTextDirection(questionText);
    final optionsRaw = currentQuestionData['options'];
    final List<String> options = [];
    if (optionsRaw is List) {
      options.addAll(optionsRaw.map((o) => o.toString()));
    }

    final isCustomMode = _customInputMode || options.isEmpty;
    final showNumbers = !AppPlatform.isMobile;

    final cardContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, size: 16, color: colorScheme.secondary),
                const SizedBox(width: 8),
                Text(
                  'Clarifying Question (${_currentQuestionIndex + 1} of ${questionsList.length})',
                  style: AppTypography.text(context,
                    color: colorScheme.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            TextButton(
              key: const Key('dismiss_all_clarifying_questions_btn'),
              onPressed: () => _handleDismissAll(context, widget.request),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Dismiss',
                style: AppTypography.text(context,
                  color: colorScheme.onSurface.withValues(alpha: 0.5),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: widget.borderColor),
          ),
          child: Text(
            questionText,
            textDirection: questionDirection,
            textAlign: questionDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (!isCustomMode) ...[
          if (options.isNotEmpty) ...[
            _buildPermissionAction(
              context,
              label: showNumbers ? '1  ${options[0]}' : options[0],
              key: const Key('predefined_option_1'),
              onTap: () => _handleAnswerSelected(widget.request, options[0]),
            ),
            const SizedBox(height: 8),
          ],
          if (options.length > 1) ...[
            _buildPermissionAction(
              context,
              label: showNumbers ? '2  ${options[1]}' : options[1],
              key: const Key('predefined_option_2'),
              onTap: () => _handleAnswerSelected(widget.request, options[1]),
            ),
            const SizedBox(height: 8),
          ],
          if (options.length > 2) ...[
            _buildPermissionAction(
              context,
              label: showNumbers ? '3  ${options[2]}' : options[2],
              key: const Key('predefined_option_3'),
              onTap: () => _handleAnswerSelected(widget.request, options[2]),
            ),
            const SizedBox(height: 8),
          ],
          _buildPermissionAction(
            context,
            label: showNumbers ? '${options.length + 1}  Type custom answer...' : 'Type custom answer...',
            key: const Key('custom_answer_option'),
            onTap: () {
              setState(() {
                _customInputMode = true;
                _clarifyingAnswerController.clear();
              });
            },
          ),
          const SizedBox(height: 8),
          _buildPermissionAction(
            context,
            label: showNumbers ? '${options.length + 2}  Skip this question' : 'Skip this question',
            key: const Key('skip_this_question_btn'),
            onTap: () => _handleAnswerSelected(widget.request, 'user skipped this question'),
          ),
        ] else ...[
          MultilineSubmissionShortcuts(
            controller: _clarifyingAnswerController,
            onSubmit: _submitCustomAnswer,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _clarifyingAnswerController,
              builder: (context, value, _) {
                final textDirection = TextUtils.getTextDirection(value.text);
                return TextField(
                  key: const Key('clarifying_question_input'),
                  controller: _clarifyingAnswerController,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 2,
                  maxLines: 8,
                  textDirection: textDirection,
                  textAlign: textDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
                  style: AppTypography.text(context, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Type your detailed answer here...',
                    hintStyle: AppTypography.text(context,
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: widget.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _buildPermissionAction(
            context,
            label: 'Submit Custom Answer',
            primary: true,
            key: const Key('submit_question_answer_btn'),
            onTap: _submitCustomAnswer,
          ),
          const SizedBox(height: 8),
          _buildPermissionAction(
            context,
            label: 'Skip this question',
            key: const Key('skip_this_question_btn'),
            onTap: () => _handleAnswerSelected(widget.request, 'user skipped this question'),
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildPermissionAction(
              context,
              label: 'Back to options',
              key: const Key('back_to_options_btn'),
              onTap: () {
                setState(() {
                  _customInputMode = false;
                });
              },
            ),
          ],
        ],
        if (_currentQuestionIndex > 0) ...[
          const SizedBox(height: 8),
          _buildPermissionAction(
            context,
            label: 'Back to previous question',
            key: const Key('back_to_previous_question_btn'),
            onTap: () {
              setState(() {
                _currentQuestionIndex--;
                _customInputMode = false;
              });
            },
          ),
        ],
      ],
    );

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: cardContent,
    );
  }

  Future<void> _handleDismissAll(
    BuildContext context,
    DeviceSuspendedRequest request,
  ) async {
    final questionsList = request.questions;
    final answersPayload = <Map<String, String>>[];
    for (var i = 0; i < questionsList.length; i += 1) {
      final qText = questionsList[i]['question']?.toString() ?? '';
      answersPayload.add({
        'question': qText,
        'answer': 'user skipped this questions',
      });
    }

    await context.read<ConversationInputCubit>().answerPendingSuspendedRequest(
      request: request,
      answer: jsonEncode(answersPayload),
    );

    if (!mounted) return;
    setState(_resetRequestState);
  }

  Future<void> _handleAnswerSelected(
    DeviceSuspendedRequest request,
    String answerText,
  ) async {
    final questionsList = request.questions;
    _userAnswers[_currentQuestionIndex] = answerText;

    if (_currentQuestionIndex < questionsList.length - 1) {
      setState(() {
        _currentQuestionIndex++;
        _customInputMode = false;
        _clarifyingAnswerController.clear();
      });
      return;
    }

    final answersPayload = <Map<String, String>>[];
    for (var i = 0; i < questionsList.length; i += 1) {
      final qText = questionsList[i]['question']?.toString() ?? '';
      final ansText = _userAnswers[i] ?? '';
      answersPayload.add({
        'question': qText,
        'answer': ansText,
      });
    }

    await context.read<ConversationInputCubit>().answerPendingSuspendedRequest(
      request: request,
      answer: jsonEncode(answersPayload),
    );

    if (!mounted) return;
    setState(_resetRequestState);
  }

  Widget _buildPermissionAction(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    Key? key,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textDirection = TextUtils.getTextDirection(label);
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: primary
              ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: primary ? colorScheme.primary.withValues(alpha: 0.25) : colorScheme.outline.withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          label,
          textDirection: textDirection,
          textAlign: textDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
          style: AppTypography.text(context,
            color: colorScheme.onSurface,
            fontSize: 13,
            fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
