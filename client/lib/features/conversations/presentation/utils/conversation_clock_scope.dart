import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Scoped provider for a unified 1-second heartbeat clock.
///
/// Descendants should NOT listen to this InheritedWidget directly for rebuilds.
/// Instead, retrieve the [clock] listenable via [ConversationClockScope.maybeOf]
/// and wrap only the specific text widget in a [ValueListenableBuilder] to prevent
/// broad widget tree rebuilds.
class ConversationClockScope extends InheritedWidget {
  const ConversationClockScope({
    super.key,
    required this.clock,
    required super.child,
  });

  final ValueListenable<DateTime> clock;

  static ValueListenable<DateTime>? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ConversationClockScope>()?.clock;
  }

  @override
  bool updateShouldNotify(ConversationClockScope oldWidget) => clock != oldWidget.clock;
}
