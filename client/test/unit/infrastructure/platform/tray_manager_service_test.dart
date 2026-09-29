import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_host.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_settings.dart';
import 'package:sanad_client/features/client_cli/presentation/bloc/client_cli_cubit.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/infrastructure/platform/desktop_lifecycle_manager.dart';
import 'package:sanad_client/infrastructure/platform/tray_manager_service.dart';
import 'package:sanad_client/infrastructure/platform/tray_menu_descriptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeTrayManagerAdapter implements TrayManagerAdapter {
  int initializeCalls = 0;
  String? lastIconPath;
  String? lastTooltip;
  void Function()? onTrayClickCallback;
  List<List<TrayMenuItemDescriptor>> setMenuHistory = [];
  int destroyCalls = 0;

  @override
  Future<void> initialize({
    required String iconAssetPath,
    required String tooltip,
    required void Function() onTrayIconClick,
  }) async {
    initializeCalls++;
    lastIconPath = iconAssetPath;
    lastTooltip = tooltip;
    onTrayClickCallback = onTrayIconClick;
  }

  @override
  Future<void> setContextMenu(List<TrayMenuItemDescriptor> items) async {
    setMenuHistory.add(items);
  }

  @override
  Future<void> destroy() async {
    destroyCalls++;
  }
}

class FakeDaemonController implements LocalDaemonController {
  bool running = false;
  int isDaemonRunningCalls = 0;
  int startDaemonCalls = 0;
  int restartDaemonCalls = 0;
  Completer<bool>? pendingActionCompleter;

  @override
  Future<bool> isDaemonRunning() async {
    isDaemonRunningCalls++;
    return running;
  }

  @override
  Future<bool> startDaemon() async {
    startDaemonCalls++;
    if (pendingActionCompleter != null) {
      await pendingActionCompleter!.future;
    }
    running = true;
    return true;
  }

  @override
  Future<bool> restartDaemon() async {
    restartDaemonCalls++;
    if (pendingActionCompleter != null) {
      await pendingActionCompleter!.future;
    }
    running = true;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async => null;

  @override
  Future<String?> getDaemonVersion() async => '1.0.15';

  @override
  Future<bool> stopDaemon() async {
    running = false;
    return true;
  }

  @override
  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async =>
      const AgentLifecycleResult(AgentLifecycleStatus.ready);

  @override
  bool isServiceInstalled() => true;

  @override
  bool get shouldAutoStart => false;

  @override
  Future<bool> install() async => true;
}

class FakeClientCliHost implements ClientCliHost {
  ClientCliSettings lastSettings = const ClientCliSettings();
  int updateSettingsCalls = 0;
  int stopCalls = 0;

  ClientCliSettings get currentSettings => lastSettings;

