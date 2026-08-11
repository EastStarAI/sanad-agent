import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../devices/domain/models/device_config.dart';
import '../../../../devices/presentation/bloc/device_capabilities_cubit.dart';
import '../../../../devices/presentation/bloc/device_capabilities_state.dart';
import '../../../../devices/domain/models/capability.dart';
import '../../../../../utils/app_platform.dart';
import '../../../domain/models/session.dart';
import '../../../domain/models/session_attention_state.dart';
import '../../bloc/session_cubit.dart';
import '../../bloc/session_state.dart';

enum _RowVisualState {
  permission,
  question,
  blocked,
  waiting,
  stopping,
  running,
  queued,
  normal,
}

/// A single conversation row in the sidebar (Plan 32c Gate C0).
///
/// This is the most granular rebuild unit: a row rebuilds only when its own
/// selection, processing, or pending-suspension slice changes. It reads a
/// narrow [SessionState] projection via `BlocBuilder.buildWhen` and never
/// touches cache or pagination.
///
/// The row emits a navigation intent ([onSelected]) instead of mutating
/// selection directly so the parent owns routing. Rename/delete stay here
/// because they are per-row affordances gated by device capabilities.
class SidebarConversationRow extends StatefulWidget {
  final DeviceConfig device;
  final Session session;
  final bool isDrawerMode;
  final VoidCallback onSelected;

  @visibleForTesting
  static void Function(String deviceId, String sessionId)? debugOnSessionRowBuild;

  const SidebarConversationRow({
    super.key,
    required this.device,
    required this.session,
    required this.onSelected,
    this.isDrawerMode = false,
  });

  @override
  State<SidebarConversationRow> createState() => _SidebarConversationRowState();
}

