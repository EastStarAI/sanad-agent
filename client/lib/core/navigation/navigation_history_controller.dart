import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:go_router/go_router.dart';

import 'conversation_destination.dart';
import 'nav_trace.dart';

/// Snapshot of the navigation history at a point in time.
class NavigationHistorySnapshot {
  /// Destinations the user can navigate back to (most recent last).
  final List<ConversationDestination> backStack;

  /// The destination currently presented.
  final ConversationDestination? current;

  /// Destinations the user can navigate forward to (most recent last).
  final List<ConversationDestination> forwardStack;

  const NavigationHistorySnapshot({
    this.backStack = const [],
    this.current,
    this.forwardStack = const [],
  });

  NavigationHistorySnapshot copyWith({
    List<ConversationDestination>? backStack,
    ConversationDestination? current,
    bool clearCurrent = false,
    List<ConversationDestination>? forwardStack,
  }) {
    return NavigationHistorySnapshot(
      backStack: backStack ?? this.backStack,
      current: clearCurrent ? null : current ?? this.current,
      forwardStack: forwardStack ?? this.forwardStack,
    );
  }

  bool get canGoBack => backStack.isNotEmpty;
  bool get canGoForward => forwardStack.isNotEmpty;

  @override
  String toString() => 'NavigationHistorySnapshot(back=$backStack, current=$current, forward=$forwardStack)';
}

/// The branch [ConversationHistoryController.reconcile] took for a route that
/// GoRouter already made current. Reported so callers can trace the decision
/// without re-deriving it.
enum NavigationReconciliation {
  /// The route already describes the current destination.
  noop,

  /// The controller had no current destination yet (first route of a session).
  setInitial,

  /// The route is the newest back destination, so the controller moved back.
  goBack,

  /// The route is the newest forward destination, so the controller moved on.
  goForward,

  /// The route is unrelated to either stack, so the controller navigated to it.
  navigateTo,
}

/// Manages navigation history (back/current/forward stacks) for conversation
/// destinations.
///
/// ## Rules
/// 1. Navigating to a new destination pushes current onto back, clears forward.
/// 2. Back moves current to forward, pops last from back as new current.
/// 3. Forward reverses Back: moves current to back, pops last from forward.
/// 4. Re-selecting the same current does not add a duplicate entry.
/// 5. Deleted/invalid destinations are skipped when popping (E3).
/// 6. Route replacement (after deletion) must not add the replaced URL to back.
/// 7. Across-device navigation is allowed; the active device switches first.
class ConversationHistoryController extends ChangeNotifier {
  static final _logger = Logger('ConversationHistoryController');

  final List<ConversationDestination> _backStack = [];
  ConversationDestination? _current;
  final List<ConversationDestination> _forwardStack = [];

  final StreamController<NavigationHistorySnapshot> _controller =
      StreamController<NavigationHistorySnapshot>.broadcast();

  ConversationHistoryController() {
    _emit();
  }

  NavigationHistorySnapshot get snapshot => NavigationHistorySnapshot(
    backStack: List.unmodifiable(_backStack),
    current: _current,
    forwardStack: List.unmodifiable(_forwardStack),
  );

  Stream<NavigationHistorySnapshot> get changes => _controller.stream;

  /// Navigate to [destination], pushing current onto back and clearing forward.
  /// If [destination] equals the current destination, this is a no-op.
  void navigateTo(ConversationDestination destination) {
    if (destination == _current) {
      _logger.fine('navigateTo: duplicate of current, skipping');
      navTrace('nav.navigateTo', 'dup-of-current ${destTrace(destination)} | $_traceSnapshot');
      return;
    }

    if (_current != null) {
      _backStack.add(_current!);
    }
    _current = destination;
    _forwardStack.clear();
    _logger.fine('navigateTo: $destination');
    navTrace('nav.navigateTo', '-> ${destTrace(destination)} | $_traceSnapshot');
    _emit();
  }

