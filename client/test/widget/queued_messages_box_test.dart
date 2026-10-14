import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/queued_messages_box.dart';

void main() {
  testWidgets('queue actions use the raw request id and wait for confirmation', (tester) async {
    String? steeredRequestId;
    String? deletedRequestId;
    final event = CanonicalEvent(
      id: 'user_raw-request',
      kind: EventKind.userMessage,
      text: 'queued text',
      timestamp: DateTime.utc(2026, 7, 15),
      metadata: const {'request_id': 'raw-request', 'queued': true},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueuedMessagesBox(
            messages: [event],
            borderColor: Colors.grey,
            inputBgColor: Colors.white,
            dimTextColor: Colors.black54,
            onSteer: (_, {required requestId}) => steeredRequestId = requestId,
            onDelete: ({required requestId}) => deletedRequestId = requestId,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Steer'));
    expect(steeredRequestId, 'raw-request');
    expect(find.text('queued text'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete queued message'));
    expect(deletedRequestId, 'raw-request');
    expect(find.text('queued text'), findsOneWidget);
  });

  testWidgets('pending queue mutation disables row actions and shows progress', (tester) async {
    final event = CanonicalEvent(
      id: 'user_raw-request',
      kind: EventKind.userMessage,
      text: 'queued text',
      timestamp: DateTime.utc(2026, 7, 15),
      metadata: const {'request_id': 'raw-request', 'queued': true},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueuedMessagesBox(
            messages: [event],
            borderColor: Colors.grey,
            inputBgColor: Colors.white,
            dimTextColor: Colors.black54,
            pendingRequestIds: const {'raw-request'},
            onSteer: (_, {required requestId}) {},
            onDelete: ({required requestId}) {},
          ),
        ),
      ),
    );

    expect(find.byType(AppProgressIndicator), findsOneWidget);
    expect(find.text('Steer'), findsNothing);
    expect(find.text('queued text'), findsOneWidget);
  });
}
