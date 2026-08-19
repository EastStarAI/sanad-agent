import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/utils/format_utils.dart';
import 'package:sanad_client/utils/link_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/plan_task_list.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/utils/tool_presentation_helper.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/file_tool_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/terminal_tool_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/web_tool_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/ask_user_tool_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/generic_tool_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/skill_load_tool_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/app_markdown_renderer.dart';

enum ToolWaitingIndicator { none, permission, question }

class EventTile extends StatefulWidget {
  final CanonicalEvent event;
  final bool? isExpanded;
  final ValueChanged<bool>? onToggleExpanded;
  final Future<void> Function(String requestId)? onCancelPendingSteer;
  final bool isCancellingPendingSteer;
  final bool canReplay;
  final bool isEditing;
  final bool isReplayPending;
  final TextEditingController? editController;
  final VoidCallback? onBeginEdit;
  final VoidCallback? onCancelEdit;
  final Future<void> Function()? onSubmitEdit;
  final Future<void> Function()? onRetry;
  final ToolWaitingIndicator waitingIndicator;

  const EventTile({
    super.key,
    required this.event,
    this.isExpanded,
    this.onToggleExpanded,
    this.onCancelPendingSteer,
    this.isCancellingPendingSteer = false,
    this.canReplay = false,
    this.isEditing = false,
    this.isReplayPending = false,
    this.editController,
    this.onBeginEdit,
    this.onCancelEdit,
    this.onSubmitEdit,
    this.onRetry,
    this.waitingIndicator = ToolWaitingIndicator.none,
  });

  @override
  State<EventTile> createState() => _EventTileState();
}

