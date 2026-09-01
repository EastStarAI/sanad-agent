import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'dart:async';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/features/home/presentation/widgets/new_chat_view.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input_panel.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_activity_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/tool_group_tile.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/utils/toast_utils.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../widgets/sidebar/sidebar_composition.dart';

/// Displays the live conversation timeline as a stream of `CanonicalEvent`s
/// sourced from the active conversation repository.
///
/// Scroll behaviour
/// ─────────────────
/// • Opening active work → starts at the latest event.
/// • Opening an idle session → restores its last manual viewport anchor, then
///   falls back to the last user message.
/// • Eligible tail content follows only after reaching the composer boundary.
/// • The first user message is top-anchored; later user messages are revealed
///   only by the minimum direct offset needed above the composer.
class BrainActivityView extends StatefulWidget {
  final Stream<List<CanonicalEvent>>? messagesStream;
  final List<CanonicalEvent> initialMessages;
  final void Function(String, {MessageDeliveryIntent intent}) onSendMessage;
  final VoidCallback? onStop;
  final String? sessionId;
  final String? composerSessionId;
  final String? initialViewportAnchorEventId;
  final bool followLatestOnOpen;
  final ValueChanged<String>? onViewportAnchorChanged;
  final ConversationVisualState visualState;
  final bool activityEligible;
  final SessionExecutionSnapshot? executionSnapshot;
  final Set<String> pendingSteerCancellationRequestIds;
  final bool hasOlderHistory;
  final bool isOlderHistoryLoading;
  final String? olderHistoryError;
  final Future<void> Function()? onLoadOlderHistory;
  final Future<void> Function(String eventId)? onLoadAnchoredHistory;

  const BrainActivityView({
    super.key,
    this.messagesStream,
    this.initialMessages = const [],
    required this.onSendMessage,
    this.onStop,
    this.sessionId,
    this.composerSessionId,
    this.initialViewportAnchorEventId,
    this.followLatestOnOpen = false,
    this.onViewportAnchorChanged,
    this.visualState = ConversationVisualState.newConversation,
    this.activityEligible = false,
    this.executionSnapshot,
    this.pendingSteerCancellationRequestIds = const {},
    this.hasOlderHistory = false,
    this.isOlderHistoryLoading = false,
    this.olderHistoryError,
    this.onLoadOlderHistory,
    this.onLoadAnchoredHistory,
  });

  @override
  State<BrainActivityView> createState() => _BrainActivityViewState();
}

class _BrainActivityViewState extends State<BrainActivityView> {
  static const double _bottomFollowThreshold = 1;
  static const Duration _newAgentFollowScrollDuration = Duration(milliseconds: 280);
  static const int _maxAutomaticHistoryFillPages = 3;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _conversationAnchorKey = GlobalKey();
  final GlobalKey _scrollViewportKey = GlobalKey();
  final GlobalKey _composerKey = GlobalKey();
  final Map<String, GlobalKey> _eventViewportKeys = {};
  double _composerHeight = 140.0;
  bool _hasMeasuredComposer = false;
  double _visibleContentTopInset = 0;
  double _visibleContentBottomInset = 0;
  int _scrollGeneration = 0;
  bool _awaitingLocalUserMessage = false;
  bool _hasPendingManualScrollAnchor = false;
  bool _isOpeningSession = true;
  List<CanonicalEvent> _messages = [];
  List<ConversationTimelineItem> _timelineItems = [];
  StreamSubscription<List<CanonicalEvent>>? _messagesSubscription;
  final Set<String> _expandedEventIds = {};
  final Set<String> _pendingEntranceEventIds = {};
  TextEditingController? _editController;
  String? _editingEventId;
  String? _replayPendingEventId;
  int _openAnchorIndex = 0;
  bool _openAtTail = false;
  bool _hasResolvedOpeningTailAlignment = true;
  double? _openingTailAnchorPixels;
  bool _autoFollowEligible = false;
  bool _isFollowingTail = false;
  String? _attemptedAnchorEventId;
  int _automaticHistoryFillPages = 0;

