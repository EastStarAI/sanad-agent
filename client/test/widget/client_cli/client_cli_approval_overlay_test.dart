import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_approval_coordinator.dart';
import 'package:sanad_client/features/client_cli/presentation/widgets/client_cli_approval_overlay.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

void main() {
  Widget buildTestWidget(ClientCliApprovalCoordinator coordinator) {
    return MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      home: Scaffold(
        body: Provider<ClientCliApprovalCoordinator>.value(
          value: coordinator,
          child: const ClientCliApprovalOverlay(
            child: Center(
              child: Text('Main Content Area'),
            ),
          ),
        ),
      ),
    );
  }

  group('ClientCliApprovalOverlay', () {
    late ClientCliApprovalCoordinator coordinator;

    setUp(() {
      coordinator = ClientCliApprovalCoordinator();
    });

    tearDown(() {
      coordinator.dispose();
    });

    testWidgets('renders child content and no dialog when idle', (tester) async {
      await tester.pumpWidget(buildTestWidget(coordinator));
      await tester.pumpAndSettle();

      expect(find.text('Main Content Area'), findsOneWidget);
      expect(find.byKey(const Key('client_cli_allow_once_btn')), findsNothing);
    });

    testWidgets('displays approval dialog when request is pending and resolves allowOnce on click', (tester) async {
      await tester.pumpWidget(buildTestWidget(coordinator));
      await tester.pumpAndSettle();

      Future<bool>? approvalFuture;
      // Start a request
      approvalFuture = coordinator.requestApproval(
        id: 'req-1',
        deviceId: 'dev-remote-1',
        deviceName: 'Remote Mac',
        argv: ['run', '--workspace', 'ws-1', 'hello'],
      );

      await tester.pumpAndSettle();

      expect(find.text('Allow Sanad CLI to run remote command?'), findsOneWidget);
      expect(find.textContaining('Remote Mac'), findsWidgets);
      expect(find.textContaining('run --workspace ws-1 hello'), findsWidgets);
      expect(find.byKey(const Key('client_cli_allow_once_btn')), findsOneWidget);

      // Tap allow once
      await tester.tap(find.byKey(const Key('client_cli_allow_once_btn')));
      await tester.pumpAndSettle();

      final result = await approvalFuture;
      expect(result, isTrue);

      // Dialog should disappear
      expect(find.byKey(const Key('client_cli_allow_once_btn')), findsNothing);
    });

    testWidgets('resolves allowSession when key 2 is pressed', (tester) async {
      await tester.pumpWidget(buildTestWidget(coordinator));
      await tester.pumpAndSettle();

      final approvalFuture = coordinator.requestApproval(
        id: 'req-2',
        deviceId: 'dev-remote-1',
        deviceName: 'Remote Mac',
        argv: ['run', '--workspace', 'ws-1'],
        sessionId: 'sess-123',
      );

      await tester.pumpAndSettle();
      expect(find.text('Allow Sanad CLI to run remote command?'), findsOneWidget);

      // Press key '2'
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pumpAndSettle();

      final result = await approvalFuture;
      expect(result, isTrue);

      // Next request for same session is auto-approved without dialog
      final secondFuture = coordinator.requestApproval(
        id: 'req-3',
        deviceId: 'dev-remote-1',
        deviceName: 'Remote Mac',
        argv: ['session', 'show'],
        sessionId: 'sess-123',
      );
      final secondResult = await secondFuture;
      expect(secondResult, isTrue);
      expect(find.byKey(const Key('client_cli_allow_once_btn')), findsNothing);
    });

    testWidgets('resolves deny when key 3 or Escape is pressed', (tester) async {
      await tester.pumpWidget(buildTestWidget(coordinator));
      await tester.pumpAndSettle();

      final approvalFuture = coordinator.requestApproval(
        id: 'req-4',
        deviceId: 'dev-remote-1',
        deviceName: 'Remote Mac',
        argv: ['stop'],
      );

      await tester.pumpAndSettle();
      expect(find.text('Allow Sanad CLI to run remote command?'), findsOneWidget);

      // Press Escape
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final result = await approvalFuture;
      expect(result, isFalse);
      expect(find.byKey(const Key('client_cli_allow_once_btn')), findsNothing);
    });
  });
}
