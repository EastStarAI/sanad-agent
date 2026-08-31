import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';

enum RouteThinkingSelectorState { hidden, unavailable, selectable, legacy }

class RouteThinkingControl {
  RouteThinkingControl._();

  static String? activeProviderId({
    required Session? session,
    required ConversationInputSlice inputSlice,
  }) {
    final nextProviderId = inputSlice.nextMessageProviderId?.trim();
    if (nextProviderId != null && nextProviderId.isNotEmpty) {
      return nextProviderId;
    }
    final sessionProvider = session?.modelProvider?.trim();
    if (sessionProvider != null && sessionProvider.isNotEmpty) {
      return sessionProvider;
    }
    final metadataProvider = session?.metadata?['provider']?.toString().trim();
    if (metadataProvider != null && metadataProvider.isNotEmpty) {
      return metadataProvider;
    }
    final metadataModelProvider =
        session?.metadata?['model_provider']?.toString().trim();
    if (metadataModelProvider != null && metadataModelProvider.isNotEmpty) {
      return metadataModelProvider;
    }
    return null;
  }

  static String? activeModelId({
    required Session? session,
    required ConversationInputSlice inputSlice,
  }) {
    final nextModel = inputSlice.nextMessageModel?.trim();
    if (nextModel != null && nextModel.isNotEmpty) {
      return nextModel;
    }
    final sessionModel = session?.model?.trim();
    if (sessionModel != null && sessionModel.isNotEmpty) {
      return sessionModel;
    }
    return null;
  }

  static ThinkingControlDescriptorDto? resolveDescriptor({
    required ModelCacheSnapshotDto? snapshot,
    required String? providerInstanceId,
    required String? modelId,
    ThinkingControlDescriptorDto? sessionDescriptor,
    int? sessionRouteRevision,
    int? activeRouteRevision,
    String? sessionProviderId,
    String? sessionModelId,
  }) {
    if (_sessionDescriptorMatchesActiveRoute(
      sessionDescriptor: sessionDescriptor,
      sessionRouteRevision: sessionRouteRevision,
      activeRouteRevision: activeRouteRevision,
      sessionProviderId: sessionProviderId,
      sessionModelId: sessionModelId,
      activeProviderId: providerInstanceId,
      activeModelId: modelId,
    )) {
      return sessionDescriptor;
    }

    if (snapshot == null) {
      return null;
    }

    return _resolveFromSnapshot(
      snapshot: snapshot,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
    );
  }

  static bool _sessionDescriptorMatchesActiveRoute({
    required ThinkingControlDescriptorDto? sessionDescriptor,
    required int? sessionRouteRevision,
    required int? activeRouteRevision,
    required String? sessionProviderId,
    required String? sessionModelId,
    required String? activeProviderId,
    required String? activeModelId,
  }) {
    if (sessionDescriptor == null) {
      return false;
    }
    if (sessionRouteRevision == null ||
        activeRouteRevision == null ||
        sessionRouteRevision != activeRouteRevision) {
      return false;
    }

    final providerId = activeProviderId?.trim();
    final routeModelId = activeModelId?.trim();
    final boundProviderId = sessionProviderId?.trim();
    final boundModelId = sessionModelId?.trim();
    if (providerId == null ||
        providerId.isEmpty ||
        routeModelId == null ||
        routeModelId.isEmpty ||
        boundProviderId == null ||
        boundProviderId.isEmpty ||
        boundModelId == null ||
        boundModelId.isEmpty) {
      return false;
    }

    return boundProviderId == providerId &&
        _normalizeModelId(boundModelId, providerId) ==
            _normalizeModelId(routeModelId, providerId);
  }

  static ThinkingControlDescriptorDto? _resolveFromSnapshot({
    required ModelCacheSnapshotDto snapshot,
    required String? providerInstanceId,
    required String? modelId,
  }) {
    final providerId = providerInstanceId?.trim();
    final routeModelId = modelId?.trim();
    if (providerId == null ||
        providerId.isEmpty ||
        routeModelId == null ||
        routeModelId.isEmpty) {
      return null;
    }

    ModelCacheInstanceDto? instance;
    for (final candidate in snapshot.instances) {
      if (candidate.id == providerId) {
        instance = candidate;
        break;
      }
    }
    if (instance == null) {
      return null;
    }

    final normalizedTarget = _normalizeModelId(routeModelId, providerId);
    for (final model in instance.models) {
      if (_normalizeModelId(model.id, providerId) == normalizedTarget) {
        return model.thinkingControl;
      }
    }
    return null;
  }

  static RouteThinkingSelectorState selectorState({
    required Capability capabilities,
    ThinkingControlDescriptorDto? descriptor,
  }) {
    if (!capabilities.supportsThinkingModeChange) {
      return RouteThinkingSelectorState.hidden;
    }
    if (!capabilities.usesModelThinkingControls) {
      return capabilities.thinkingModesList.isEmpty
          ? RouteThinkingSelectorState.hidden
          : RouteThinkingSelectorState.legacy;
    }
    if (descriptor == null) {
      return RouteThinkingSelectorState.unavailable;
    }
    return switch (descriptor.status) {
      ThinkingCapabilityStatus.unsupported => RouteThinkingSelectorState.hidden,
      ThinkingCapabilityStatus.unknown => RouteThinkingSelectorState.unavailable,
      ThinkingCapabilityStatus.supported =>
        descriptor.isSelectable
            ? RouteThinkingSelectorState.selectable
            : RouteThinkingSelectorState.hidden,
    };
  }

  static bool isValidSelection({
    required ThinkingControlDescriptorDto? descriptor,
    required String? selectionId,
  }) {
    final trimmed = selectionId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return true;
    }
    if (descriptor == null || !descriptor.isSelectable) {
      return false;
    }
    return descriptor.options.any((option) => option.id == trimmed);
  }

  static String labelForSelection({
    required ThinkingControlDescriptorDto? descriptor,
    required String? selectionId,
    required List<String> legacyModes,
  }) {
    final trimmed = selectionId?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      final fromDescriptor = descriptor?.options
          .where((option) => option.id == trimmed)
          .map((option) => option.label)
          .firstOrNull;
      if (fromDescriptor != null && fromDescriptor.isNotEmpty) {
        return fromDescriptor;
      }
      return trimmed;
    }
    if (legacyModes.isNotEmpty) {
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
      if (legacyModes.contains('balanced')) {
        return 'balanced';
      }
      return legacyModes.first;
    }
    return 'Default';
  }

  static String _normalizeModelId(String modelId, String providerInstanceId) {
    var normalized = modelId.trim().toLowerCase();
    final providerPrefix = '${providerInstanceId.trim().toLowerCase()}/';
    if (normalized.startsWith(providerPrefix)) {
      normalized = normalized.substring(providerPrefix.length);
    }
    if (normalized.contains('/')) {
      normalized = normalized.split('/').last;
    }
    return normalized;
  }
}