  @override
  void initState() {
    super.initState();
    _messages = List.from(widget.initialMessages);
    _timelineItems = projectConversationTimeline(
      _messages,
      activityEligible: widget.activityEligible,
    );
    _prepareInitialSessionPosition();
    _isOpeningSession = _timelineItems.isEmpty;
    _subscribeToMessages();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateComposerHeight();
      _requestMissingSavedAnchor();
      _maybeAutoFillHistory();
    });
  }

  @override
  void dispose() {
    unawaited(_messagesSubscription?.cancel());
    _editController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateComposerHeight() {
    if (!mounted) return;
    final renderBox = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final height = renderBox.size.height;
    final isFirstMeasurement = !_hasMeasuredComposer;
    if (!isFirstMeasurement && height == _composerHeight) return;

    setState(() {
      _composerHeight = height;
      _hasMeasuredComposer = true;
    });
    if (isFirstMeasurement) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoFillHistory());
    }
    if (!isFirstMeasurement && _isFollowingTail) {
      _scrollToBottom();
    }
  }

  void _requestMissingSavedAnchor() {
    if (!mounted || widget.followLatestOnOpen) return;
    final anchorEventId = widget.initialViewportAnchorEventId;
    if (anchorEventId == null ||
        anchorEventId == _attemptedAnchorEventId ||
        widget.onLoadAnchoredHistory == null ||
        _messages.any((event) => event.id == anchorEventId)) {
      return;
    }
    _attemptedAnchorEventId = anchorEventId;
    unawaited(widget.onLoadAnchoredHistory!(anchorEventId));
  }

  void _maybeAutoFillHistory() {
    if (!mounted ||
        _automaticHistoryFillPages >= _maxAutomaticHistoryFillPages ||
        !widget.hasOlderHistory ||
        widget.isOlderHistoryLoading ||
        widget.olderHistoryError != null ||
        widget.onLoadOlderHistory == null ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final contentExtent = position.maxScrollExtent - position.minScrollExtent;
    if (contentExtent > position.viewportDimension + 1) return;
    _automaticHistoryFillPages++;
    unawaited(widget.onLoadOlderHistory!());
  }

  // ── Stream subscription ──────────────────────────────────────────────────

  void _subscribeToMessages() {
    unawaited(_messagesSubscription?.cancel());
    if (widget.messagesStream == null) return;

    _messagesSubscription = widget.messagesStream!.listen((messages) {
      if (!mounted) return;

      final isInitialSessionLoad = _messages.isEmpty && messages.isNotEmpty && !_awaitingLocalUserMessage;
      _applyMessages(messages, isOpeningSession: isInitialSessionLoad);
    });
  }

  // ── Widget update (same widget instance, different props) ────────────────

  @override
  void didUpdateWidget(covariant BrainActivityView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.messagesStream != widget.messagesStream) {
      _subscribeToMessages();
    }

    final sessionChanged =
        oldWidget.sessionId != widget.sessionId || oldWidget.composerSessionId != widget.composerSessionId;
    if (sessionChanged) {
      _cancelInlineEdit(notify: false);
      _attemptedAnchorEventId = null;
      _automaticHistoryFillPages = 0;
    }
    final messagesChanged = !listEquals(oldWidget.initialMessages, widget.initialMessages);
    final activityChanged = oldWidget.activityEligible != widget.activityEligible;
    final savedAnchor = widget.initialViewportAnchorEventId;
    final anchorBecameAvailable =
        savedAnchor != null &&
        !oldWidget.initialMessages.any((event) => event.id == savedAnchor) &&
        widget.initialMessages.any((event) => event.id == savedAnchor);
    if (sessionChanged || messagesChanged || activityChanged) {
      _applyMessages(
        widget.initialMessages,
        isOpeningSession: sessionChanged || _isOpeningSession || anchorBecameAvailable,
      );
    } else if (oldWidget.isOlderHistoryLoading != widget.isOlderHistoryLoading ||
        oldWidget.hasOlderHistory != widget.hasOlderHistory ||
        oldWidget.olderHistoryError != widget.olderHistoryError) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoFillHistory());
    }
  }

  // ── Scroll helpers ───────────────────────────────────────────────────────

  void _applyMessages(List<CanonicalEvent> messages, {required bool isOpeningSession}) {
    final previousMessages = _messages;
    final previousWasEmpty = previousMessages.isEmpty;
    final wasFollowingTail = _isFollowingTail;
    final previousIds = previousMessages.map((message) => message.id).toSet();
    final lastExistingIndex = previousIds.isEmpty
        ? -1
        : messages.lastIndexWhere((message) => previousIds.contains(message.id));
    final appendedNewEvents = <CanonicalEvent>[];
    for (var index = lastExistingIndex + 1; index < messages.length; index++) {
      final message = messages[index];
      if (!previousIds.contains(message.id)) appendedNewEvents.add(message);
    }
    final containsNewUserMessage = appendedNewEvents.any(
      (message) => message.kind == EventKind.userMessage,
    );
    final containsNewAgentEvent = appendedNewEvents.any(
      (message) => message.kind != EventKind.userMessage,
    );
    final newUserIndex = containsNewUserMessage
        ? messages.lastIndexWhere(
            (message) => !previousIds.contains(message.id) && message.kind == EventKind.userMessage,
          )
        : -1;
    final nextTimelineItems = projectConversationTimeline(
      messages,
      previousItems: _timelineItems,
      activityEligible: widget.activityEligible,
    );
    final previousAnchorEventIds = _openAnchorIndex >= 0 && _openAnchorIndex < _timelineItems.length
        ? _timelineItems[_openAnchorIndex].events.map((event) => event.id).toSet()
        : const <String>{};

    setState(() {
      _messages = List.from(messages);
      _timelineItems = nextTimelineItems;
      if (!isOpeningSession && newUserIndex < 0 && _timelineItems.isNotEmpty) {
        final projectedAnchor = _timelineItems.indexWhere(
          (item) => item.events.any(
            (event) => previousAnchorEventIds.contains(event.id),
          ),
        );
        _openAnchorIndex = projectedAnchor >= 0
            ? projectedAnchor
            : _openAnchorIndex.clamp(0, _timelineItems.length - 1).toInt();
      }
      if (!isOpeningSession) {
        _pendingEntranceEventIds.addAll(
          appendedNewEvents.where((event) => event.kind != EventKind.userMessage).map((event) => event.id),
        );
      }
      if (isOpeningSession) {
        _prepareInitialSessionPosition();
        _isOpeningSession = false;
      } else if (newUserIndex >= 0) {
        if (previousWasEmpty) {
          _openAtTail = false;
          _openAnchorIndex = _timelineItems.indexWhere(
            (item) => item.containsEventId(messages[newUserIndex].id),
          );
          if (_openAnchorIndex < 0) _openAnchorIndex = 0;
          _openingTailAnchorPixels = null;
          _hasResolvedOpeningTailAlignment = true;
        }
        // Sending reveals only the user row, but grants follow eligibility for
        // subsequent streamed growth until the user manually scrolls away.
        _autoFollowEligible = true;
        _isFollowingTail = false;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestMissingSavedAnchor();
      _maybeAutoFillHistory();
    });

    if (isOpeningSession || _timelineItems.isEmpty) return;

    if (containsNewUserMessage) {
      _awaitingLocalUserMessage = false;
      if (previousWasEmpty) {
        _scrollGeneration++;
      } else {
        _revealUserMessage(messages[newUserIndex].id);
      }
      return;
    }

    // In-place stream growth never performs an unconditional tail jump. It may
    // minimally reveal the followed row, or activate follow only when eligible
    // growth first reaches the composer boundary.
    if (!containsNewAgentEvent) {
      if (wasFollowingTail) {
        _revealFollowedEvent(_timelineItems.last.id);
      } else if (_autoFollowEligible) {
        _activateTailFollowAtBoundary();
      } else {
        _scrollGeneration++;
      }
      return;
    }

    if (wasFollowingTail) {
      _animateToBottomForNewAgentEvent();
      return;
    }
    if (_autoFollowEligible) {
      _activateTailFollowAtBoundary();
    }
  }

  int _lastUserMessageIndex(List<CanonicalEvent> messages) {
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].kind == EventKind.userMessage) return i;
    }
    return -1;
  }

  void _prepareInitialSessionPosition() {
    _openAtTail = widget.followLatestOnOpen;
    _openingTailAnchorPixels = null;
    _hasResolvedOpeningTailAlignment = true;
    _autoFollowEligible = false;
    _isFollowingTail = false;
    if (_timelineItems.isEmpty) {
      _openAnchorIndex = 0;
      return;
    }
    if (_openAtTail &&
        _timelineItems.last.events.length == 1 &&
        _timelineItems.last.event.kind == EventKind.userMessage) {
      _openAtTail = false;
      _openAnchorIndex = _timelineItems.length - 1;
      return;
    }
    if (_openAtTail) {
      _hasResolvedOpeningTailAlignment = false;
      _autoFollowEligible = true;
      // Keep older history in the upward-growing sliver, but place the latest
      // projected item after the center so streamed content grows downward.
      _openAnchorIndex = _timelineItems.length - 1;
      return;
    }
    final restoredIndex = widget.initialViewportAnchorEventId == null
        ? -1
        : _timelineItems.indexWhere(
            (item) => item.containsEventId(
              widget.initialViewportAnchorEventId!,
            ),
          );
    if (restoredIndex >= 0) {
      _openAnchorIndex = restoredIndex;
      return;
    }
    final userMessageIndex = _lastUserTimelineItemIndex();
    _openAnchorIndex = userMessageIndex == -1 ? _timelineItems.length - 1 : userMessageIndex;
  }

  int _lastUserTimelineItemIndex() {
    for (var index = _timelineItems.length - 1; index >= 0; index--) {
      if (_timelineItems[index].events.any(
        (event) => event.kind == EventKind.userMessage,
      )) {
        return index;
      }
    }
    return -1;
  }

  void _resolveOpeningTailAlignment() {
    if (!mounted ||
        !_openAtTail ||
        _hasResolvedOpeningTailAlignment ||
        !_hasMeasuredComposer ||
        _timelineItems.isEmpty) {
      return;
    }

    final viewport = _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    final latestBox = _eventViewportKeys[_timelineItems.last.id]?.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached || latestBox == null || !latestBox.attached) {
      return;
    }

    final viewportOrigin = viewport.localToGlobal(Offset.zero).dy;
    final visibleTop = viewportOrigin + _visibleContentTopInset;
    final visibleBottom = viewportOrigin + viewport.size.height - _visibleContentBottomInset;
    final latestBottom = latestBox.localToGlobal(Offset.zero).dy + latestBox.size.height;
    final bottomAnchorPixels = viewport.size.height - _visibleContentBottomInset;
    final tailCorrection = latestBottom - visibleBottom;
    final tailAnchorPixels = bottomAnchorPixels - tailCorrection;

    final firstBox = _eventViewportKeys[_timelineItems.first.id]?.currentContext?.findRenderObject() as RenderBox?;
    final firstTopAfterTailCorrection = firstBox == null || !firstBox.attached
        ? null
        : firstBox.localToGlobal(Offset.zero).dy - tailCorrection;
    final emptyUpperGap = firstTopAfterTailCorrection == null ? 0.0 : firstTopAfterTailCorrection - visibleTop;
    final hasEmptyUpperViewport = emptyUpperGap > 0.5;
    final resolvedAnchorPixels = tailAnchorPixels - (hasEmptyUpperViewport ? emptyUpperGap : 0);

    setState(() {
      _openingTailAnchorPixels = resolvedAnchorPixels.clamp(0.0, bottomAnchorPixels).toDouble();
      _hasResolvedOpeningTailAlignment = true;
      _isFollowingTail = !hasEmptyUpperViewport;
    });
  }

  bool get _isAtBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= _bottomFollowThreshold;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification && notification.direction != ScrollDirection.idle) {
      _hasPendingManualScrollAnchor = true;
      if (notification.direction == ScrollDirection.forward &&
          widget.hasOlderHistory &&
          !widget.isOlderHistoryLoading &&
          widget.onLoadOlderHistory != null &&
          notification.metrics.pixels - notification.metrics.minScrollExtent <= 600) {
        unawaited(widget.onLoadOlderHistory!());
      }
      _autoFollowEligible = false;
      _isFollowingTail = false;
      _scrollGeneration++;
    }
    if (notification is ScrollEndNotification && _hasPendingManualScrollAnchor) {
      _hasPendingManualScrollAnchor = false;
      final returnedToTail = _isAtBottom;
      _autoFollowEligible = returnedToTail;
      _isFollowingTail = false;
      if (returnedToTail) {
        _activateTailFollowAtBoundary();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _persistTopVisibleEvent());
    }
    return false;
  }

  void _persistTopVisibleEvent() {
    if (!mounted || widget.sessionId == null || widget.onViewportAnchorChanged == null) return;
    final viewport = _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return;

    final viewportOrigin = viewport.localToGlobal(Offset.zero).dy;
    final viewportTop = viewportOrigin + _visibleContentTopInset;
    final viewportBottom = viewportOrigin + viewport.size.height - _visibleContentBottomInset;
    String? topEventId;
    double? topEventPosition;

    for (final item in _timelineItems) {
      final eventBox = _eventViewportKeys[item.id]?.currentContext?.findRenderObject() as RenderBox?;
      if (eventBox == null || !eventBox.attached) continue;
      final eventTop = eventBox.localToGlobal(Offset.zero).dy;
      final eventBottom = eventTop + eventBox.size.height;
      if (eventBottom <= viewportTop || eventTop >= viewportBottom) continue;
      final visibleTop = eventTop < viewportTop ? viewportTop : eventTop;
      if (topEventPosition == null || visibleTop < topEventPosition) {
        topEventPosition = visibleTop;
        topEventId = item.id;
      }
    }

    _eventViewportKeys.removeWhere((_, key) => key.currentContext == null);
    if (topEventId != null) widget.onViewportAnchorChanged!(topEventId);
  }

  void _revealUserMessage(String eventId) {
    final generation = ++_scrollGeneration;
    _scheduleEventReveal(
      eventId,
      generation: generation,
      remainingFrames: 20,
      probedForLayout: false,
    );
  }

  void _revealFollowedEvent(String eventId) {
    final generation = ++_scrollGeneration;
    _scheduleEventReveal(
      eventId,
      generation: generation,
      remainingFrames: 3,
      probedForLayout: false,
    );
  }

  void _handleConversationActivityDisplayed(String eventId) {
    if (!mounted) return;
    if (_isFollowingTail) {
      _revealFollowedEvent(eventId);
    } else if (_autoFollowEligible) {
      _activateTailFollowAtBoundary();
    }
  }

  void _scheduleEventReveal(
    String eventId, {
    required int generation,
    required int remainingFrames,
    required bool probedForLayout,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _scrollGeneration || !_scrollController.hasClients) {
        return;
      }

      final viewport = _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (viewport == null || !viewport.attached) {
        if (remainingFrames > 1) {
          _scheduleEventReveal(
            eventId,
            generation: generation,
            remainingFrames: remainingFrames - 1,
            probedForLayout: probedForLayout,
          );
        }
        return;
      }

      final eventBox = _eventViewportKeys[eventId]?.currentContext?.findRenderObject() as RenderBox?;
      if (eventBox == null || !eventBox.attached) {
        final position = _scrollController.position;
        final probeTarget = position.maxScrollExtent;
        if ((probeTarget - position.pixels).abs() > 0.5) {
          _scrollController.jumpTo(probeTarget);
        }
        if (remainingFrames > 1) {
          _scheduleEventReveal(
            eventId,
            generation: generation,
            remainingFrames: remainingFrames - 1,
            probedForLayout: true,
          );
        }
        return;
      }

      final viewportOrigin = viewport.localToGlobal(Offset.zero).dy;
      final visibleTop = viewportOrigin + _visibleContentTopInset;
      final visibleBottom = viewportOrigin + viewport.size.height - _visibleContentBottomInset;
      final eventTop = eventBox.localToGlobal(Offset.zero).dy;
      final eventBottom = eventTop + eventBox.size.height;
      final fullyVisible = eventTop >= visibleTop - 0.5 && eventBottom <= visibleBottom + 0.5;
      if (fullyVisible && !probedForLayout) return;
      if (eventBottom <= visibleBottom + 0.5 && !probedForLayout) return;

      final position = _scrollController.position;
      final target = (position.pixels + eventBottom - visibleBottom).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
    });
  }

  void _animateToBottomForNewAgentEvent() {
    if (!mounted || _timelineItems.isEmpty) return;
    final generation = ++_scrollGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _scrollGeneration || !_scrollController.hasClients) {
        return;
      }
      final target = _scrollController.position.maxScrollExtent;
      if ((target - _scrollController.offset).abs() <= 0.5) return;
      unawaited(_runNewAgentFollowScroll(generation, target));
    });
  }

  Future<void> _runNewAgentFollowScroll(int generation, double target) async {
    await _scrollController.animateTo(
      target,
      duration: _newAgentFollowScrollDuration,
      curve: Curves.easeOutCubic,
    );
    if (!mounted || generation != _scrollGeneration || !_scrollController.hasClients) {
      return;
    }
    _jumpToBottomNow();
  }

  void _scrollToBottom({int remainingFrames = 3}) {
    if (!mounted || _timelineItems.isEmpty) return;
    final generation = ++_scrollGeneration;
    _scheduleBottomSettle(generation, remainingFrames);
  }

  void _scheduleBottomSettle(int generation, int remainingFrames) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _scrollGeneration) return;
      if (!mounted || !_scrollController.hasClients) return;
      _jumpToBottomNow();
      if (remainingFrames > 1) {
        _scheduleBottomSettle(generation, remainingFrames - 1);
      }
    });
  }

  void _jumpToBottomNow() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  void _activateTailFollowAtBoundary({int remainingFrames = 2}) {
    if (!mounted ||
        !_autoFollowEligible ||
        _isFollowingTail ||
        (_openAtTail && !_hasResolvedOpeningTailAlignment) ||
        _timelineItems.isEmpty) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autoFollowEligible || _isFollowingTail) return;
      final reachedBoundary = _latestContentReachedComposerBoundary();
      if (reachedBoundary == null && remainingFrames > 1) {
        _activateTailFollowAtBoundary(remainingFrames: remainingFrames - 1);
        return;
      }
      if (reachedBoundary != true) return;
      _isFollowingTail = true;
      _revealFollowedEvent(_timelineItems.last.id);
    });
  }

  bool? _latestContentReachedComposerBoundary() {
    if (_timelineItems.isEmpty) return false;
    final viewport = _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return null;

    final latestBox = _eventViewportKeys[_timelineItems.last.id]?.currentContext?.findRenderObject() as RenderBox?;
    if (latestBox != null && latestBox.attached) {
      final viewportBottom = viewport.localToGlobal(Offset.zero).dy + viewport.size.height - _visibleContentBottomInset;
      final latestBottom = latestBox.localToGlobal(Offset.zero).dy + latestBox.size.height;
      return latestBottom >= viewportBottom - 0.5;
    }

    if (!_scrollController.hasClients) return null;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels > 0.5;
  }

  void _beginInlineEdit(CanonicalEvent event) {
    _editController?.dispose();
    setState(() {
      _editController = TextEditingController(text: event.text);
      _editingEventId = event.id;
    });
  }

  void _cancelInlineEdit({bool notify = true}) {
    _editController?.dispose();
    _editController = null;
    _editingEventId = null;
    if (notify && mounted) setState(() {});
  }

  Future<void> _replayTurn(
    CanonicalEvent event, {
    required TurnReplayAction action,
    String? message,
  }) async {
    final requestId = event.requestId;
    if (requestId == null || requestId.isEmpty || _replayPendingEventId != null) {
      return;
    }
    setState(() => _replayPendingEventId = event.id);
    final cubit = context.read<ConversationInputCubit>();
    var result = await cubit.replayTurn(
      targetRequestId: requestId,
      action: action,
      message: message,
    );
    if (!mounted) return;
    if (result.requiresConfirmation) {
      final confirmed = await _confirmUnsafeReplay(result.safety);
      if (!mounted) return;
      if (!confirmed) {
        setState(() => _replayPendingEventId = null);
        return;
      }
      result = await cubit.replayTurn(
        targetRequestId: requestId,
        action: action,
        message: message,
        confirmedReplayUnsafe: true,
      );
      if (!mounted) return;
    }
    if (result.isAccepted) {
      _cancelInlineEdit(notify: false);
    } else {
      ToastUtils.showError(context, _turnReplayError(result.outcome));
    }
    setState(() => _replayPendingEventId = null);
  }

  Future<bool> _confirmUnsafeReplay(TurnReplaySafety safety) async {
    final isUnknown = safety == TurnReplaySafety.unknown;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Retry tool actions?'),
            content: Text(
              isUnknown
                  ? 'Sanad cannot verify whether this turn’s tools are safe to repeat. Retrying may repeat changes to files or external systems.'
                  : 'This turn used tools that may change files or external systems. Retrying can repeat those side effects.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
  }

  String _turnReplayError(String outcome) => switch (outcome) {
    'not_latest_turn' => 'Only the latest user turn can be edited or retried.',
    'turn_boundary_not_found' => 'This message does not have a reliable turn boundary.',
    'session_not_idle' => 'Sanad could not finish stopping the active turn.',
    'already_in_progress' => 'A message edit or retry is already in progress.',
    _ => 'Sanad could not edit or retry this message.',
  };

  void _handleSendMessage(String message, {MessageDeliveryIntent intent = MessageDeliveryIntent.auto}) {
    _awaitingLocalUserMessage = true;
    widget.onSendMessage(message, intent: intent);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  Widget _buildOlderHistoryControl() {
    if (!widget.hasOlderHistory && widget.olderHistoryError == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const Key('conversation_show_earlier'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: widget.isOlderHistoryLoading
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: widget.onLoadOlderHistory == null ? null : () => unawaited(widget.onLoadOlderHistory!()),
                icon: const Icon(Icons.expand_less),
                label: Text(
                  widget.olderHistoryError == null ? 'Show earlier' : 'Retry earlier messages',
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top + 48.0;
    final bottomPadding = _composerHeight + 12.0;
    _visibleContentTopInset = topPadding;
    _visibleContentBottomInset = bottomPadding;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateComposerHeight();
      _resolveOpeningTailAlignment();
    });

    if (widget.visualState.isNewConversation) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: SidebarBreakpoints.maxConversationWidth),
            child: NewChatView(
              onSendMessage: _handleSendMessage,
              onStop: widget.onStop,
            ),
          ),
        ),
      );
    }

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: Stack(
        children: [
          Positioned.fill(
            child: !_hasMeasuredComposer || _timelineItems.isEmpty
                ? const SizedBox.shrink()
                : Opacity(
                    opacity: !_openAtTail || _hasResolvedOpeningTailAlignment ? 1 : 0,
                    child: Container(
                      key: const Key('chat_messages_list'),
                      child: ShaderMask(
                        shaderCallback: (Rect rect) {
                          return const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black,
                              Colors.black,
                              Colors.transparent,
                            ],
                            stops: [0.0, 0.03, 0.97, 1.0],
                          ).createShader(rect);
                        },
                        blendMode: BlendMode.dstIn,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final viewportHeight = constraints.maxHeight;
                            final anchorPixels = _openAtTail
                                ? _openingTailAnchorPixels ?? viewportHeight - bottomPadding
                                : topPadding;
                            final anchor = viewportHeight > 0
                                ? (anchorPixels / viewportHeight).clamp(0.0, 1.0).toDouble()
                                : 0.0;

                            return SizedBox.expand(
                              key: _scrollViewportKey,
                              child: NotificationListener<ScrollNotification>(
                                onNotification: _handleScrollNotification,
                                child: CustomScrollView(
                                  key: ValueKey(
                                    '${widget.sessionId ?? 'new'}:'
                                    '${_openAtTail ? 'tail' : 'event'}:'
                                    '$_openAnchorIndex',
                                  ),
                                  controller: _scrollController,
                                  center: _conversationAnchorKey,
                                  anchor: anchor,
                                  slivers: [
                                    SliverPadding(
                                      padding: EdgeInsets.fromLTRB(8, topPadding, 8, 0),
                                      sliver: SliverList.builder(
                                        itemCount:
                                            _openAnchorIndex +
                                            ((widget.hasOlderHistory || widget.olderHistoryError != null) ? 1 : 0),
                                        itemBuilder: (context, index) {
                                          if (index == _openAnchorIndex) {
                                            return _buildOlderHistoryControl();
                                          }
                                          final itemIndex = _openAnchorIndex - index - 1;
                                          final item = _timelineItems[itemIndex];
                                          return Center(
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: SidebarBreakpoints.maxConversationWidth,
                                              ),
                                              child: _buildViewportTrackedItem(item),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    SliverPadding(
                                      key: _conversationAnchorKey,
                                      padding: EdgeInsets.fromLTRB(8, 8, 8, bottomPadding),
                                      sliver: SliverList.builder(
                                        itemCount: _timelineItems.length - _openAnchorIndex,
                                        itemBuilder: (context, index) {
                                          final itemIndex = _openAnchorIndex + index;
                                          final item = _timelineItems[itemIndex];
                                          return Center(
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: SidebarBreakpoints.maxConversationWidth,
                                              ),
                                              child: _buildViewportTrackedItem(item),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SizeChangedLayoutNotifier(
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (notification) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _updateComposerHeight();
                  });
                  return true;
                },
                child: Container(
                  key: _composerKey,
                  child: ConversationInputPanel(
                    onSendMessage: _handleSendMessage,
                    onStop: widget.onStop,
                    sessionId: widget.composerSessionId ?? widget.sessionId,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewportTrackedItem(ConversationTimelineItem item) {
    final entranceEvent = item.isActivity ? item.activity!.event : item.events.first;
    final animateEntrance =
        entranceEvent != null &&
        entranceEvent.kind != EventKind.userMessage &&
        _pendingEntranceEventIds.remove(entranceEvent.id) &&
        !item.isActivity;
    for (final event in item.events.skip(1)) {
      _pendingEntranceEventIds.remove(event.id);
    }
    return SizedBox(
      key: _eventViewportKeys.putIfAbsent(item.id, () => GlobalKey()),
      width: double.infinity,
      child: _AgentEventEntrance(
        key: ValueKey('agent-event-entrance:${item.id}'),
        animate: animateEntrance,
        child: item.isActivity
            ? ConversationActivityTile(
                activity: item.activity!,
                executionSnapshot: widget.executionSnapshot,
                onDisplayed: () => _handleConversationActivityDisplayed(
                  item.id,
                ),
              )
            : item.isToolGroup
            ? ToolGroupTile(
                key: ValueKey('tool-group:${item.id}'),
                item: item,
                isExpanded: _expandedEventIds.contains(
                  _toolGroupExpansionId(item),
                ),
                onToggleExpanded: (expanded) {
                  setState(() {
                    final id = _toolGroupExpansionId(item);
                    if (expanded) {
                      _expandedEventIds.add(id);
                    } else {
                      _expandedEventIds.remove(id);
                    }
                  });
                },
                expandedChildEventIds: _expandedEventIds,
                onChildToggleExpanded: (eventId, expanded) {
                  if (expanded) {
                    _expandedEventIds.add(eventId);
                  } else {
                    _expandedEventIds.remove(eventId);
                  }
                },
              )
            : _buildEventTile(item.event),
      ),
    );
  }

  String _toolGroupExpansionId(ConversationTimelineItem item) => 'tool-group:${item.id}';

  Widget _buildEventTile(CanonicalEvent event) {
    final latestUserIndex = _lastUserMessageIndex(_messages);
    final canReplay = latestUserIndex >= 0 && _messages[latestUserIndex].id == event.id && event.requestId != null;
    return BlocSelector<ConversationInputCubit, ConversationInputState, String?>(
      selector: (state) => state.pendingSuspendedRequest?.toolName,
      builder: (context, pendingToolName) => EventTile(
        key: ValueKey(event.id),
        event: event,
        waitingIndicator: event.status == EventStatus.running && pendingToolName == event.toolName
            ? (event.toolName == 'system_ask_user' ? ToolWaitingIndicator.question : ToolWaitingIndicator.permission)
            : ToolWaitingIndicator.none,
        isExpanded: _expandedEventIds.contains(event.id),
        onToggleExpanded: (expanded) {
          if (expanded) {
            _expandedEventIds.add(event.id);
          } else {
            _expandedEventIds.remove(event.id);
          }
        },
        onCancelPendingSteer: (requestId) =>
            context.read<ConversationInputCubit>().cancelPendingSteer(requestId: requestId),
        isCancellingPendingSteer:
            event.requestId != null && widget.pendingSteerCancellationRequestIds.contains(event.requestId),
        canReplay: canReplay,
        isEditing: _editingEventId == event.id,
        isReplayPending: _replayPendingEventId == event.id,
        editController: _editingEventId == event.id ? _editController : null,
        onBeginEdit: canReplay ? () => _beginInlineEdit(event) : null,
        onCancelEdit: _cancelInlineEdit,
        onSubmitEdit: canReplay
            ? () async {
                final text = _editController?.text.trim() ?? '';
                if (text.isEmpty) return;
                await _replayTurn(
                  event,
                  action: TurnReplayAction.edit,
                  message: text,
                );
              }
            : null,
        onRetry: canReplay ? () => _replayTurn(event, action: TurnReplayAction.retry) : null,
      ),
    );
  }
}

class _AgentEventEntrance extends StatefulWidget {
  const _AgentEventEntrance({
    super.key,
    required this.animate,
    required this.child,
  });

  final bool animate;
  final Widget child;

  @override
  State<_AgentEventEntrance> createState() => _AgentEventEntranceState();
}

class _AgentEventEntranceState extends State<_AgentEventEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  late bool _isComplete;

  @override
  void initState() {
    super.initState();
    _isComplete = !widget.animate;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.animate ? 0 : 1,
    )..addStatusListener(_handleAnimationStatus);
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    if (widget.animate) {
      unawaited(_controller.forward());
    }
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && !_isComplete) {
      setState(() => _isComplete = true);
    }
  }

  @override
  void didUpdateWidget(covariant _AgentEventEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !oldWidget.animate) {
      _isComplete = false;
      _controller.value = 0;
      unawaited(_controller.forward());
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleAnimationStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isComplete) return widget.child;

    return FadeTransition(
      opacity: _progress,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(_progress),
        child: widget.child,
      ),
    );
  }
}
