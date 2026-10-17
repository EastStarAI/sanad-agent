import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';

enum RouteThinkingSelectorState {
  /// The route/device carries no thinking transport (`supports_thinking_mode_change`
  /// is false, or a legacy device list is empty), so the control stays visible
  /// but disabled and never dispatches a mode. It is never silently removed.
  unavailable,
  loading,
  selectable,

  /// The route resolved, but exposes no user-selectable thinking control.
  /// This is a distinct, explainable state — never `Default` and never hidden.
  noControl,

  /// No thinking evidence was reported for the selected model/route yet, and the
  /// client must not guess. Distinct from [noControl] and from [loading].
  unknown,
  fetchFailure,
  legacy,
}

class RouteThinkingControl {
  RouteThinkingControl._();

  static bool shouldReloadSnapshot({
    required bool previouslyUsedModelControls,
    required bool usesModelControls,
    required String? previousProviderId,
    required String? providerId,
    required String? previousModelId,
    required String? modelId,
    required String? previousDeviceId,
    required String? deviceId,
  }) {
    if (!usesModelControls) {
      return false;
    }
    return !previouslyUsedModelControls ||
        previousProviderId != providerId ||
        previousModelId != modelId ||
        previousDeviceId != deviceId;
  }

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
    final metadataModelProvider = session?.metadata?['model_provider']?.toString().trim();
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
    bool isAuthoritative = false,
  }) {
    final sessionMatches = _sessionDescriptorMatchesActiveRoute(
      sessionDescriptor: sessionDescriptor,
      sessionRouteRevision: sessionRouteRevision,
      activeRouteRevision: activeRouteRevision,
      sessionProviderId: sessionProviderId,
      sessionModelId: sessionModelId,
      activeProviderId: providerInstanceId,
      activeModelId: modelId,
    );

    if (snapshot == null) {
      return sessionMatches ? sessionDescriptor : null;
    }

    final snapshotModel = _findModelInSnapshot(
      snapshot: snapshot,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
    );

    if (sessionMatches) {
      if (snapshotModel == null) {
        return sessionDescriptor;
      }
      final snapshotDescriptor = snapshotModel.thinkingControl;
      if (snapshotDescriptor == null) {
        return null;
      }
      if (snapshotDescriptor.status == ThinkingCapabilityStatus.unsupported) {
        return snapshotDescriptor;
      }
      if (isAuthoritative || snapshotDescriptor.capabilityRevision != sessionDescriptor!.capabilityRevision) {
        return snapshotDescriptor;
      }
      return sessionDescriptor;
    }

    return snapshotModel?.thinkingControl;
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
    if (sessionDescriptor.status == ThinkingCapabilityStatus.unknown) {
      return false;
    }
    if (sessionRouteRevision == null || activeRouteRevision == null || sessionRouteRevision != activeRouteRevision) {
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
        _normalizeModelId(boundModelId, providerId) == _normalizeModelId(routeModelId, providerId);
  }

  static ModelCacheModelDto? _findModelInSnapshot({
    required ModelCacheSnapshotDto snapshot,
    required String? providerInstanceId,
    required String? modelId,
  }) {
    final providerId = providerInstanceId?.trim();
    final routeModelId = modelId?.trim();
    if (providerId == null || providerId.isEmpty || routeModelId == null || routeModelId.isEmpty) {
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
        return model;
      }
    }
    return null;
  }

  static RouteThinkingSelectorState selectorState({
    required Capability capabilities,
    ThinkingControlDescriptorDto? descriptor,
    bool isLoading = false,
    bool hasFetchError = false,
  }) {
    if (!capabilities.supportsThinkingModeChange) {
      return RouteThinkingSelectorState.unavailable;
    }
    if (!capabilities.usesModelThinkingControls) {
      return capabilities.thinkingModesList.isEmpty
          ? RouteThinkingSelectorState.unavailable
          : RouteThinkingSelectorState.legacy;
    }
    if (descriptor != null) {
      return switch (descriptor.status) {
        // A resolved "no selectable control" route stays visible and explained.
        ThinkingCapabilityStatus.unsupported => RouteThinkingSelectorState.noControl,
        ThinkingCapabilityStatus.unknown => RouteThinkingSelectorState.unknown,
        ThinkingCapabilityStatus.supported =>
          descriptor.isSelectable ? RouteThinkingSelectorState.selectable : RouteThinkingSelectorState.noControl,
      };
    }
    if (isLoading) {
      return RouteThinkingSelectorState.loading;
    }
    if (hasFetchError) {
      return RouteThinkingSelectorState.fetchFailure;
    }
    // No descriptor, no load in flight and no failure: nothing was reported for
    // this route, so the honest state is unknown rather than a default claim.
    return RouteThinkingSelectorState.unknown;
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
      return true;
    }
    return descriptor.options.any((option) => option.id == trimmed);
  }

  /// The exact option id this route must admit, given the stored [selectionId].
  ///
  /// A valid explicit choice wins verbatim, including an exact `Off`; a choice
  /// the current descriptor no longer advertises (or no choice at all) resolves
  /// to the route's known native default, and `null` when this route declares no
  /// valid default — meaning the request omits thinking rather than the client
  /// guessing a tier. A `null`, non-selectable or silent descriptor is not proof
  /// that an explicit choice is invalid, so it is never rewritten.
  static String? resolveSelectionId({
    required ThinkingControlDescriptorDto? descriptor,
    required String? selectionId,
  }) {
    final trimmed = selectionId?.trim();
    if (trimmed != null && trimmed.isNotEmpty && isValidSelection(descriptor: descriptor, selectionId: trimmed)) {
      return trimmed;
    }
    return nativeDefaultOption(descriptor)?.id;
  }

  /// The menu entry that must be checked for [selectionId]. An explicit
  /// selection is returned verbatim (a stale id simply matches no entry); an
  /// unset selection falls back to the legacy device list only for legacy
  /// routes. It never resolves a descriptor default.
  static String? checkedMenuEntryId({
    required String? selectionId,
    required List<String> legacyModes,
  }) {
    final trimmed = selectionId?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    if (legacyModes.isNotEmpty) {
      if (legacyModes.contains('balanced')) {
        return 'balanced';
      }
      return legacyModes.first;
    }
    return null;
  }

  /// The descriptor's known native default option, when the agent declared one
  /// through `defaultOptionId` or `isProviderDefault` **and** that declaration
  /// still matches a current declared exact option. An unknown or stale default
  /// name resolves to no option at all, so the client never invents a tier.
  ///
  /// This is the option the route itself would apply, so it is the only value
  /// the composer may auto-select when the user made no explicit choice.
  static ThinkingControlOptionDto? nativeDefaultOption(
    ThinkingControlDescriptorDto? descriptor,
  ) {
    if (descriptor == null || descriptor.options.isEmpty) {
      return null;
    }
    final defaultOptionId = descriptor.defaultOptionId?.trim();
    if (defaultOptionId != null && defaultOptionId.isNotEmpty) {
      final byId = descriptor.options.where((option) => option.id == defaultOptionId).firstOrNull;
      if (byId != null) {
        return byId;
      }
    }
    return descriptor.options.where((option) => option.isProviderDefault).firstOrNull;
  }

  /// The exact token count declared for [option], or null when the descriptor
  /// declared no positive integral budget. The numeric value is returned as data
  /// so the caller applies its own localized copy and never invents a count.
  static int? declaredBudgetTokens(ThinkingControlOptionDto option) {
    final tokens = option.budgetTokens;
    if (tokens == null || tokens <= 0) {
      return null;
    }
    return tokens;
  }

  /// True when [option] is a token-budget preset the descriptor never gave a
  /// count for. Such an option belongs to a `token_budget` control and must stay
  /// identifiable as a budget even though no token value may be derived.
  static bool isUndeclaredBudgetPreset({
    required ThinkingControlDescriptorDto? descriptor,
    required ThinkingControlOptionDto option,
  }) {
    if (option.isOff) {
      return false;
    }
    if (declaredBudgetTokens(option) != null) {
      return false;
    }
    return descriptor?.kind == ThinkingControlKind.tokenBudget;
  }

  /// Label for the currently admitted thinking selection, or `null` when this
  /// route admits no selection at all.
  ///
  /// Only a real admitted selection is labelled here: the route's native
  /// default is auto-selected through the composer selection path, so it is
  /// labelled exactly like any other selected option, and the unselected label
  /// itself is localized copy supplied by the caller.
  static String? labelForSelection({
    required ThinkingControlDescriptorDto? descriptor,
    required String? selectionId,
  }) {
    final explicitId = selectionId?.trim();
    if (explicitId == null || explicitId.isEmpty) {
      return null;
    }
    final fromDescriptor = descriptor?.options
        .where((option) => option.id == explicitId)
        .map((option) => option.label)
        .firstOrNull;
    if (fromDescriptor != null && fromDescriptor.isNotEmpty) {
      return fromDescriptor;
    }
    if (explicitId.toLowerCase() == 'medium') {
      return 'Medium';
    }
    return explicitId;
  }

  static String normalizeModelId(String modelId, [String? providerInstanceId]) {
    var normalized = modelId.trim();
    if (providerInstanceId != null) {
      final provider = providerInstanceId.trim();
      final providerPrefix = '$provider/';
      if (provider.isNotEmpty && normalized.startsWith(providerPrefix)) {
        normalized = normalized.substring(providerPrefix.length);
      }
    }
    return normalized;
  }

  static String _normalizeModelId(String modelId, String providerInstanceId) =>
      normalizeModelId(modelId, providerInstanceId);
}
