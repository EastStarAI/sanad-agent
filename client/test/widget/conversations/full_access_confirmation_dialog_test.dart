import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/full_access_confirmation_dialog.dart';

void main() {
  group('FullAccessConfirmationDialog', () {
    testWidgets('renders all approved Plan 83 security copy and warning sections', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FullAccessConfirmationDialog(),
          ),
        ),
      );

      // Verify title
      expect(find.text('Turn on Full Access?'), findsOneWidget);

      // Verify intro body
      expect(
        find.textContaining('without asking before each operation'),
        findsOneWidget,
      );

      // Verify risk items
      expect(find.text('Access files and folders'), findsOneWidget);
      expect(
        find.text('Read, create, modify, upload, or delete files available to your user account.'),
        findsOneWidget,
      );

      expect(find.text('Run terminal commands'), findsOneWidget);
      expect(
        find.text('Execute commands, install software, and change system or development settings.'),
        findsOneWidget,
      );

      expect(find.text('Use the internet and connected tools'), findsOneWidget);
      expect(
        find.text('Access websites, send data, and use enabled tools and plugins.'),
        findsOneWidget,
      );

      // Verify security warning text
      expect(
        find.textContaining('Commands run with your operating-system account'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Malicious instructions or prompt injection could cause data loss or exposure.'),
        findsOneWidget,
      );

      // Verify footer text
      expect(
        find.text('You can turn Full Access off at any time.'),
        findsOneWidget,
      );
      expect(find.text('Learn more'), findsOneWidget);

      // Verify actions
      expect(find.byKey(const Key('cancel_full_access_button')), findsOneWidget);
      expect(find.byKey(const Key('confirm_turn_on_full_access')), findsOneWidget);
    });

    testWidgets('returns false when Cancel is pressed', (tester) async {
      bool? dialogResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  dialogResult = await FullAccessConfirmationDialog.show(context);
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.byType(FullAccessConfirmationDialog), findsOneWidget);

      await tester.tap(find.byKey(const Key('cancel_full_access_button')));
      await tester.pumpAndSettle();

      expect(find.byType(FullAccessConfirmationDialog), findsNothing);
      expect(dialogResult, isFalse);
    });

    testWidgets('returns true when Turn On is pressed', (tester) async {
      bool? dialogResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  dialogResult = await FullAccessConfirmationDialog.show(context);
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.byType(FullAccessConfirmationDialog), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirm_turn_on_full_access')));
      await tester.pumpAndSettle();

      expect(find.byType(FullAccessConfirmationDialog), findsNothing);
      expect(dialogResult, isTrue);
    });
  });
}
