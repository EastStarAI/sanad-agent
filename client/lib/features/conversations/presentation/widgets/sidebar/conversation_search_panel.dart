import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../../devices/domain/models/device_config.dart';
import '../../../domain/models/session_search.dart';
import '../../bloc/session_search_cubit.dart';
import '../../bloc/session_search_state.dart';

class ConversationSearchButton extends StatelessWidget {
  final DeviceConfig device;
  final bool isDrawerMode;
  final ValueChanged<SessionSearchHit> onSelected;

  const ConversationSearchButton({
    super.key,
    required this.device,
    required this.isDrawerMode,
    required this.onSelected,
  });

  Future<void> _open(BuildContext context) async {
    final cubit = context.read<SessionSearchCubit>();
    cubit.reset();
    final panel = BlocProvider.value(
      value: cubit,
      child: ConversationSearchPanel(
        device: device,
        onSelected: (hit) {
          Navigator.of(context, rootNavigator: true).pop();
          onSelected(hit);
        },
      ),
    );
    if (isDrawerMode) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(heightFactor: .88, child: panel),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
            child: panel,
          ),
        ),
      );
    }
    cubit.reset();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('conversation_search_button'),
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        hoverColor: theme.colorScheme.surfaceContainer.withValues(alpha: 0.8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(
                Symbols.search_rounded,
                size: 16,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Search conversations',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ConversationSearchPanel extends StatefulWidget {
  final DeviceConfig device;
  final ValueChanged<SessionSearchHit> onSelected;

  const ConversationSearchPanel({
    super.key,
    required this.device,
    required this.onSelected,
  });

  @override
  State<ConversationSearchPanel> createState() => _ConversationSearchPanelState();
}

class _ConversationSearchPanelState extends State<ConversationSearchPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final state = context.read<SessionSearchCubit>().state;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_controller.text.isNotEmpty) {
        _controller.clear();
        context.read<SessionSearchCubit>().queryChanged(widget.device, '');
      } else {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final composing = _controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) {
        return KeyEventResult.handled;
      }
      _submit();
      return KeyEventResult.handled;
    }
    if (state.hits.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedIndex = (_selectedIndex + 1).clamp(0, state.hits.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _selectedIndex = (_selectedIndex - 1).clamp(0, state.hits.length - 1));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _submit() {
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final hits = context.read<SessionSearchCubit>().state.hits;
    if (hits.isEmpty) return;
    widget.onSelected(hits[_selectedIndex.clamp(0, hits.length - 1)]);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('conversation_search_field'),
                    controller: _controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    onChanged: (value) {
                      _selectedIndex = 0;
                      context.read<SessionSearchCubit>().queryChanged(widget.device, value);
                    },
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: 'Search titles and messages',
                      prefixIcon: const Icon(Symbols.search_rounded),
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _controller,
                        builder: (context, value, _) {
                          if (value.text.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _controller.clear();
                              context.read<SessionSearchCubit>().queryChanged(widget.device, '');
                              _focusNode.requestFocus();
                            },
                            icon: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              ),
                              child: const Icon(
                                Symbols.close_rounded,
                                size: 16,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('conversation_search_close_btn'),
                  tooltip: 'Close search',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Symbols.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: BlocBuilder<SessionSearchCubit, SessionSearchState>(
              builder: (context, state) => _SearchResults(
                state: state,
                selectedIndex: _selectedIndex,
                onSelected: widget.onSelected,
                onRetry: context.read<SessionSearchCubit>().retry,
                onLoadMore: context.read<SessionSearchCubit>().loadMore,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  final SessionSearchState state;
  final int selectedIndex;
  final ValueChanged<SessionSearchHit> onSelected;
  final VoidCallback onRetry;
  final VoidCallback onLoadMore;

  const _SearchResults({
    required this.state,
    required this.selectedIndex,
    required this.onSelected,
    required this.onRetry,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    if (state.status == SessionSearchStatus.idle) {
      return const Center(child: Text('Search this device’s conversation history.'));
    }
    if (state.status == SessionSearchStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == SessionSearchStatus.empty) {
      return const Center(
        child: Text(
          'No conversations found.',
          key: Key('conversation_search_empty'),
        ),
      );
    }
    if (state.status == SessionSearchStatus.failure && state.hits.isEmpty) {
      return _SearchError(message: state.errorMessage, onRetry: onRetry);
    }
    return ListView.builder(
      key: const Key('conversation_search_results'),
      itemCount: state.hits.length + (state.hasMore || state.status == SessionSearchStatus.failure ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == state.hits.length) {
          if (state.status == SessionSearchStatus.loadingMore) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton(
              onPressed: state.status == SessionSearchStatus.failure ? onRetry : onLoadMore,
              child: Text(state.status == SessionSearchStatus.failure ? 'Retry' : 'Load more'),
            ),
          );
        }
        final hit = state.hits[index];
        final workspace = hit.session.workspaceName;
        final kind = switch (hit.matchKind) {
          SessionSearchMatchKind.title => 'Title match',
          SessionSearchMatchKind.content => 'Message match',
          SessionSearchMatchKind.titleAndContent => 'Title and message match',
        };
        return ListTile(
          key: ValueKey('conversation_search_result:${hit.session.id}'),
          selected: index == selectedIndex,
          title: Text(hit.session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  if (workspace != null && workspace.isNotEmpty) workspace,
                  kind,
                  _formatSearchDate(
                    hit.session.lastMessageAt ?? hit.session.updatedAt,
                  ),
                ].join(' · '),
              ),
              if (hit.snippet case final snippet?) Text(snippet, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
          isThreeLine: hit.snippet != null,
          onTap: () => onSelected(hit),
        );
      },
    );
  }
}

String _formatSearchDate(DateTime value) {
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
}

class _SearchError extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;

  const _SearchError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message ?? 'Conversation search failed.', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
