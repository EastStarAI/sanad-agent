import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/presentation/widgets/installation_terminal_view.dart';
import 'package:sanad_client/features/devices/presentation/widgets/local_agent_lifecycle_notice.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../mocks/mock_socket_service.dart';

class _ReadySocket extends FakeSanadSocketService {
  _ReadySocket() : super(hardwareId: 'device-1', isLocalTransport: true) {
    setConnected(true);
  }

  @override
  bool get isReady => true;
}

/// A controller whose stopped or running agent is newer than the Client.
class _NewerAgentController implements LocalDaemonController {
  @override
  bool get ownsStoppedAgentLifecycle => true;
  @override
  bool get shouldAutoStart => true;
  @override
  bool isServiceInstalled() => true;
  @override
  Future<bool> isDaemonRunning() async => true;
  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async => {'version': '1.0.18'};
  @override
  Future<String?> getDaemonVersion() async => '1.0.18';
  @override
  Future<bool> install() async => true;
  @override
  Future<bool> restartDaemon() async => true;
  @override
  Future<bool> startDaemon() async => true;
  @override
  Future<bool> stopDaemon() async => true;
  @override
  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async => const AgentLifecycleResult(AgentLifecycleStatus.newerAgentInUse, agentVersion: '1.0.18');
}

Widget _app(Widget child, Locale locale) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  late DeviceConnectionCoordinator coordinator;
  final controller = _NewerAgentController();

  setUp(() {
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: FakeSanadSocketService(hardwareId: 'device-1'),
      localSocketService: _ReadySocket(),
      currentDeviceId: 'device-1',
      daemonController: controller,
      expectedVersion: '1.0.17',
    );
    GetIt.instance
      ..registerSingleton<LocalDaemonController>(controller)
      ..registerSingleton<DeviceConnectionCoordinator>(coordinator);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    coordinator.dispose();
  });

  for (final locale in const [Locale('en'), Locale('ar')]) {
    testWidgets('Run Sanad Locally treats a newer agent in use as success with a notice ($locale)', (tester) async {
      var completed = false;
      String? failure;
      await tester.pumpWidget(
        _app(
          InstallationTerminalView(
            versionTag: 'v1.0.17',
            onComplete: () => completed = true,
            onFailure: (error) => failure = error,
          ),
          locale,
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(locale);
      expect(failure, isNull);
      expect(completed, isTrue);
      expect(find.textContaining(l10n.newerAgentInUseNotice('1.0.18', '1.0.17')), findsOneWidget);
      expect(find.textContaining('[ERROR]'), findsNothing);
    });

    testWidgets('Settings shows the localized newer-agent notice ($locale)', (tester) async {
      await tester.pumpWidget(_app(LocalAgentLifecycleNotice(coordinator: coordinator), locale));
      expect(find.byKey(const Key('local_agent_newer_notice')), findsNothing);

      await coordinator.checkAndStartLocalDaemon();
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(locale);
      expect(find.byKey(const Key('local_agent_newer_notice')), findsOneWidget);
      expect(find.text(l10n.newerAgentInUseNotice('1.0.18', '1.0.17')), findsOneWidget);
    });
  }
}