class _EventTileState extends State<EventTile> with TickerProviderStateMixin {
  bool _isExpanded = true;
  late AnimationController _expansionController;
  late Animation<double> _expansionAnimation;
  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initExpansionState();
  }

  void _initAnimations() {
    _expansionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _expansionController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed || status == AnimationStatus.completed) {
        if (mounted) {
          setState(() {});
        }
      }
    });

    _expansionAnimation = CurvedAnimation(
      parent: _expansionController,
      curve: Curves.easeInOut,
    );
  }

  void _initExpansionState() {
    if (widget.event.toolName == 'system_ask_user') {
      _isExpanded = true;
    } else if (widget.isExpanded != null) {
      _isExpanded = widget.isExpanded!;
    } else {
      // Default fallback if no external state is provided
      _isExpanded = widget.event.kind == EventKind.userMessage || widget.event.kind == EventKind.finalAnswer;
    }

    if (_isExpanded) {
      _expansionController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant EventTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.event.toolName == 'system_ask_user') {
      _setExpanded(true, notifyParent: false, rebuild: false);
      return;
    }

    if (widget.isExpanded != null && widget.isExpanded != oldWidget.isExpanded) {
      _setExpanded(
        widget.isExpanded!,
        notifyParent: false,
        rebuild: false,
      );
    }
  }

  @override
  void dispose() {
    _expansionController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    _setExpanded(!_isExpanded);
  }

  void _setExpanded(
    bool expanded, {
    bool notifyParent = true,
    bool rebuild = true,
  }) {
    if (_isExpanded == expanded) return;

    void apply() {
      _isExpanded = expanded;
      if (expanded) {
        unawaited(_expansionController.forward());
      } else {
        unawaited(_expansionController.reverse());
      }
    }

    if (rebuild) {
      setState(apply);
    } else {
      apply();
    }
    if (notifyParent) widget.onToggleExpanded?.call(expanded);
  }

  // ── Build Methods ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    switch (widget.event.kind) {
      case EventKind.finalAnswer:
        return _buildPrimaryResponse(context, showFinalFooter: true);
      case EventKind.thinking:
        // Streaming assistant text renders exactly like the final answer
        // (full-width markdown, copy action) but without the final footer and
        // without the transient "Thinking"/"Thoughts" header label.
        return _buildPrimaryResponse(context, showCopyAction: true);
      case EventKind.reasoning:
        // Provider reasoning is a transient, live-only artifact rendered like
        // a running tool row: a small spinner, a dim "Thinking:" label, and
        // the first few content words. It is removed from state as soon as a
        // successor event arrives, so it never appears from history.
        return _buildReasoningRow(context);
      case EventKind.userMessage:
        return UserMessageTile(
          event: widget.event,
          onCancelPendingSteer: widget.onCancelPendingSteer,
          isCancellingPendingSteer: widget.isCancellingPendingSteer,
          canReplay: widget.canReplay,
          isEditing: widget.isEditing,
          isReplayPending: widget.isReplayPending,
          editController: widget.editController,
          onBeginEdit: widget.onBeginEdit,
          onCancelEdit: widget.onCancelEdit,
          onSubmitEdit: widget.onSubmitEdit,
          onRetry: widget.onRetry,
        );
      case EventKind.informational:
        return _buildInformational(context);
      default:
        return _buildCollapsibleEvent(context);
    }
  }

  Widget _buildInformational(BuildContext context) {
    return Semantics(
      label: 'Session route changed',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.swap_horiz,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.event.text,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrimaryResponse(
    BuildContext context, {
    bool showFinalFooter = false,
    bool showCopyAction = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPrimaryMarkdown(context),
          if (showFinalFooter) ...[
            const SizedBox(height: 8),
            _buildFinalAnswerFooter(context),
          ] else if (showCopyAction) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: CopyButton(
                text: widget.event.text,
                successMessage: 'Content copied to clipboard',
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Transient provider-reasoning row styled like a running tool call:
  /// a small spinner, a dim `Thinking:` prefix, then the first few words of
  /// the streamed reasoning content. Live-only; never rendered from history.
  Widget _buildReasoningRow(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    final isRunning = widget.event.status == EventStatus.running;
    final preview = _firstWords(widget.event.text, 5);

    return Semantics(
      label: 'Thinking',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 12.0),
        child: Row(
          children: [
            if (isRunning)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            else
              Icon(
                Icons.psychology_outlined,
                size: 18,
                color: color.withValues(alpha: 0.4),
              ),
            const SizedBox(width: 8),
            Flexible(
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: GoogleFonts.outfit(fontSize: 13, letterSpacing: 0.5),
                    children: [
                      TextSpan(
                        text: 'Thinking: ',
                        style: TextStyle(
                          color: color.withValues(alpha: 0.4),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (preview.isNotEmpty)
                        TextSpan(
                          text: preview,
                          style: TextStyle(
                            color: isRunning ? Theme.of(context).colorScheme.primary : color.withValues(alpha: 0.55),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _firstWords(String text, int count) {
    final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '';
    return words.take(count).join(' ');
  }

  Widget _buildPrimaryMarkdown(BuildContext context) {
    return SelectionArea(
      child: Directionality(
        textDirection: TextUtils.getTextDirection(widget.event.text),
        child: SizedBox(
          key: Key('primary_markdown_${widget.event.kind.name}'),
          width: double.infinity,
          child: AppMarkdownRenderer(
            data: widget.event.text,
            isFinal: true,
            onTapLink: _onTapLink,
          ),
        ),
      ),
    );
  }

  Widget _buildFinalAnswerFooter(BuildContext context) {
    final metaText = EventMetadataFormatter.responseMetaText(
      widget.event,
      context,
    );
    final timestampText = EventMetadataFormatter.timestampText(
      widget.event.timestamp,
      context,
    );
    return Row(
      children: [
        if (metaText.isNotEmpty || timestampText.isNotEmpty)
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                [
                  timestampText,
                  metaText,
                ].where((part) => part.isNotEmpty).join('  •  '),
                style: GoogleFonts.roboto(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                  fontSize: 11,
                ),
              ),
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: 8),
        CopyButton(
          text: widget.event.text,
          successMessage: 'Answer copied to clipboard',
        ),
      ],
    );
  }

  Widget _buildCollapsibleEvent(BuildContext context) {
    if (widget.event.toolName == 'system_ask_user') {
      return _buildEventBody();
    }

    final bool isToolLike = widget.event.kind == EventKind.toolCall || widget.event.kind == EventKind.plan;
    final bool canExpand = isToolLike;

    return Column(
      children: [
        _buildEventHeader(canExpand),
        _buildEventBody(),
      ],
    );
  }

  // ── Sub-Components ────────────────────────────────────────────────────────

  Widget _buildEventHeader(bool canExpand) {
    final bool isError = widget.event.status == EventStatus.error;
    final titleText = ToolPresentationHelper.getEventTitle(widget.event);
    final titleDetail = widget.event.kind == EventKind.toolCall
        ? ToolPresentationHelper.getToolDetailSuffix(widget.event)
        : '';
    final textDirection = TextUtils.getTextDirection(
      titleDetail.isNotEmpty ? titleDetail : titleText,
    );

    final Widget header = InkWell(
      onTap: canExpand ? _toggleExpanded : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 12.0),
        child: Directionality(
          textDirection: textDirection,
          child: Row(
            children: [
              _buildStatusIndicator(),
              const SizedBox(width: 8),
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: ToolPresentationHelper.buildTitleWidget(
                        context: context,
                        event: widget.event,
                        titleColor: _getTitleColor(context),
                        textDirection: textDirection,
                      ),
                    ),
                    if (canExpand) ...[
                      const SizedBox(width: 4),
                      RotationTransition(
                        turns: _expansionAnimation.drive(Tween<double>(begin: 0.0, end: 0.25)),
                        child: Icon(
                          Icons.chevron_right,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ],
                    if (isError) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.error_outline_rounded,
                        size: 14,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return header;
  }

  Widget _buildEventBody() {
    final isAskUserRunning = widget.event.toolName == 'system_ask_user' && widget.event.status == EventStatus.running;
    final hasContent =
        (widget.event.text.trim().isNotEmpty ||
            widget.event.kind == EventKind.toolCall ||
            widget.event.kind == EventKind.plan) &&
        !isAskUserRunning;

    if (!hasContent) return const SizedBox.shrink();

    final isClosed = !_isExpanded && _expansionController.isDismissed;

    return SizeTransition(
      sizeFactor: _expansionAnimation,
      alignment: AlignmentDirectional.topStart,
      child: isClosed
          ? const SizedBox.shrink()
          : Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectionArea(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 500),
                    child: SingleChildScrollView(
                      child: _buildEventContent(),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildStatusIndicator() {
    if (widget.waitingIndicator != ToolWaitingIndicator.none) {
      final isQuestion = widget.waitingIndicator == ToolWaitingIndicator.question;
      return Semantics(
        label: isQuestion ? 'Waiting for your answer' : 'Waiting for permission',
        child: Icon(
          isQuestion ? Icons.help_outline_rounded : Icons.shield_outlined,
          key: Key(isQuestion ? 'tool_waiting_question_icon' : 'tool_waiting_permission_icon'),
          size: 18,
          color: Theme.of(context).colorScheme.tertiary,
        ),
      );
    }
    if (widget.event.status == EventStatus.running && widget.event.toolName != 'system_ask_user') {
      return Padding(
        padding: const EdgeInsets.all(2),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            key: const Key('tool_running_progress_indicator'),
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    final rawName = widget.event.toolName ?? '';
    final cleanName = ToolPresentationHelper.cleanToolTitle(rawName);
    if (widget.event.kind == EventKind.toolCall) {
      if (cleanName == 'Read' || cleanName == 'Write' || cleanName == 'Edit') {
        final fileName = ToolPresentationHelper.getToolDetailSuffix(widget.event);
        if (fileName.isNotEmpty) {
          return FileExtensionIcon(fileName: fileName, size: 18);
        }
      } else if (cleanName == 'Ran') {
        return const FileExtensionIcon(fileName: 'terminal', size: 18);
      } else if (cleanName == 'Search' || cleanName == 'Grep') {
        return const FileExtensionIcon(fileName: 'search', size: 18);
      }
    }

    final (icon, color) = ToolPresentationHelper.getEventIconData(context, widget.event);
    return Icon(icon, size: 18, color: color.withValues(alpha: 0.7));
  }

  Widget _buildEventContent() {
    switch (widget.event.kind) {
      case EventKind.toolCall:
        return _buildToolContent();
      case EventKind.plan:
        return PlanTaskList(plan: widget.event.plan);
      default:
        return Directionality(
          textDirection: TextUtils.getTextDirection(widget.event.text),
          child: AppMarkdownRenderer(
            data: widget.event.text,
            isFinal: false,
            onTapLink: _onTapLink,
          ),
        );
    }
  }

  Widget _buildToolContent() {
    final toolName = widget.event.toolName ?? '';
    final details = ToolPresentationHelper.getToolDetailSuffix(widget.event);

    // If we could not extract any suffix details, fall back to the old GenericToolTile (input/output JSON)
    if (details.isEmpty) {
      return GenericToolTile(event: widget.event);
    }

    final category = ToolPresentationHelper.cleanToolTitle(toolName);

    switch (category) {
      case 'Read':
      case 'Write':
      case 'Edit':
      case 'Search':
      case 'Grep':
        return FileToolTile(
          event: widget.event,
          isFullyExpanded: _isExpanded && _expansionController.isCompleted,
        );
      case 'Ran':
        return TerminalToolTile(event: widget.event);
      case 'Search Web':
      case 'Fetch':
        return WebToolTile(event: widget.event);
      case 'Ask':
        return AskUserToolTile(event: widget.event);
      case 'Skill Load':
        return SkillLoadToolTile(event: widget.event);
      // todo : Memory presentation remains suspended until its UI is fixed.
      // case 'Memory':
      //   return MemoryToolTile(event: widget.event);
      default:
        return GenericToolTile(event: widget.event);
    }
  }

  void _onTapLink(String text, String? href, String title) {
    unawaited(openExternalUrl(href));
  }

  // ── Helpers & Data ────────────────────────────────────────────────────────

  Color _getTitleColor(BuildContext context) {
    if (widget.event.status == EventStatus.running) return Theme.of(context).colorScheme.primary;
    if (widget.event.kind == EventKind.error || widget.event.status == EventStatus.error) {
      return Theme.of(context).colorScheme.error;
    }
    return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);
  }
}
