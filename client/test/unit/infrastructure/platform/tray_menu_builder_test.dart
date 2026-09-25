import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/infrastructure/platform/tray_menu_builder.dart';
import 'package:sanad_client/infrastructure/platform/tray_menu_descriptor.dart';

void main() {
  group('TrayMenuBuilder', () {
    test('truncate returns New Chat for empty or whitespace strings', () {
      expect(TrayMenuBuilder.truncate(''), equals('New Chat'));
      expect(TrayMenuBuilder.truncate('   '), equals('New Chat'));
    });

    test('truncate preserves short titles and truncates titles exceeding limit', () {
      expect(TrayMenuBuilder.truncate('Short Title'), equals('Short Title'));
      final longTitle = 'A' * 50;
      final truncated = TrayMenuBuilder.truncate(longTitle, maxLength: 35);
      expect(truncated.length, equals(35));
      expect(truncated.endsWith('...'), isTrue);
    });

    test('sortRecentConversations orders by lastMessageAt desc, then updatedAt desc, then id asc', () {
      final now = DateTime.now();
      final s1 = Session(
        id: 's1',
        title: 'Session 1',
        createdAt: now.subtract(const Duration(hours: 5)),
        updatedAt: now.subtract(const Duration(hours: 4)),
        lastMessageAt: now.subtract(const Duration(minutes: 10)),
      );
      final s2 = Session(
        id: 's2',
        title: 'Session 2',
        createdAt: now.subtract(const Duration(hours: 5)),
        updatedAt: now.subtract(const Duration(hours: 3)),
        lastMessageAt: now.subtract(const Duration(minutes: 5)), // most recent message
      );
      final s3 = Session(
        id: 's3',
        title: 'Session 3',
        createdAt: now.subtract(const Duration(hours: 5)),
        updatedAt: now.subtract(const Duration(hours: 1)), // newer update, but null lastMessageAt
        lastMessageAt: null,
      );
      final s4 = Session(
        id: 's4',
        title: 'Session 4',
        createdAt: now.subtract(const Duration(hours: 5)),
        updatedAt: now.subtract(const Duration(hours: 2)), // older update, null lastMessageAt
        lastMessageAt: null,
      );
      final s5 = Session(
        id: 's5',
        title: 'Session 5',
        createdAt: now.subtract(const Duration(hours: 5)),
        updatedAt: now.subtract(const Duration(hours: 1)),
        lastMessageAt: null, // same updatedAt as s3, but id 's5' > 's3'
      );

      final sorted = TrayMenuBuilder.sortRecentConversations([s1, s2, s3, s4, s5]);

      expect(sorted.map((s) => s.id).toList(), equals(['s2', 's1', 's3', 's5', 's4']));
    });

    test('sortRecentConversations never returns more than five items', () {
      final now = DateTime.now();
      final sessions = List.generate(
        10,
        (i) => Session(
          id: 'session_$i',
          title: 'Title $i',
          createdAt: now,
          updatedAt: now.subtract(Duration(minutes: i)),
        ),
      );

      final sorted = TrayMenuBuilder.sortRecentConversations(sessions, limit: 5);
      expect(sorted.length, equals(5));
      expect(sorted.first.id, equals('session_0'));
      expect(sorted.last.id, equals('session_4'));
    });

    test('buildMenu with empty conversations projects No recent conversations fallback', () {
      final menu = TrayMenuBuilder.buildMenu(
        recentConversations: const [],
        isAgentRunning: false,
        isClientCliEnabled: false,
        onShow: () {},
        onSelectConversation: (_) {},
        onAgentAction: () {},
        onToggleClientCli: () {},
        onQuit: () {},
      );

      final fallback = menu.firstWhere((item) => item.key == 'recent_empty');
      expect(fallback.label, equals('No recent conversations'));
      expect(fallback.isEnabled, isFalse);
      expect(fallback.kind, equals(TrayMenuItemKind.info));
    });

    test('buildMenu when Agent is running shows Running status and Restart Agent action', () {
      final menu = TrayMenuBuilder.buildMenu(
        recentConversations: const [],
        isAgentRunning: true,
        isClientCliEnabled: true,
        onShow: () {},
        onSelectConversation: (_) {},
        onAgentAction: () {},
        onToggleClientCli: () {},
        onQuit: () {},
      );

      final statusItem = menu.firstWhere((item) => item.key == 'agent_status');
      expect(statusItem.label, equals('Agent: Running'));
      expect(statusItem.isEnabled, isFalse);

      final actionItem = menu.firstWhere((item) => item.key == 'restart_agent');
      expect(actionItem.label, equals('Restart Agent'));
      expect(actionItem.isEnabled, isTrue);

      final cliItem = menu.firstWhere((item) => item.key == 'toggle_client_cli');
      expect(cliItem.label, equals('Client CLI: Enabled'));
    });

    test('buildMenu when Agent is stopped shows Stopped status and Start Agent action', () {
      final menu = TrayMenuBuilder.buildMenu(
        recentConversations: const [],
        isAgentRunning: false,
        isClientCliEnabled: false,
        onShow: () {},
        onSelectConversation: (_) {},
        onAgentAction: () {},
        onToggleClientCli: () {},
        onQuit: () {},
      );

      final statusItem = menu.firstWhere((item) => item.key == 'agent_status');
      expect(statusItem.label, equals('Agent: Stopped'));

      final actionItem = menu.firstWhere((item) => item.key == 'start_agent');
      expect(actionItem.label, equals('Start Agent'));

      final cliItem = menu.firstWhere((item) => item.key == 'toggle_client_cli');
      expect(cliItem.label, equals('Client CLI: Disabled'));
    });

    test('buildMenu wires callbacks for conversation selection, cli toggle, agent action, show, and quit', () async {
      final now = DateTime.now();
      final session = Session(
        id: 's_test',
        title: 'Project Planning',
        createdAt: now,
        updatedAt: now,
      );

      Session? selectedSession;
      bool showCalled = false;
      bool agentCalled = false;
      bool cliToggled = false;
      bool quitCalled = false;

      final menu = TrayMenuBuilder.buildMenu(
        recentConversations: [session],
        isAgentRunning: true,
        isClientCliEnabled: false,
        onShow: () => showCalled = true,
        onSelectConversation: (s) => selectedSession = s,
        onAgentAction: () => agentCalled = true,
        onToggleClientCli: () => cliToggled = true,
        onQuit: () => quitCalled = true,
      );

      final showItem = menu.firstWhere((item) => item.key == 'show');
      await showItem.onSelected?.call();
      expect(showCalled, isTrue);

      final sessionItem = menu.firstWhere((item) => item.key == 'session_s_test');
      expect(sessionItem.label, equals('Project Planning'));
      await sessionItem.onSelected?.call();
      expect(selectedSession?.id, equals('s_test'));

      final agentItem = menu.firstWhere((item) => item.key == 'restart_agent');
      await agentItem.onSelected?.call();
      expect(agentCalled, isTrue);

      final cliItem = menu.firstWhere((item) => item.key == 'toggle_client_cli');
      await cliItem.onSelected?.call();
      expect(cliToggled, isTrue);

      final quitItem = menu.firstWhere((item) => item.key == 'quit');
      await quitItem.onSelected?.call();
      expect(quitCalled, isTrue);
    });

    test('truncate flattens multiline titles and trims excess whitespace', () {
      expect(TrayMenuBuilder.truncate('Line 1\nLine 2\r\nLine 3'), equals('Line 1 Line 2 Line 3'));
      expect(TrayMenuBuilder.truncate('   \n\r\n  '), equals('New Chat'));
    });

    test('TrayMenuItemDescriptor equality and hashCode match by attributes', () {
      const item1 = TrayMenuItemDescriptor(key: 'a', label: 'Item A', kind: TrayMenuItemKind.action, isEnabled: true);
      const item2 = TrayMenuItemDescriptor(key: 'a', label: 'Item A', kind: TrayMenuItemKind.action, isEnabled: true);
      const item3 = TrayMenuItemDescriptor(key: 'b', label: 'Item A', kind: TrayMenuItemKind.action, isEnabled: true);

      expect(item1, equals(item2));
      expect(item1.hashCode, equals(item2.hashCode));
      expect(item1, isNot(equals(item3)));
    });
  });
}
