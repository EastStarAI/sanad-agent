import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_model_group_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_runtime_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';
import 'package:intl/intl.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'model_brand_icon.dart';

/// Hierarchical model picker dialog: shows all configured providers as
/// section headers with their models listed beneath, plus a "Recently Used"
/// section when available. Includes a search field that filters models by
/// name across all providers.
///
/// Selection returns `{providerId, modelId}` to the caller via [onSelected];
/// the dialog does NOT send any socket command — it only captures the user's
/// intent for the next message.
///
/// The dialog creates its own [ProviderRuntimeCubit] scoped to the active
/// device, so it works even when opened in a new route that does not inherit
/// the parent route's providers.
class ModelPickerDialog extends StatefulWidget {
  final void Function(String providerId, String modelId) onSelected;

  /// The active device to scope the provider queries to. Null targets the
  /// local daemon. Resolved by the caller from the parent context before
  /// opening the dialog.
  final DeviceConfig? agent;
  final String? activeProviderId;
  final String? activeModelId;

  const ModelPickerDialog({
    super.key,
    required this.onSelected,
    this.agent,
    this.activeProviderId,
    this.activeModelId,
  });

  static IconData getProviderIconData(
    String providerId, {
    String? displayName,
    String? modelName,
  }) {
    final combined =
        '${providerId.toLowerCase()} ${displayName?.toLowerCase() ?? ''} ${modelName?.toLowerCase() ?? ''}';
    if (combined.contains('openai') || combined.contains('chatgpt') || combined.contains('gpt')) {
      return Symbols.smart_toy;
    }
    if (combined.contains('opencode')) {
      return Symbols.terminal;
    }
    if (combined.contains('deepseek')) {
      return Symbols.explore;
    }
    if (combined.contains('qwen') || combined.contains('alibaba')) {
      return Symbols.psychology_alt;
    }
    if (combined.contains('kimi') || combined.contains('moonshot')) {
      return Symbols.dark_mode;
    }
    if (combined.contains('anthropic') || combined.contains('claude')) {
      return Symbols.psychology;
    }
    if (combined.contains('google') || combined.contains('gemini')) {
      return Symbols.auto_awesome;
    }
    if (combined.contains('ollama') || combined.contains('local')) {
      return Symbols.terminal;
    }
    if (combined.contains('groq')) {
      return Symbols.bolt;
    }
    if (combined.contains('mistral') || combined.contains('codestral')) {
      return Symbols.air;
    }
    if (combined.contains('openrouter')) {
      return Symbols.hub;
    }
    if (combined.contains('bedrock') || combined.contains('aws')) {
      return Symbols.cloud;
    }
    if (combined.contains('azure')) {
      return Symbols.cloud_queue;
    }
    if (combined.contains('copilot') || combined.contains('github')) {
      return Symbols.code_blocks;
    }
    return Symbols.memory;
  }

  @override
  State<ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<ModelPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _query = '';
  final Set<String> _expandedProviderIds = {};
  int _focusedIndex = 0;
  List<({String providerId, String model})> _flatVisibleModels = [];

  List<ProviderModelGroupDto> _sortGroupsByRecency(
    List<ProviderModelGroupDto> groups,
    List<RecentModelDto> recentList,
  ) {
    final sortedGroups = List<ProviderModelGroupDto>.from(groups);
    final providerRecency = <String, int>{};
    for (int i = 0; i < recentList.length; i++) {
      final pId = recentList[i].instanceId;
      if (!providerRecency.containsKey(pId)) {
        providerRecency[pId] = i;
      }
    }

    final originalIndices = {for (int i = 0; i < groups.length; i++) groups[i].providerId: i};

    sortedGroups.sort((a, b) {
      final indexA = providerRecency[a.providerId] ?? 1000000;
      final indexB = providerRecency[b.providerId] ?? 1000000;
      if (indexA == indexB) {
        final origA = originalIndices[a.providerId] ?? 0;
        final origB = originalIndices[b.providerId] ?? 0;
        return origA.compareTo(origB);
      }
      return indexA.compareTo(indexB);
    });

    return sortedGroups;
  }

  List<String> _sortModelsByRecency(ProviderModelGroupDto group, List<RecentModelDto> recentList) {
    final models = group.models.models;
    final providerRecentModels = recentList
        .where((r) => r.instanceId == group.providerId)
        .map((r) => r.modelId)
        .toSet()
        .toList();

    final existingRecent = providerRecentModels.where((m) => models.contains(m)).toList();
    final otherModels = models.where((m) => !existingRecent.contains(m)).toList();

    return [...existingRecent, ...otherModels];
  }