  /// Navigate back one step. Returns the new current destination, or null if
  /// back is not available.
  ConversationDestination? goBack() {
    if (_backStack.isEmpty) {
      _logger.fine('goBack: back stack empty');
      return null;
    }

    if (_current != null) {
      _forwardStack.insert(0, _current!);
    }
    _current = _backStack.removeLast();
    _logger.fine('goBack: $_current');
    navTrace('nav.goBack', '-> ${destTrace(_current)} | $_traceSnapshot');
    _emit();
    return _current;
  }

  /// Navigate forward one step. Returns the new current destination, or null if
  /// forward is not available.
  ConversationDestination? goForward() {
    if (_forwardStack.isEmpty) {
      _logger.fine('goForward: forward stack empty');
      return null;
    }

    if (_current != null) {
      _backStack.add(_current!);
    }
    _current = _forwardStack.removeAt(0);
    _logger.fine('goForward: $_current');
    navTrace('nav.goForward', '-> ${destTrace(_current)} | $_traceSnapshot');
    _emit();
    return _current;
  }

  /// Replace the current destination without affecting back/forward stacks.
  /// Used after session deletion to prevent returning to the deleted URL.
  void replaceCurrent(ConversationDestination destination) {
    _current = destination;
    _logger.fine('replaceCurrent: $destination');
    navTrace('nav.replaceCurrent', '-> ${destTrace(destination)} | $_traceSnapshot');
    _emit();
  }

  /// Remove all occurrences of [destination] from back/forward stacks without
  /// affecting current. Used when a session is deleted.
  void removeFromHistory(ConversationDestination destination) {
    _backStack.removeWhere((d) => d == destination);
    _forwardStack.removeWhere((d) => d == destination);
    _logger.fine('removeFromHistory: $destination');
    navTrace('nav.removeFromHistory', '${destTrace(destination)} | $_traceSnapshot');
    _emit();
  }

  /// Remove all occurrences matching [sessionId] from back/forward stacks.
  void removeSessionFromHistory(String deviceId, String sessionId) {
    final target = ConversationDestination.session(
      deviceId: deviceId,
      sessionId: sessionId,
    );
    removeFromHistory(target);
  }

  /// Walk the back stack (most recent first) for the first valid same-device
  /// destination. Returns null if none found.
  ConversationDestination? findPreviousSameDevice(String deviceId) {
    for (var i = _backStack.length - 1; i >= 0; i--) {
      if (_backStack[i].deviceId == deviceId) {
        return _backStack[i];
      }
    }
    return null;
  }

  /// Removes and returns the most recent valid same-device destination from
  /// the back stack. Invalid candidates are pruned while walking the stack.
  ConversationDestination? takePreviousSameDevice(
    String deviceId, {
    bool Function(ConversationDestination destination)? isValid,
  }) {
    for (var i = _backStack.length - 1; i >= 0; i--) {
      final destination = _backStack[i];
      if (destination.deviceId != deviceId) continue;
      if (isValid != null && !isValid(destination)) {
        _backStack.removeAt(i);
        continue;
      }
      _backStack.removeAt(i);
      return destination;
    }
    return null;
  }

  /// Walk the forward stack (most recent first) for the first valid same-device
  /// destination. Returns null if none found.
  ConversationDestination? findForwardSameDevice(String deviceId) {
    for (final dest in _forwardStack) {
      if (dest.deviceId == deviceId) {
        return dest;
      }
    }
    return null;
  }

  /// Removes and returns the nearest valid same-device destination from the
  /// forward stack. Invalid candidates are pruned while walking the stack.
  ConversationDestination? takeForwardSameDevice(
    String deviceId, {
    bool Function(ConversationDestination destination)? isValid,
  }) {
    for (var i = 0; i < _forwardStack.length; i++) {
      final destination = _forwardStack[i];
      if (destination.deviceId != deviceId) continue;
      if (isValid != null && !isValid(destination)) {
        _forwardStack.removeAt(i);
        i--;
        continue;
      }
      _forwardStack.removeAt(i);
      return destination;
    }
    return null;
  }

  /// Clear all history (back, current, forward).
  void clear() {
    _backStack.clear();
    _current = null;
    _forwardStack.clear();
    navTrace('nav.clear', _traceSnapshot);
    _emit();
  }

