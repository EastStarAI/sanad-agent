import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/turn_replay_confirmation_dialog.dart';

void main() {
  testWidgets('combines unsafe replay and steer-drop warnings', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TurnReplayConfirmationDialog(
            action: TurnReplayAction.edit,
            safety: TurnReplaySafety.unsafe,
            confirmsUnsafe: true,
            confirmsSteerDrop: true,
          ),
        ),
      ),
    );

    expect(find.text('Edit and rerun this turn?'), findsOneWidget);
    expect(find.textContaining('repeat those side effects'), findsOneWidget);
    expect(find.textContaining('will not send those follow-up directions again'), findsOneWidget);
    expect(find.byKey(const Key('turn_replay_cancel_button')), findsOneWidget);
    expect(find.byKey(const Key('turn_replay_confirm_button')), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });
}