  @override
  void initState() {
    super.initState();
    if (!AppPlatform.isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _searchFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = getIt<ProviderSetupClient>();

    return MultiBlocProvider(
      providers: [
        BlocProvider<ProviderRuntimeCubit>(
          create: (_) => ProviderRuntimeCubit(client: client, agent: widget.agent),
        ),
        BlocProvider<ProviderUsageCubit>.value(
          value: getIt<ProviderUsageCubit>(),
        ),
      ],
      child: BlocListener<ProviderRuntimeCubit, ProviderRuntimeState>(
        listenWhen: (prev, next) => prev.groups != next.groups && next.groups.isNotEmpty,
        listener: (context, state) {
          final instanceIds = state.groups.map((g) => g.providerId).toList();
          unawaited(
            context.read<ProviderUsageCubit>().onInstancesLoaded(
              agent: widget.agent,
              instanceIds: instanceIds,
            ),
          );
        },
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.70),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
                    child: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: BlocBuilder<ProviderRuntimeCubit, ProviderRuntimeState>(
                      builder: (context, state) => Row(
                        children: [
                          Text(
                            'Select Model',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          IconButton(
                            key: const Key('model_picker_refresh_btn'),
                            tooltip: state.isRefreshing ? 'Refreshing models...' : 'Refresh models',
                            icon: state.isRefreshing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: AppProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh, size: 18),
                            onPressed: state.isRefreshing
                                ? null
                                : () => context.read<ProviderRuntimeCubit>().refreshModels(),
                            visualDensity: VisualDensity.compact,
                          ),
                          IconButton(
                            key: const Key('model_picker_settings_btn'),
                            tooltip: 'Configure providers',
                            icon: const Icon(Icons.settings, size: 18),
                            onPressed: () {
                              Navigator.of(context).pop();
                              final deviceId = widget.agent?.id ?? '';
                              unawaited(context.push('${AppRoutes.settings}?section=providers&device_id=$deviceId'));
                            },
                            visualDensity: VisualDensity.compact,
                          ),
                          IconButton(
                            key: const Key('model_picker_close_btn'),
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => Navigator.of(context).pop(),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Focus(
                      onKeyEvent: (node, event) {
                        final isDownOrRepeat = event is KeyDownEvent || event is KeyRepeatEvent;
                        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                          if (isDownOrRepeat && _flatVisibleModels.isNotEmpty) {
                            setState(() {
                              _focusedIndex = (_focusedIndex + 1).clamp(0, _flatVisibleModels.length - 1);
                            });
                          }
                          return KeyEventResult.handled;
                        } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          if (isDownOrRepeat && _flatVisibleModels.isNotEmpty) {
                            setState(() {
                              _focusedIndex = (_focusedIndex - 1).clamp(0, _flatVisibleModels.length - 1);
                            });
                          }
                          return KeyEventResult.handled;
                        } else if (event.logicalKey == LogicalKeyboardKey.enter) {
                          if (event is KeyDownEvent &&
                              _flatVisibleModels.isNotEmpty &&
                              _focusedIndex >= 0 &&
                              _focusedIndex < _flatVisibleModels.length) {
                            final target = _flatVisibleModels[_focusedIndex];
                            widget.onSelected(target.providerId, target.model);
                            Navigator.of(context).pop();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        key: const Key('model_picker_search_input'),
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search models...',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        onChanged: (value) => setState(() {
                          _query = value.trim().toLowerCase();
                          _focusedIndex = 0;
                        }),
                      ),
                    ),
                  ),
                  BlocBuilder<ProviderRuntimeCubit, ProviderRuntimeState>(
                    builder: (context, state) {
                      return SizedBox(
                        height: 2,
                        child: (state.loading || state.isRefreshing)
                            ? const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16),
                                child: LinearProgressIndicator(minHeight: 2),
                              )
                            : null,
                      );
                    },
                  ),
                  Expanded(
                    child: BlocBuilder<ProviderRuntimeCubit, ProviderRuntimeState>(
                      builder: (context, state) => _buildBody(context, state),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
),
),
);
  }

