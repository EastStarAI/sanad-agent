import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'tray_menu_descriptor.dart';

class TrayMenuBuilder {
  static const int maxRecentConversations = 5;
  static const int maxTitleLength = 35;

  static String truncate(String text, {int maxLength = maxTitleLength}) {
    final singleLine = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (singleLine.isEmpty) return 'New Chat';
    if (singleLine.length <= maxLength) return singleLine;
    return '${singleLine.substring(0, maxLength - 3)}...';
  }

  static List<Session> sortRecentConversations(
    Iterable<Session> sessions, {
    int limit = maxRecentConversations,
  }) {
    final list = List<Session>.from(sessions);
    list.sort((a, b) {
      final am = a.lastMessageAt;
      final bm = b.lastMessageAt;
      if (am != null && bm != null) {
        final cmp = bm.compareTo(am);
        if (cmp != 0) return cmp;
      } else if (am != null) {
        return -1;
      } else if (bm != null) {
        return 1;
      }
      final ucmp = b.updatedAt.compareTo(a.updatedAt);
      if (ucmp != 0) return ucmp;
      return a.id.compareTo(b.id);
    });
    return list.take(limit).toList();
  }

  static List<TrayMenuItemDescriptor> buildMenu({
    required List<Session> recentConversations,
    required bool isAgentRunning,
    required bool isClientCliEnabled,
    required void Function() onShow,
    required void Function(Session session) onSelectConversation,
    required void Function() onAgentAction,
    required void Function() onToggleClientCli,
    required void Function() onQuit,
  }) {
    final items = <TrayMenuItemDescriptor>[
      TrayMenuItemDescriptor.action(
        key: 'show',
        label: 'Show',
        onSelected: onShow,
      ),
      const TrayMenuItemDescriptor.separator(key: 'sep_1'),
    ];

    // Recent conversations (up to 5, never more than 5)
    final sorted = sortRecentConversations(recentConversations, limit: maxRecentConversations);
    if (sorted.isEmpty) {
      items.add(const TrayMenuItemDescriptor.info(
        key: 'recent_empty',
        label: 'No recent conversations',
      ));
    } else {
      for (final session in sorted) {
        items.add(TrayMenuItemDescriptor.action(
          key: 'session_${session.id}',
          label: truncate(session.title),
          onSelected: () => onSelectConversation(session),
        ));
      }
    }

    items.addAll([
      const TrayMenuItemDescriptor.separator(key: 'sep_2'),
      // Local Agent status & action
      TrayMenuItemDescriptor.info(
        key: 'agent_status',
        label: isAgentRunning ? 'Agent: Running' : 'Agent: Stopped',
      ),
      TrayMenuItemDescriptor.action(
        key: isAgentRunning ? 'restart_agent' : 'start_agent',
        label: isAgentRunning ? 'Restart Agent' : 'Start Agent',
        onSelected: onAgentAction,
      ),
      const TrayMenuItemDescriptor.separator(key: 'sep_3'),
      // Client CLI status & toggle
      TrayMenuItemDescriptor.action(
        key: 'toggle_client_cli',
        label: isClientCliEnabled ? 'Client CLI: Enabled' : 'Client CLI: Disabled',
        onSelected: onToggleClientCli,
      ),
      const TrayMenuItemDescriptor.separator(key: 'sep_4'),
      // Explicit Quit
      TrayMenuItemDescriptor.action(
        key: 'quit',
        label: 'Quit',
        onSelected: onQuit,
      ),
    ]);

    return items;
  }
}