  @override
  Future<void> updateSettings({required bool enabled, required String permissionMode}) async {
    updateSettingsCalls++;
    lastSettings = ClientCliSettings(enabled: enabled, permissionMode: permissionMode);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDesktopWindowManagerAdapter implements DesktopWindowManagerAdapter {
  int showCalls = 0;
  int hideCalls = 0;
  int focusCalls = 0;
  int destroyCalls = 0;

  @override
  Future<void> show() async => showCalls++;
  @override
  Future<void> hide() async => hideCalls++;
  @override
  Future<void> focus() async => focusCalls++;
  @override
  Future<void> setPreventClose(bool prevent) async {}
  @override
  Future<void> destroy() async => destroyCalls++;
}

void main() {
  group('AppTrayService', () {
    late FakeTrayManagerAdapter adapter;
    late ConversationCacheStore cacheStore;
    late FakeDaemonController daemonController;
    late FakeClientCliHost cliHost;
    late SharedPreferences prefs;
    late ClientCliCubit cliCubit;
    late FakeDesktopWindowManagerAdapter windowAdapter;
    late DesktopLifecycleManager lifecycleManager;
    ConversationDestination? navigatedDestination;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      adapter = FakeTrayManagerAdapter();
      cacheStore = ConversationCacheStore();
      daemonController = FakeDaemonController();
      cliHost = FakeClientCliHost();
      cliCubit = ClientCliCubit(host: cliHost, prefs: prefs);
      windowAdapter = FakeDesktopWindowManagerAdapter();
      lifecycleManager = DesktopLifecycleManager(windowAdapter: windowAdapter);
      navigatedDestination = null;
    });

    AppTrayService createService({
      void Function(ConversationDestination destination)? onNavigate,
    }) {
      return AppTrayService(
        adapter: adapter,
        conversationCacheStore: cacheStore,
        clientCliCubit: cliCubit,
        daemonController: daemonController,
        lifecycleManager: lifecycleManager,
        onNavigate: onNavigate ?? (d) => navigatedDestination = d,
      );
    }

    test('initialize registers icon, tooltip, click listener and sets initial menu', () async {
      final service = createService();

      expect(service.isInitialized, isFalse);
      await service.initialize(iconAssetPath: 'assets/app-logo.png', tooltip: 'Sanad');

      expect(service.isInitialized, isTrue);
      expect(adapter.initializeCalls, equals(1));
      expect(adapter.lastIconPath, equals('assets/app-logo.png'));
      expect(adapter.lastTooltip, equals('Sanad'));
      expect(adapter.setMenuHistory, isNotEmpty);
      expect(adapter.onTrayClickCallback, isNotNull);

      // Clicking the tray icon restores window
      adapter.onTrayClickCallback!();
      await Future<void>.delayed(Duration.zero);
      expect(windowAdapter.showCalls, equals(1));
      expect(windowAdapter.focusCalls, equals(1));

      await service.destroy();
    });

    test('extractRecentConversations aggregates, deduplicates and sorts across all devices', () async {
      final now = DateTime.now();
      final s1 = Session(
        id: 's1',
        title: 'Conversation 1',
        createdAt: now,
        updatedAt: now,
        lastMessageAt: now.subtract(const Duration(minutes: 5)),
      );
      final s2 = Session(
        id: 's2',
        title: 'Conversation 2',
        createdAt: now,
        updatedAt: now,
        lastMessageAt: now.subtract(const Duration(minutes: 1)),
      );

      cacheStore.applySessionCreated('device_1', s1);
      cacheStore.applySessionCreated('device_2', s2);

      final service = createService();
      final recent = service.extractRecentConversations();

      expect(recent.length, equals(2));
      expect(recent.first.id, equals('s2'));
      expect(recent.first.deviceId, equals('device_2'));
      expect(recent.last.id, equals('s1'));
      expect(recent.last.deviceId, equals('device_1'));
    });

    test('handleSelectConversation shows window and invokes navigation with Session destination', () async {
      final now = DateTime.now();
      final session = Session(
        id: 'session_target',
        title: 'Target Session',
        deviceId: 'device_abc',
        workspaceId: 'ws_123',
        createdAt: now,
        updatedAt: now,
      );

      final service = createService();
      service.handleSelectConversation(session);
      await Future<void>.delayed(Duration.zero);

      expect(windowAdapter.showCalls, equals(1));
      expect(windowAdapter.focusCalls, equals(1));
      expect(navigatedDestination, isNotNull);
      expect(navigatedDestination!.isSession, isTrue);
      expect(navigatedDestination!.deviceId, equals('device_abc'));
      expect(navigatedDestination!.sessionId, equals('session_target'));
      expect(navigatedDestination!.workspaceId, equals('ws_123'));
    });

    test('handleAgentAction when daemon is stopped calls startDaemon exactly once and refreshes menu', () async {
      daemonController.running = false;
      final service = createService();
      await service.initialize();

      adapter.setMenuHistory.clear();
      await service.handleAgentAction();

      expect(daemonController.startDaemonCalls, equals(1));
      expect(daemonController.restartDaemonCalls, equals(0));
      expect(daemonController.running, isTrue);
      expect(adapter.setMenuHistory, isNotEmpty);

      // Latest menu projection reflects that Agent is now Running
      final latestMenu = adapter.setMenuHistory.last;
      final statusItem = latestMenu.firstWhere((i) => i.key == 'agent_status');
      expect(statusItem.label, equals('Agent: Running'));
      expect(latestMenu.any((i) => i.key == 'restart_agent'), isTrue);

      await service.destroy();
    });

    test('handleAgentAction when daemon is running calls restartDaemon exactly once and refreshes menu', () async {
      daemonController.running = true;
      final service = createService();
      await service.initialize();

      adapter.setMenuHistory.clear();
      await service.handleAgentAction();

      expect(daemonController.restartDaemonCalls, equals(1));
      expect(daemonController.startDaemonCalls, equals(0));
      expect(adapter.setMenuHistory, isNotEmpty);

      await service.destroy();
    });

    test('handleAgentAction guards against concurrent double-clicks', () async {
      daemonController.running = false;
      final completer = Completer<bool>();
      daemonController.pendingActionCompleter = completer;

      final service = createService();
      await service.initialize();

      final firstCall = service.handleAgentAction();
      final secondCall = service.handleAgentAction();

      completer.complete(true);
      await Future.wait([firstCall, secondCall]);

      expect(daemonController.startDaemonCalls, equals(1));

      await service.destroy();
    });

    test('handleToggleClientCli flips settings and refreshes menu', () async {
      expect(cliCubit.state.enabled, isFalse);

      final service = createService();
      await service.initialize();

      adapter.setMenuHistory.clear();
      await service.handleToggleClientCli();

      expect(cliCubit.state.enabled, isTrue);
      expect(adapter.setMenuHistory, isNotEmpty);

      final latestMenu = adapter.setMenuHistory.last;
      final cliItem = latestMenu.firstWhere((i) => i.key == 'toggle_client_cli');
      expect(cliItem.label, equals('Client CLI: Enabled'));

      await service.destroy();
    });

    test('destroy unsubscribes streams and disposes adapter', () async {
      final service = createService();
      await service.initialize();

      await service.destroy();

      expect(service.isInitialized, isFalse);
      expect(adapter.destroyCalls, equals(1));
    });

    test('refreshMenu with unchanged items does not rebuild menu when force is false', () async {
      final service = createService();
      await service.initialize();

      adapter.setMenuHistory.clear();
      await service.refreshMenu(force: false);

      expect(adapter.setMenuHistory, isEmpty);

      await service.refreshMenu(force: true);
      expect(adapter.setMenuHistory, hasLength(1));

      await service.destroy();
    });

    test('snapshotStream triggers debounced refresh and updates menu', () async {
      final service = createService();
      await service.initialize();

      adapter.setMenuHistory.clear();

      final now = DateTime.now();
      final session = Session(
        id: 'new_streamed_session',
        title: 'New Streamed Chat',
        createdAt: now,
        updatedAt: now,
      );
      cacheStore.applySessionCreated('device_1', session);

      // Debounce delay is 200ms
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(adapter.setMenuHistory, isNotEmpty);
      final latestMenu = adapter.setMenuHistory.last;
      expect(latestMenu.any((i) => i.key == 'session_new_streamed_session'), isTrue);

      await service.destroy();
    });

    test('handleSelectConversation with empty deviceId logs and does not navigate', () async {
      final now = DateTime.now();
      final session = Session(
        id: 'orphan_session',
        title: 'Orphan Chat',
        deviceId: '',
        createdAt: now,
        updatedAt: now,
      );

      final service = createService();
      service.handleSelectConversation(session);
      await Future<void>.delayed(Duration.zero);

      expect(navigatedDestination, isNull);
    });

    test('extractRecentConversations prefers newer timestamp when duplicate session ids exist', () async {
      final now = DateTime.now();
      final older = Session(
        id: 'dup_session',
        title: 'Older Session',
        createdAt: now.subtract(const Duration(hours: 2)),
        updatedAt: now.subtract(const Duration(hours: 1)),
      );
      final newer = Session(
        id: 'dup_session',
        title: 'Newer Session',
        createdAt: now.subtract(const Duration(hours: 2)),
        updatedAt: now,
      );

      cacheStore.applySessionCreated('device_old', older);
      cacheStore.applySessionCreated('device_new', newer);

      final service = createService();
      final recent = service.extractRecentConversations();

      expect(recent, hasLength(1));
      expect(recent.first.title, equals('Newer Session'));
      expect(recent.first.deviceId, equals('device_new'));
    });
  });
}