  Widget _buildBody(BuildContext context, ProviderRuntimeState state) {
    if (state.loading && state.groups.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: AppProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (state.error != null && state.groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.error!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    final groups = _sortGroupsByRecency(_filteredGroups(state.groups), state.recent);
    final recent = _query.isEmpty ? state.recent : <RecentModelDto>[];

    final flatList = <({String providerId, String model})>[];
    if (recent.isNotEmpty) {
      for (final r in recent.take(5)) {
        flatList.add((providerId: r.instanceId, model: r.modelId));
      }
    }
    for (final group in groups) {
      final sortedModels = _sortModelsByRecency(group, state.recent);
      final isExpanded = _expandedProviderIds.contains(group.providerId);
      final models = (_query.isNotEmpty || isExpanded) ? sortedModels : sortedModels.take(5);
      for (final m in models) {
        flatList.add((providerId: group.providerId, model: m));
      }
    }
    _flatVisibleModels = flatList;

    if (groups.isEmpty && recent.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _query.isEmpty ? 'No configured providers' : 'No models match "$_query"',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    final slivers = <Widget>[];

    if (recent.isNotEmpty) {
      final recentToShow = recent.take(5).toList();
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecentHeader(context),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          sliver: SliverList.builder(
            itemCount: recentToShow.length,
            itemBuilder: (context, index) => _buildRecentItem(context, recentToShow[index]),
          ),
        ),
      );
    }

    for (final group in groups) {
      final originalGroup = state.groups.firstWhere(
        (g) => g.providerId == group.providerId,
        orElse: () => group,
      );
      final totalCount = originalGroup.models.models.length;
      final sortedModels = _sortModelsByRecency(group, state.recent);

      final isExpanded = _expandedProviderIds.contains(group.providerId);
      final hasMore = totalCount > 5;

      final List<String> modelsToShow;
      final bool showShowAllButton;
      final bool showShowLessButton;

      if (_query.isNotEmpty) {
        modelsToShow = sortedModels;
        showShowAllButton = false;
        showShowLessButton = false;
      } else {
        if (isExpanded) {
          modelsToShow = sortedModels;
          showShowAllButton = false;
          showShowLessButton = hasMore;
        } else {
          modelsToShow = sortedModels.take(5).toList();
          showShowAllButton = hasMore;
          showShowLessButton = false;
        }
      }

      final visibleCount = _query.isNotEmpty
          ? group.models.models.length
          : (isExpanded ? totalCount : (totalCount < 5 ? totalCount : 5));

      slivers.add(
        SliverMainAxisGroup(
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _ProviderHeaderDelegate(
                providerId: group.providerId,
                displayName: group.displayName,
                runtimeReady: group.runtimeReady,
                visibleCount: visibleCount,
                totalCount: totalCount,
                agent: widget.agent,
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              sliver: SliverList.builder(
                itemCount: modelsToShow.length + (showShowAllButton ? 1 : 0) + (showShowLessButton ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index < modelsToShow.length) {
                    final model = modelsToShow[index];
                    return _buildModelItem(context, group, model);
                  } else if (showShowAllButton) {
                    return _buildShowAllButton(context, group.providerId, totalCount - 5);
                  } else {
                    return _buildShowLessButton(context, group.providerId);
                  }
                },
              ),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: slivers,
    );
  }

  Widget _buildShowAllButton(BuildContext context, String providerId, int moreCount) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: InkWell(
          key: Key('model_picker_load_more_$providerId'),
          onTap: () {
            setState(() {
              _expandedProviderIds.add(providerId);
            });
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.expand_more,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 6),
                Text(
                  'Load more ($moreCount more)',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShowLessButton(BuildContext context, String providerId) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: InkWell(
          onTap: () {
            setState(() {
              _expandedProviderIds.remove(providerId);
            });
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.expand_less,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 6),
                Text(
                  'Show Less',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            'Recently Used',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentItem(BuildContext context, RecentModelDto recent) {
    final label = recent.instanceDisplayName != null
        ? '${recent.instanceDisplayName} / ${recent.modelId}'
        : recent.modelId;
    final isSelected =
        widget.activeProviderId?.trim().toLowerCase() == recent.instanceId.trim().toLowerCase() &&
        widget.activeModelId?.trim().toLowerCase() == recent.modelId.trim().toLowerCase();
    final isFocused = _flatVisibleModels.isNotEmpty &&
        _focusedIndex >= 0 &&
        _focusedIndex < _flatVisibleModels.length &&
        _flatVisibleModels[_focusedIndex].providerId == recent.instanceId &&
        _flatVisibleModels[_focusedIndex].model == recent.modelId;

    final tile = ListTile(
      key: Key('recent_model_option_${recent.modelId}'),
      dense: true,
      selected: isSelected,
      leading: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: ModelBrandIcon(
            providerId: recent.instanceId,
            displayName: recent.instanceDisplayName,
            modelName: recent.modelId,
            size: 16,
          ),
        ),
      ),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      onTap: () {
        widget.onSelected(recent.instanceId, recent.modelId);
        Navigator.of(context).pop();
      },
    );

    if (isFocused) {
      return Material(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        child: tile,
      );
    }
    return tile;
  }

  List<ProviderModelGroupDto> _filteredGroups(
    List<ProviderModelGroupDto> groups,
  ) {
    if (_query.isEmpty) return groups;
    final result = <ProviderModelGroupDto>[];
    for (final g in groups) {
      final matching = g.models.models.where((m) => m.toLowerCase().contains(_query)).toList();
      if (matching.isNotEmpty) {
        result.add(
          ProviderModelGroupDto(
            providerId: g.providerId,
            displayName: g.displayName,
            runtimeReady: g.runtimeReady,
            models: ModelOptionsDto(
              providerId: g.models.providerId,
              models: matching,
              selectedModel: g.models.selectedModel,
              authenticated: g.models.authenticated,
              authType: g.models.authType,
              keyEnv: g.models.keyEnv,
              warning: g.models.warning,
              source: g.models.source,
            ),
            liveFetchFailed: g.liveFetchFailed,
          ),
        );
      }
    }
    return result;
  }

  Widget _buildModelItem(BuildContext context, ProviderModelGroupDto group, String model) {
    final isSelected = () {
      final activeProvider = widget.activeProviderId?.trim().toLowerCase();
      final activeModel = widget.activeModelId?.trim().toLowerCase();

      if (activeModel == null || activeModel.isEmpty) {
        return model == group.models.selectedModel;
      }

      if (activeProvider != null && activeProvider.isNotEmpty) {
        final cleanModel = activeModel.startsWith('$activeProvider/')
            ? activeModel.substring(activeProvider.length + 1)
            : activeModel;
        return group.providerId.toLowerCase() == activeProvider && model.toLowerCase() == cleanModel;
      }

      return model.toLowerCase() == activeModel;
    }();

    final isFocused = _flatVisibleModels.isNotEmpty &&
        _focusedIndex >= 0 &&
        _focusedIndex < _flatVisibleModels.length &&
        _flatVisibleModels[_focusedIndex].providerId == group.providerId &&
        _flatVisibleModels[_focusedIndex].model == model;

    final tile = ListTile(
      key: Key('model_option_$model'),
      dense: true,
      selected: isSelected,
      leading: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: ModelBrandIcon(
            providerId: group.providerId,
            displayName: group.displayName,
            modelName: model,
            size: 16,
          ),
        ),
      ),
      title: Text(model, key: Key('model_title_$model'), style: const TextStyle(fontSize: 13)),
      trailing: isSelected ? const Icon(Icons.check, size: 16) : null,
      onTap: () {
        widget.onSelected(group.providerId, model);
        Navigator.of(context).pop();
      },
    );

    if (isFocused) {
      return Material(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        child: tile,
      );
    }
    return tile;
  }
}

class _ProviderHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String providerId;
  final String displayName;
  final bool runtimeReady;
  final int visibleCount;
  final int totalCount;
  final DeviceConfig? agent;

  _ProviderHeaderDelegate({
    required this.providerId,
    required this.displayName,
    required this.runtimeReady,
    required this.visibleCount,
    required this.totalCount,
    required this.agent,
  });

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: overlapsContent
            ? Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  width: 1,
                ),
              )
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        children: [
          ModelBrandIcon(
            providerId: providerId,
            displayName: displayName,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            displayName,
            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          if (runtimeReady)
            Icon(Icons.check_circle, size: 14, color: theme.colorScheme.primary)
          else
            Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          BlocBuilder<ProviderUsageCubit, ProviderUsageState>(
            builder: (context, usageState) {
              final deviceId = agent?.id ?? getIt<ProviderUsageCubit>().localDeviceId;
              final entry = usageState.entry(deviceId, providerId);
              final supports = usageState.support.supports(deviceId, providerId);

              if (!supports || entry == null || entry.phase == ProviderUsagePhase.hidden) {
                return const SizedBox.shrink();
              }

              final isLoading = entry.phase == ProviderUsagePhase.loading || entry.backgroundRefreshing;
              final hasSnapshot = entry.hasVisibleSnapshot;

              double? progress;
              if (hasSnapshot && entry.result?.snapshot?.windows != null) {
                double maxProgress = 0.0;
                for (final window in entry.result!.snapshot!.windows) {
                  final remaining = window.remainingPercent;
                  final used = window.usedPercent;
                  final p = (used ?? (remaining != null ? 100.0 - remaining : 0.0)) / 100.0;
                  if (p > maxProgress) {
                    maxProgress = p;
                  }
                }
                progress = maxProgress.clamp(0.0, 1.0);
              }

              // Color for the progress indicator
              Color getProgressColor(double value) {
                if (value >= 0.9) return const Color(0xFFE53935);
                if (value >= 0.7) return const Color(0xFFFB8C00);
                return theme.colorScheme.primary;
              }

              // Format helper
              String formatPercent(double value) {
                return value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);
              }

              // Tooltip message containing all available details
              final List<String> tooltipLines = [];
              String formatRelativeTime(DateTime at) {
                final local = at.toLocal();
                final delta = DateTime.now().difference(local);
                if (delta.inSeconds < 30) return 'updated just now';
                if (delta.inMinutes < 1) {
                  final sec = delta.inSeconds;
                  return 'updated $sec second${sec == 1 ? '' : 's'} ago';
                }
                if (delta.inHours < 1) {
                  final min = delta.inMinutes;
                  return 'updated $min minute${min == 1 ? '' : 's'} ago';
                }
                if (delta.inHours < 24) {
                  final hr = delta.inHours;
                  return 'updated $hr hour${hr == 1 ? '' : 's'} ago';
                }
                return 'updated on ${DateFormat('EEE, MMM d, HH:mm').format(local)}';
              }

              if (entry.fetchedAt != null) {
                tooltipLines.add(formatRelativeTime(entry.fetchedAt!));

                if (entry.result?.snapshot?.windows != null) {
                  for (final window in entry.result!.snapshot!.windows) {
                    final label = window.label;
                    final remaining = window.remainingPercent;
                    final used = window.usedPercent;
                    final double? remainingVal = remaining ?? (used != null ? (100.0 - used).clamp(0.0, 100.0) : null);
                    if (remainingVal != null) {
                      var line = '$label: ${formatPercent(remainingVal)}% remaining';
                      if (window.resetAt != null) {
                        final resetString = _formatResetRelative(window.resetAt!);
                        line += ' (resets $resetString)';
                      }
                      tooltipLines.add(line);
                    }
                  }
                }

                final resets = entry.result?.snapshot?.availableResets ?? 0;
                if (resets > 0) {
                  tooltipLines.add('Resets: $resets available');
                }
              } else if (isLoading) {
                tooltipLines.add('Loading usage...');
              } else {
                tooltipLines.add('No usage data fetched yet');
              }
              final tooltipMessage = tooltipLines.join('\n');

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: tooltipMessage,
                    triggerMode: TooltipTriggerMode.tap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: AppProgressIndicator(
                          value: progress,
                          strokeWidth: 2.0,
                          backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            getProgressColor(progress ?? 0.0).withValues(alpha: 0.90),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: isLoading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: AppProgressIndicator(strokeWidth: 1.5),
                          )
                        : Icon(
                            Icons.refresh,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                    onPressed: isLoading
                        ? null
                        : () => context.read<ProviderUsageCubit>().refresh(
                            instanceId: providerId,
                            agent: agent,
                          ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Refresh usage',
                  ),
                ],
              );
            },
          ),
          const Spacer(),
          Text(
            '$totalCount',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  @override
  double get maxExtent => 36.0;

  @override
  double get minExtent => 36.0;

  @override
  bool shouldRebuild(covariant _ProviderHeaderDelegate oldDelegate) {
    return oldDelegate.providerId != providerId ||
        oldDelegate.displayName != displayName ||
        oldDelegate.runtimeReady != runtimeReady ||
        oldDelegate.visibleCount != visibleCount ||
        oldDelegate.totalCount != totalCount ||
        oldDelegate.agent?.id != agent?.id;
  }
}

String _formatResetRelative(DateTime resetAt) {
  final local = resetAt.toLocal();
  final now = DateTime.now();
  final delta = local.difference(now);
  if (delta.isNegative) return 'any moment';
  if (delta.inMinutes < 1) return 'in a moment';
  if (delta.inHours < 1) return 'in ${delta.inMinutes}m';
  if (delta.inHours < 24) return 'in ${delta.inHours}h';
  if (delta.inDays <= 6) return 'in ${delta.inDays}d';
  return "on ${DateFormat('MMM d, HH:mm').format(local)}";
}

@visibleForTesting
int modelPickerVisibleSectionCount({
  required int groupCount,
  required int recentCount,
}) {
  return groupCount + (recentCount > 0 ? recentCount + 1 : 0);
}