class _SidebarConversationRowState extends State<SidebarConversationRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SessionCubit, SessionState>(
      key: ValueKey(
        'sidebar-row-state:${widget.device.id}:${widget.session.id}:'
        '${widget.session.updatedAt.microsecondsSinceEpoch}:${widget.session.title}',
      ),
      buildWhen: (previous, current) {
        return _isSelected(previous) != _isSelected(current) || _attention(previous) != _attention(current);
      },
      builder: (context, state) {
        assert(() {
          SidebarConversationRow.debugOnSessionRowBuild?.call(widget.device.id, widget.session.id);
          return true;
        }());
        final isSelected = _isSelected(state);
        final attention = _attention(state);
        final theme = Theme.of(context);

        final visualState = _getVisualState(attention);

        final leadingWidth = 16.0;
        final leadingSize = 14.0;

        final leadingWidget = switch (visualState) {
          _RowVisualState.running => const SizedBox(
            key: Key('sidebar_session_busy_indicator'),
            width: 8,
            height: 8,
            child: _BusyDot(),
          ),
          _RowVisualState.question => Icon(
            Icons.help_outline,
            color: theme.colorScheme.primary,
            size: leadingSize,
          ),
          _RowVisualState.permission => Icon(
            Icons.pending_actions_outlined,
            color: theme.colorScheme.tertiary,
            size: leadingSize,
          ),
          _RowVisualState.blocked => Icon(
            Icons.error_outline,
            color: theme.colorScheme.error,
            size: leadingSize,
          ),
          _RowVisualState.waiting => Icon(
            Icons.schedule_outlined,
            color: theme.colorScheme.tertiary,
            size: leadingSize,
          ),
          _RowVisualState.stopping => Icon(
            Icons.stop_circle_outlined,
            color: theme.colorScheme.error,
            size: leadingSize,
          ),
          _RowVisualState.queued => Icon(
            Icons.queue_outlined,
            color: theme.colorScheme.secondary,
            size: leadingSize,
          ),
          _RowVisualState.normal => const SizedBox.shrink(),
        };

        final leadingContainer = SizedBox(
          width: leadingWidth,
          height: leadingWidth,
          child: Center(
            child: leadingWidget,
          ),
        );

        return MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: Container(
            margin: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 0,
            ),
            decoration: BoxDecoration(
              color: isSelected ? theme.colorScheme.surfaceContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              clipBehavior: Clip.antiAlias,
              child: Semantics(
                button: true,
                selected: isSelected,
                label: 'Conversation ${widget.session.title}',
                child: ListTile(
                  dense: true,
                  minLeadingWidth: leadingWidth,
                  contentPadding: const EdgeInsets.only(
                    left: 8,
                    right: 0,
                  ),
                  minVerticalPadding: 2,
                  title: Text(
                    widget.session.title.replaceAll(RegExp(r'\n'), ' '),
                    maxLines: 1,
                    style: TextStyle(
                      color: isSelected ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: leadingContainer,
                  onTap: widget.onSelected,
                  onLongPress: () {
                    _showMobileSessionOptions(context, widget.device, widget.session);
                  },
                  trailing: _SidebarSessionTrailing(
                    device: widget.device,
                    session: widget.session,
                    isHovered: _isHovered,
                    isDrawerMode: widget.isDrawerMode,
                  ),
                  hoverColor: theme.colorScheme.surfaceContainer.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool _isSelected(SessionState state) =>
      state.selectedSession?.id == widget.session.id && state.selectedSession?.deviceId == widget.device.id;
  SessionAttentionState? _attention(SessionState state) => state.attentionStateFor(widget.device.id, widget.session.id);

  _RowVisualState _getVisualState(SessionAttentionState? attention) {
    return switch (attention?.visualState) {
      SessionAttentionVisualState.userQuestionOrPermission =>
        attention?.pendingSuspendedRequest?.toolName == 'system_ask_user'
            ? _RowVisualState.question
            : _RowVisualState.permission,
      SessionAttentionVisualState.blockedOrFatal => _RowVisualState.blocked,
      SessionAttentionVisualState.waiting => _RowVisualState.waiting,
      SessionAttentionVisualState.stopping => _RowVisualState.stopping,
      SessionAttentionVisualState.runningOrResuming => _RowVisualState.running,
      SessionAttentionVisualState.queued => _RowVisualState.queued,
      SessionAttentionVisualState.normal || null => _RowVisualState.normal,
    };
  }
}

String formatCompactRelativeTime(DateTime dateTime) {
  final now = DateTime.now();
  final diff = now.difference(dateTime);

  if (diff.isNegative || diff.inSeconds < 10) {
    return 'now';
  }
  if (diff.inSeconds < 60) {
    return '${diff.inSeconds}s';
  }
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes}m';
  }
  if (diff.inHours < 24) {
    return '${diff.inHours}h';
  }
  if (diff.inDays < 7) {
    return '${diff.inDays}d';
  }
  if (diff.inDays < 30) {
    final weeks = (diff.inDays / 7).floor();
    return '${weeks}w';
  }
  if (diff.inDays < 365) {
    final months = (diff.inDays / 30).floor();
    return '${months}mo';
  }
  final years = (diff.inDays / 365).floor();
  return '${years}y';
}

void _showMobileSessionOptions(
  BuildContext context,
  DeviceConfig device,
  Session session, [
  Capability? capabilities,
]) {
  final caps = capabilities ?? context.read<DeviceCapabilitiesCubit>().state.getForAgent(device.id);
  final hasOptions = caps.supportsUpdateSessionName || caps.supportsDeleteSession;
  if (!hasOptions) return;

  final sessionCubit = context.read<SessionCubit>();
  final theme = Theme.of(context);

  unawaited(
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const Divider(height: 1),
              if (caps.supportsUpdateSessionName)
                ListTile(
                  leading: Icon(Icons.edit_outlined, size: 20, color: theme.colorScheme.onSurface),
                  title: const Text('Rename', style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showRenameDialog(context, sessionCubit, device, session);
                  },
                ),
              if (caps.supportsDeleteSession)
                ListTile(
                  leading: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                  title: const Text('Delete', style: TextStyle(fontSize: 14, color: Colors.redAccent)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showDeleteConfirmation(context, sessionCubit, device, session);
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

void _showRenameDialog(BuildContext context, SessionCubit sessionCubit, DeviceConfig device, Session session) {
  var titleText = session.title;
  void onRename() {
    final text = titleText.trim();
    if (text.isNotEmpty) {
      unawaited(sessionCubit.updateSessionTitle(agent: device, session: session, title: text));
      Navigator.pop(context);
    }
  }

  unawaited(
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Session'),
        content: TextFormField(
          initialValue: session.title,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'New title'),
          onChanged: (val) => titleText = val,
          onFieldSubmitted: (_) => onRename(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: onRename, child: const Text('Rename')),
        ],
      ),
    ),
  );
}

void _showDeleteConfirmation(BuildContext context, SessionCubit sessionCubit, DeviceConfig device, Session session) {
  unawaited(
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Session'),
        content: Text('Are you sure you want to delete "${session.title}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              await sessionCubit.deleteSession(agent: device, session: session);
              switch (context.mounted) {
                case true:
                  Navigator.pop(context);
                case false:
                  break;
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    ),
  );
}

class _SidebarSessionTrailing extends StatelessWidget {
  final DeviceConfig device;
  final Session session;
  final bool isHovered;
  final bool isDrawerMode;

  const _SidebarSessionTrailing({
    required this.device,
    required this.session,
    required this.isHovered,
    required this.isDrawerMode,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = AppPlatform.isMobile;
    final theme = Theme.of(context);

    return BlocSelector<DeviceCapabilitiesCubit, DeviceCapabilitiesState, Capability>(
      selector: (state) => state.getForAgent(device.id),
      builder: (context, caps) {
        final hasOptions = caps.supportsUpdateSessionName || caps.supportsDeleteSession;

        if (isMobile) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (hasOptions) {
                _showMobileSessionOptions(context, device, session, caps);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                formatCompactRelativeTime(session.updatedAt),
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          );
        }

        if (isHovered && hasOptions) {
          return PopupMenuButton<String>(
            tooltip: '',
            icon: Icon(
              Icons.more_vert,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              size: 14,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 32,
              minHeight: 32,
            ),
            onSelected: (value) {
              final sessionCubit = context.read<SessionCubit>();
              switch (value) {
                case 'rename':
                  _showRenameDialog(context, sessionCubit, device, session);
                case 'delete':
                  _showDeleteConfirmation(context, sessionCubit, device, session);
              }
            },
            itemBuilder: (context) => [
              ...switch (caps.supportsUpdateSessionName) {
                true => [
                  PopupMenuItem(
                    value: 'rename',
                    height: 32,
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Text(
                          'Rename',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
                false => const <PopupMenuItem<String>>[],
              },
              ...switch (caps.supportsDeleteSession) {
                true => [
                  PopupMenuItem(
                    value: 'delete',
                    height: 32,
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
                        const SizedBox(width: 8),
                        const Text('Delete', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
                false => const <PopupMenuItem<String>>[],
              },
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            formatCompactRelativeTime(session.updatedAt),
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              fontSize: 10,
              fontWeight: FontWeight.w400,
            ),
          ),
        );
      },
    );
  }
}

/// Animates reorder/insert/delete changes for a small sidebar section without
/// taking ownership of ordering. The cache/store still provides the canonical
/// child order; this widget gives moved items a smooth slide transition using
/// position-tracking so live user-message bumps are visible and keep scroll
/// position intact.
///
/// Each child must use a stable key (typically [ValueKey] with the session id)
/// so the framework's reconciliation maps old children to new children
/// correctly. This widget tracks the screen position of each item before and
/// after a data change, then applies a [Transform.translate] that eases the
/// item from its old visual position to its new one.
class AnimatedListDiffColumn extends StatefulWidget {
  final List<String> itemIds;
  final List<Widget> children;
  final Duration duration;
  final Curve curve;

  const AnimatedListDiffColumn({
    super.key,
    required this.itemIds,
    required this.children,
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.easeOutCubic,
  }) : assert(itemIds.length == children.length);

  @override
  State<AnimatedListDiffColumn> createState() => _AnimatedListDiffColumnState();
}

class _AnimatedListDiffColumnState extends State<AnimatedListDiffColumn> with TickerProviderStateMixin {
  final Map<String, GlobalKey> _itemKeys = {};
  Map<String, double> _oldPositions = const {};
  final Map<String, AnimationController> _moveControllers = {};
  final Map<String, Animation<double>> _moveAnimations = {};
  bool _pendingMoveCheck = false;

  @override
  void initState() {
    super.initState();
    for (final id in widget.itemIds) {
      _itemKeys[id] = GlobalKey();
    }
  }

  @override
  void didUpdateWidget(AnimatedListDiffColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    _recordPositions();
    final newIds = Set<String>.from(widget.itemIds);
    _itemKeys.removeWhere((id, _) => !newIds.contains(id));
    for (final id in widget.itemIds) {
      _itemKeys.putIfAbsent(id, () => GlobalKey());
    }
    _pendingMoveCheck = true;
  }

  void _recordPositions() {
    final parentBox = context.findRenderObject() as RenderBox?;
    if (parentBox == null || !parentBox.hasSize) return;

    final positions = <String, double>{};
    for (final entry in _itemKeys.entries) {
      final renderBox = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox?.hasSize == true) {
        positions[entry.key] = renderBox!.localToGlobal(Offset.zero, ancestor: parentBox).dy;
      }
    }
    _oldPositions = positions;
  }

  @override
  void dispose() {
    for (final controller in _moveControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingMoveCheck) {
      _pendingMoveCheck = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkMoves());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.children.length; i++) _buildAnimatedItem(i),
      ],
    );
  }

  Widget _buildAnimatedItem(int index) {
    final id = widget.itemIds[index];
    final child = SizedBox(
      key: _itemKeys[id],
      child: widget.children[index],
    );

    final moveAnimation = _moveAnimations[id];
    if (moveAnimation != null) {
      return AnimatedBuilder(
        animation: moveAnimation,
        builder: (context, animatedChild) {
          return Transform.translate(
            offset: Offset(0, moveAnimation.value),
            child: animatedChild,
          );
        },
        child: child,
      );
    }

    return child;
  }

  void _checkMoves() {
    if (!mounted) return;
    final parentBox = context.findRenderObject() as RenderBox?;
    if (parentBox == null || !parentBox.hasSize) return;

    final newPositions = <String, double>{};
    for (final entry in _itemKeys.entries) {
      final renderBox = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox?.hasSize == true) {
        newPositions[entry.key] = renderBox!.localToGlobal(Offset.zero, ancestor: parentBox).dy;
      }
    }

    final oldPositions = _oldPositions;
    final controllersToStart = <AnimationController>[];

    for (final id in widget.itemIds) {
      final oldPos = oldPositions[id];
      final newPos = newPositions[id];
      if (oldPos == null || newPos == null) continue;

      final delta = oldPos - newPos;
      if (delta.abs() <= 0.5) continue;

      _moveControllers[id]?.dispose();

      final controller = AnimationController(
        vsync: this,
        duration: widget.duration,
      );
      final animation = Tween<double>(begin: delta, end: 0.0).animate(
        CurvedAnimation(parent: controller, curve: widget.curve),
      );

      _moveControllers[id] = controller;
      _moveAnimations[id] = animation;
      controllersToStart.add(controller);

      controller.addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          if (!mounted) return;
          setState(() {
            _moveControllers[id]?.dispose();
            _moveControllers.remove(id);
            _moveAnimations.remove(id);
          });
        }
      });
    }

    _oldPositions = newPositions;
    if (controllersToStart.isEmpty) return;
    setState(() {});
    for (final controller in controllersToStart) {
      unawaited(controller.forward());
    }
  }
}

class _BusyDot extends StatefulWidget {
  const _BusyDot();
  @override
  State<_BusyDot> createState() => _BusyDotState();
}

class _BusyDotState extends State<_BusyDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    unawaited(_controller.repeat(reverse: true));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}
