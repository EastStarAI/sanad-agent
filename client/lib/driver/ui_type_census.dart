/// Bounded census of the widget runtime types a Client actually renders.
///
/// The inspected projection intentionally emits only keyed, textual,
/// tooltip-bearing, or interactive widgets, so an uninspected type is
/// indistinguishable from an absent one. The census answers "is this type
/// rendered at all", which is what an absence claim requires.
library;

/// Rendered types found by one census walk, with explicit truncation state.
class RenderedTypeCensus {
  const RenderedTypeCensus({
    required this.types,
    required this.visitedElements,
    required this.truncated,
  });

  /// Distinct rendered type names, sorted for stable output.
  final List<String> types;

  /// Elements the walk visited before it stopped.
  final int visitedElements;

  /// True when the walk stopped before covering the tree, so an absence claim
  /// is unprovable from this census.
  final bool truncated;
}

/// Upper bound on the elements a rendered-type census visits.
///
/// The census is bounded by the walk, never by the number of distinct types: a
/// large application legitimately renders hundreds of widget types, and a type
/// count cap would report every such tree as truncated and make every absence
/// claim unprovable. A walk bound degrades predictably instead, and the
/// truncation flag keeps the result honest when it trips.
const int renderedTypeCensusMaxElements = 20000;

/// Collects the distinct [label] values rendered in the tree rooted at [root].
///
/// The walk is pre-order and iterative, so a deep tree cannot overflow the
/// stack. It stops at [maxElements] visited nodes and reports `truncated`, in
/// which case an absence claim must fail closed.
RenderedTypeCensus boundedRenderedTypeCensus<T>({
  required T root,
  required String Function(T node) label,
  required Iterable<T> Function(T node) children,
  int maxElements = renderedTypeCensusMaxElements,
}) {
  final types = <String>{};
  final pending = <T>[root];
  var visited = 0;
  var truncated = false;

  while (pending.isNotEmpty) {
    if (visited >= maxElements) {
      truncated = true;
      break;
    }
    final node = pending.removeLast();
    visited++;
    types.add(label(node));
    pending.addAll(children(node));
  }

  final sorted = types.toList()..sort();
  return RenderedTypeCensus(
    types: sorted,
    visitedElements: visited,
    truncated: truncated,
  );
}
