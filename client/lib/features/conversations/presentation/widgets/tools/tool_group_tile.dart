import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';

class ToolGroupTile extends StatefulWidget {
  const ToolGroupTile({
    super.key,
    required this.item,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.expandedChildEventIds,
    required this.onChildToggleExpanded,
  });

  final ConversationTimelineItem item;
  final bool isExpanded;
  final ValueChanged<bool> onToggleExpanded;
  final Set<String> expandedChildEventIds;
  final void Function(String eventId, bool expanded) onChildToggleExpanded;

  @override
  State<ToolGroupTile> createState() => _ToolGroupTileState();
}

class _ToolGroupTileState extends State<ToolGroupTile> with SingleTickerProviderStateMixin {
  static const double _maxBodyHeight = 500;
  static const double _bottomThreshold = 1;

  final ScrollController _scrollController = ScrollController();
  late final AnimationController _expansionController;
  late final Animation<double> _expansionAnimation;
  bool _isFollowing = true;
  bool _hasManualScroll = false;

  @override
  void initState() {
    super.initState();
    _expansionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _expansionAnimation = CurvedAnimation(
      parent: _expansionController,
      curve: Curves.easeInOut,
    );
    _expansionController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) setState(() {});
    });
    _expansionController.value = widget.isExpanded ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant ToolGroupTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != oldWidget.isExpanded) {
      if (widget.isExpanded) {
        unawaited(_expansionController.forward());
      } else {
        unawaited(_expansionController.reverse());
      }
    }
    if (widget.isExpanded && _isFollowing && _contentRevision(widget.item) != _contentRevision(oldWidget.item)) {
      _scheduleFollowBottom();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _expansionController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    final expanded = !widget.isExpanded;
    widget.onToggleExpanded(expanded);
    if (expanded && _isFollowing) _scheduleFollowBottom();
  }

  void _scheduleFollowBottom({int remainingFrames = 3}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isExpanded || !_isFollowing || !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      if (remainingFrames > 1) {
        _scheduleFollowBottom(remainingFrames: remainingFrames - 1);
      }
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification && notification.direction != ScrollDirection.idle) {
      _hasManualScroll = true;
      _isFollowing = false;
    }
    if (notification is ScrollEndNotification && _hasManualScroll) {
      _hasManualScroll = false;
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        _isFollowing = position.maxScrollExtent - position.pixels <= _bottomThreshold;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.item.toolSummary!;

    return Column(
      children: [
        InkWell(
          key: Key('tool_group_header_${widget.item.id}'),
          onTap: _toggleExpanded,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 4,
              horizontal: 12,
            ),
            child: Row(
              children: [
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: _buildTitleSummary(context, summary)),
                      const SizedBox(width: 4),
                      RotationTransition(
                        turns: _expansionAnimation.drive(
                          Tween<double>(begin: 0, end: 0.25),
                        ),
                        child: Icon(
                          Icons.chevron_right,
                          key: Key('tool_group_chevron_${widget.item.id}'),
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.4),
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SizeTransition(
          sizeFactor: _expansionAnimation,
          alignment: AlignmentDirectional.topStart,
          child: widget.isExpanded || !_expansionController.isDismissed
              ? Container(
                  key: Key('tool_group_body_${widget.item.id}'),
                  margin: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 16,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).scaffoldBackgroundColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.05),
                    ),
                  ),
                  child: Padding(
                    key: Key('tool_group_content_padding_${widget.item.id}'),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: SelectionArea(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: _maxBodyHeight,
                        ),
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _handleScrollNotification,
                          child: SingleChildScrollView(
                            key: Key('tool_group_scroll_${widget.item.id}'),
                            controller: _scrollController,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final event in widget.item.events)
                                  EventTile(
                                    key: ValueKey(
                                      'tool-group-child:${event.id}',
                                    ),
                                    event: event,
                                    isExpanded: widget.expandedChildEventIds.contains(event.id),
                                    onToggleExpanded: (expanded) => widget.onChildToggleExpanded(
                                      event.id,
                                      expanded,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildTitleSummary(BuildContext context, ToolGroupSummary summary) {
    return _buildSummary(
      context,
      summary,
      fontSize: 13,
      letterSpacing: 0.5,
    );
  }

  Widget _buildSummary(
    BuildContext context,
    ToolGroupSummary summary, {
    required double fontSize,
    required double letterSpacing,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseStyle = GoogleFonts.outfit(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      fontSize: fontSize,
      fontWeight: FontWeight.normal,
      letterSpacing: letterSpacing,
    );
    final addedStyle = baseStyle.copyWith(
      color: isDark ? Colors.green.shade300 : Colors.green.shade900,
    );
    final removedStyle = baseStyle.copyWith(
      color: isDark ? Colors.red.shade300 : Colors.red.shade900,
    );
    final metrics = summary.headerMetrics;
    final modifiedFileMetric = metrics.where((metric) => metric.key == 'modified-files').firstOrNull;
    final regularMetrics = metrics.where((metric) => metric.key != 'modified-files').toList(growable: false);
    final hasLineImpact = summary.addedLines > 0 || summary.removedLines > 0;

    Widget buildLineImpact() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (summary.addedLines > 0)
          _AnimatedMetric(
            key: const ValueKey('added-lines'),
            metricKey: 'added-lines',
            value: summary.addedLines,
            prefix: '+',
            style: addedStyle,
          ),
        if (summary.addedLines > 0 && summary.removedLines > 0) const SizedBox(width: 2),
        if (summary.removedLines > 0)
          _AnimatedMetric(
            key: const ValueKey('removed-lines'),
            metricKey: 'removed-lines',
            value: summary.removedLines,
            prefix: '-',
            style: removedStyle,
          ),
      ],
    );

    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var index = 0; index < regularMetrics.length; index++) ...[
          if (index > 0) Text('·', style: baseStyle),
          _AnimatedMetric(
            key: ValueKey(regularMetrics[index].key),
            metricKey: regularMetrics[index].key,
            value: regularMetrics[index].value,
            suffix: regularMetrics[index].suffix,
            style: baseStyle,
          ),
        ],
        if (modifiedFileMetric != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (regularMetrics.isNotEmpty) ...[
                Text('·', style: baseStyle),
                const SizedBox(width: 6),
              ],
              _AnimatedMetric(
                key: ValueKey(modifiedFileMetric.key),
                metricKey: modifiedFileMetric.key,
                value: modifiedFileMetric.value,
                suffix: modifiedFileMetric.suffix,
                style: baseStyle,
              ),
              if (hasLineImpact) ...[
                const SizedBox(width: 6),
                buildLineImpact(),
              ],
            ],
          )
        else if (hasLineImpact)
          buildLineImpact(),
        if (metrics.isEmpty && !hasLineImpact) Text('Tools', style: baseStyle),
      ],
    );
  }

  String _contentRevision(ConversationTimelineItem item) => item.events
      .map(
        (event) => '${event.id}:${event.status.name}:${event.toolOutput.hashCode}',
      )
      .join('|');
}

class _AnimatedMetric extends StatefulWidget {
  const _AnimatedMetric({
    super.key,
    required this.metricKey,
    required this.value,
    required this.style,
    this.prefix = '',
    this.suffix = '',
  });

  final String metricKey;
  final int value;
  final String prefix;
  final String suffix;
  final TextStyle style;

  @override
  State<_AnimatedMetric> createState() => _AnimatedMetricState();
}

class _AnimatedMetricState extends State<_AnimatedMetric> {
  late int _previousValue;

  @override
  void initState() {
    super.initState();
    _previousValue = widget.value;
  }

  @override
  void didUpdateWidget(covariant _AnimatedMetric oldWidget) {
    super.didUpdateWidget(oldWidget);
    _previousValue = oldWidget.value;
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.metricKey),
      tween: Tween<double>(
        begin: _previousValue.toDouble(),
        end: widget.value.toDouble(),
      ),
      duration: const Duration(milliseconds: 750),
      curve: Curves.easeOutCubic,
      builder: (context, animatedValue, _) => Text(
        '${widget.prefix}${animatedValue.round()}${widget.suffix}',
        style: widget.style,
      ),
    );
  }
}
