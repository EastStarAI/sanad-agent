import 'package:sanad_client/features/conversations/domain/models/request_generation.dart';

/// Owns device, workspace, and section generations, and staleness rejection.
class CacheGenerationGuard {
  /// Per-section in-flight generation tokens, keyed by `deviceId|sectionKey`.
  /// A response whose generation is older than the current value is rejected.
  final Map<String, RequestGeneration> _sectionGenerations = {};
  final Map<String, RequestGeneration> _workspaceGenerations = {};

  CacheGenerationGuard();

  String sectionKey(String deviceId, String? workspaceId) =>
      workspaceId == null ? '$deviceId|__unscoped__' : '$deviceId|$workspaceId';

  /// Advance and return the generation for a section refresh. Callers must
  /// capture the returned token and pass it to the matching merge method so
  /// a late response cannot clobber a newer snapshot.
  RequestGeneration advanceGeneration(String deviceId, String? workspaceId) {
    final key = sectionKey(deviceId, workspaceId);
    final current = _sectionGenerations[key] ?? RequestGeneration.initial;
    final next = current.next();
    _sectionGenerations[key] = next;
    return next;
  }

  RequestGeneration advanceWorkspacesGeneration(String deviceId) {
    final current = _workspaceGenerations[deviceId] ?? RequestGeneration.initial;
    final next = current.next();
    _workspaceGenerations[deviceId] = next;
    return next;
  }

  RequestGeneration currentGeneration(String deviceId, String? workspaceId) {
    return _sectionGenerations[sectionKey(deviceId, workspaceId)] ?? RequestGeneration.initial;
  }

  RequestGeneration currentWorkspaceGeneration(String deviceId) {
    return _workspaceGenerations[deviceId] ?? RequestGeneration.initial;
  }

  bool isCurrent(RequestGeneration generation, String deviceId, String? workspaceId) {
    final current = currentGeneration(deviceId, workspaceId);
    return generation == current;
  }

  bool isCurrentWorkspaceGeneration(
    RequestGeneration generation,
    String deviceId,
  ) =>
      generation == currentWorkspaceGeneration(deviceId);

  void clearDevice(String deviceId) {
    _sectionGenerations.removeWhere((key, _) => key.startsWith('$deviceId|'));
    _workspaceGenerations.remove(deviceId);
  }

  void reset() {
    _sectionGenerations.clear();
    _workspaceGenerations.clear();
  }
}
