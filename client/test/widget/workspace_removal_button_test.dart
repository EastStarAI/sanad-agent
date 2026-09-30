import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages.dart';

void main() {
  testWidgets('confirms record-only workspace removal before invoking mutation', (
    tester,
  ) async {
    var removeCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceRemovalButton(
            onRemove: () async => removeCalls++,
          ),
        ),
      ),
    );

    expect(find.text('Browse folders'), findsNothing);
    await tester.tap(find.byKey(const Key('remove_workspace_button')));
    await tester.pumpAndSettle();

    expect(find.text('Remove workspace?'), findsOneWidget);
    expect(
      find.text(
        'This removes only the workspace record from Sanad. The folder and '
        'its files will not be deleted, and existing conversations will '
        'remain in the database.',
      ),
      findsOneWidget,
    );
    expect(removeCalls, 0);

    await tester.tap(find.byKey(const Key('confirm_remove_workspace_button')));
    await tester.pumpAndSettle();

    expect(removeCalls, 1);
  });

  testWidgets('disables workspace removal when no mutation is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: WorkspaceRemovalButton(onRemove: null)),
      ),
    );

    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('remove_workspace_button')),
    );
    expect(button.onPressed, isNull);
  });
}
