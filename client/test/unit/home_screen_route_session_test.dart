import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/home/presentation/screens/home_screen.dart';

void main() {
  final placeholderTime = DateTime(2026, 9, 16);

  test('route initialization preserves a matching selected search session', () {
    final selected = Session(
      id: 'session-outside-sidebar-page',
      title: 'Authoritative search result title',
      deviceId: 'device-1',
      workspaceId: 'workspace-1',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final destination = ConversationDestination.session(
      deviceId: 'device-1',
      sessionId: selected.id,
    );

    final resolved = HomeScreen.resolveRouteSession(
      destination: destination,
      selectedSession: selected,
      placeholderTime: placeholderTime,
    );

    expect(resolved, same(selected));
    expect(resolved.title, 'Authoritative search result title');
    expect(resolved.workspaceId, 'workspace-1');
  });

  test('route initialization creates a placeholder for an unknown deep link', () {
    final destination = ConversationDestination.session(
      deviceId: 'device-1',
      sessionId: 'unknown-session',
    );

    final resolved = HomeScreen.resolveRouteSession(
      destination: destination,
      selectedSession: null,
      placeholderTime: placeholderTime,
    );

    expect(resolved.id, 'unknown-session');
    expect(resolved.deviceId, 'device-1');
    expect(resolved.title, 'Loading...');
    expect(resolved.createdAt, placeholderTime);
    expect(resolved.updatedAt, placeholderTime);
  });
}