  /// Reconcile the controller with a [destination] that GoRouter has already
  /// made current (browser pop/forward, deep link, or the first route of a
  /// session).
  ///
  /// This is the **only** stack-reconciliation implementation in the Client.
  /// It compares the destination against the existing stacks and mutates this
  /// controller; it never navigates GoRouter again, so it cannot create an
  /// update loop. Callers that need to move the route own that call.
  NavigationReconciliation reconcile(ConversationDestination destination) {
    if (destination == _current) return NavigationReconciliation.noop;
    if (_current == null) {
      setInitial(destination);
      return NavigationReconciliation.setInitial;
    }
    if (_backStack.isNotEmpty && _backStack.last == destination) {
      goBack();
      return NavigationReconciliation.goBack;
    }
    if (_forwardStack.isNotEmpty && _forwardStack.first == destination) {
      goForward();
      return NavigationReconciliation.goForward;
    }
    navigateTo(destination);
    return NavigationReconciliation.navigateTo;
  }

  /// Set the initial current destination without affecting history stacks.
  void setInitial(ConversationDestination destination) {
    _current = destination;
    navTrace('nav.setInitial', '-> ${destTrace(destination)} | $_traceSnapshot');
    _emit();
  }

  String get _traceSnapshot => historyTrace(
    back: _backStack,
    current: _current,
    forward: _forwardStack,
  );

  void _emit() {
    notifyListeners();
    _controller.add(snapshot);
  }

  @override
  void dispose() {
    unawaited(_controller.close());
    super.dispose();
  }
}

/// Synchronizes [ConversationHistoryController] with a [GoRouter] instance.
///
/// Two sync directions:
/// 1. **UI → GoRouter**: `navigateTo()` / `goBack()` / `goForward()` update the
///    controller then navigate via GoRouter. Always use these for UI intents.
/// 2. **GoRouter → Controller**: Call [reconcileFromRoute] when an external
///    route change is detected (browser pop/forward, deep link). It delegates
///    to [ConversationHistoryController.reconcile], the single
///    stack-reconciliation implementation, which compares the parsed
///    destination against the controller's stacks without calling
///    `router.go()` again.
///
/// No update loop: [reconcileFromRoute] only mutates the controller. The UI
/// will render the new route without a second GoRouter navigation.
class GoRouterHistorySync {
  static final _logger = Logger('GoRouterHistorySync');

  final ConversationHistoryController _controller;
  final GoRouter _router;

  GoRouterHistorySync({
    required ConversationHistoryController controller,
    required GoRouter router,
  }) : _controller = controller,
       _router = router;

  /// Navigate via the history controller and update GoRouter.
  /// Use for UI-triggered navigation (sidebar tap, New Conversation, etc.).
  void navigateTo(ConversationDestination destination) {
    _controller.navigateTo(destination);
    _router.go(destination.routePath);
  }

  /// Navigate back. Returns the destination or null if back unavailable.
  ConversationDestination? goBack() {
    final dest = _controller.goBack();
    if (dest != null) {
      _router.go(dest.routePath);
    }
    return dest;
  }

  /// Navigate forward. Returns the destination or null if forward unavailable.
  ConversationDestination? goForward() {
    final dest = _controller.goForward();
    if (dest != null) {
      _router.go(dest.routePath);
    }
    return dest;
  }

  /// Reconcile the controller state with a route change that already happened
  /// in GoRouter (browser pop/forward, deep link, or initial load).
  ///
  /// Call this from [HomeScreen] when [ConversationDestination] changes
  /// externally. The method parses the new destination and reconciles stacks
  /// without navigating again (the URL is already current).
  void reconcileFromRoute(ConversationDestination destination) {
    final outcome = _controller.reconcile(destination);
    _logger.fine('reconcileFromRoute: $destination -> ${outcome.name}');
  }

  bool get canGoBack => _controller.snapshot.canGoBack;
  bool get canGoForward => _controller.snapshot.canGoForward;
  ConversationHistoryController get controller => _controller;

  void dispose() {}
}
