import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages.dart';

void main() {
  testWidgets('shows Cancel, red Force restart, then Restart', (tester) async {
    AgentRestartMode? selected;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showDialog<AgentRestartMode>(
                context: context,
                builder: (_) => const AgentRestartConfirmationDialog(
                  deviceName: 'Remote Agent',
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final cancel = find.byKey(const Key('dialog_cancel_restart_button'));
    final force = find.byKey(const Key('dialog_force_restart_button'));
    final restart = find.byKey(const Key('dialog_confirm_restart_button'));
    expect(tester.getCenter(cancel).dx, lessThan(tester.getCenter(force).dx));
    expect(tester.getCenter(force).dx, lessThan(tester.getCenter(restart).dx));

    final context = tester.element(force);
    final button = tester.widget<FilledButton>(force);
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      Theme.of(context).colorScheme.error,
    );
    expect(find.textContaining('may interrupt active work'), findsOneWidget);

    await tester.tap(force);
    await tester.pumpAndSettle();
    expect(selected, AgentRestartMode.force);
  });
}
