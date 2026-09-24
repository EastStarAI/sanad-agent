import 'package:logging/logging.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';

/// Horizontal selector for agents and their sessions.
/// Displayed at the bottom of VoiceAgentView during a voice call.
class SessionSelector extends StatefulWidget {
  static final _logger = Logger('SessionSelector');

  final String? selectedAgentId;
  final String? selectedSessionId;
  final ValueChanged<String> onAgentSelected;
  final ValueChanged<String> onSessionSelected;

  const SessionSelector({
    super.key,
    this.selectedAgentId,
    this.selectedSessionId,
    required this.onAgentSelected,
    required this.onSessionSelected,
  });

  @override
  State<SessionSelector> createState() => _SessionSelectorState();
}

class _SessionSelectorState extends State<SessionSelector> {
  List<Session> _sessions = [];
  bool _loadingSessions = false;
  StreamSubscription<List<Session>>? _sessionsSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.selectedAgentId != null) {
      unawaited(_watchSessionsForAgent(widget.selectedAgentId!));
    }
  }

  @override
  void didUpdateWidget(covariant SessionSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedAgentId != oldWidget.selectedAgentId && widget.selectedAgentId != null) {
      unawaited(_watchSessionsForAgent(widget.selectedAgentId!));
    }
  }

  Future<void> _watchSessionsForAgent(String deviceId) async {
    await _sessionsSubscription?.cancel();
    setState(() {
      _loadingSessions = true;
      _sessions = [];
    });

    try {
      final agentCubit = context.read<DeviceCubit>();
      final agents = agentCubit.state is DeviceActive
          ? (agentCubit.state as DeviceActive).agents
          : (agentCubit.state is DeviceNoActive ? (agentCubit.state as DeviceNoActive).agents : <DeviceConfig>[]);

      final agent = agents.where((a) => a.id == deviceId).firstOrNull;
      if (agent == null) {
        if (mounted) {
          setState(() {
            _loadingSessions = false;
          });
        }
        return;
      }

      final conversationRepository = getIt<ConversationRepository>();
      _sessionsSubscription = conversationRepository
          .watchSessions(agent)
          .listen(
            (sessions) {
              if (!mounted) return;
              setState(() {
                _sessions = sessions;
                _loadingSessions = false;
              });
            },
            onError: (error, _) {
              SessionSelector._logger.severe('[SessionSelector] Error watching sessions: $error');
              if (mounted) {
                setState(() {
                  _loadingSessions = false;
                });
              }
            },
          );
    } catch (e) {
      SessionSelector._logger.severe('[SessionSelector] Error watching sessions: $e');
      if (mounted) {
        setState(() {
          _loadingSessions = false;
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_sessionsSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceCubit, DeviceState>(
      builder: (context, agentState) {
        final agents = agentState is DeviceActive
            ? agentState.agents
            : (agentState is DeviceNoActive ? agentState.agents : <DeviceConfig>[]);

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outline, width: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Agents Row
              SizedBox(
                height: 48,
                child: agents.isEmpty
                    ? Center(
                        child: Text(
                          'No agents available',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        itemCount: agents.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final agent = agents[index];
                          final isSelected = agent.id == widget.selectedAgentId;

                          return GestureDetector(
                            onTap: () => widget.onAgentSelected(agent.id),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                                  width: isSelected ? 1.5 : 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Online indicator
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: agent.isOnline
                                          ? Theme.of(context).colorScheme.primary
                                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    agent.name,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Theme.of(context).colorScheme.primary
                                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                      fontSize: 12,
                                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              // Sessions Row
              if (widget.selectedAgentId != null)
                SizedBox(
                  height: 40,
                  child: _loadingSessions
                      ? Center(
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: AppProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.38),
                            ),
                          ),
                        )
                      : _sessions.isEmpty
                      ? Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'No sessions',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.24),
                                fontSize: 11,
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          itemCount: _sessions.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 6),
                          itemBuilder: (context, index) {
                            final session = _sessions[index];
                            final isSelected = session.id == widget.selectedSessionId;

                            return GestureDetector(
                              onTap: () => widget.onSessionSelected(session.id),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                                      : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                                    width: isSelected ? 1.5 : 1,
                                  ),
                                ),
                                child: Text(
                                  session.title,
                                  style: TextStyle(
                                    color: isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontSize: 11,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          },
                        ),
                ),
            ],
          ),
        );
      },
    );
  }
}
