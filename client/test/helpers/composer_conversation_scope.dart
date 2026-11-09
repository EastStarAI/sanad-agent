import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';

/// The conversation scope a composer binds to.
///
/// The composer's model/provider picker is always mounted, so it always reads
/// the selected session and the live context usage. A test that mounts a
/// composer on its own supplies this scope instead of leaving the provider
/// missing; a test that cares about the route passes a [Session].
class StubSessionCubit extends Cubit<SessionState> implements SessionCubit {
  StubSessionCubit([Session? session]) : super(SessionState(selectedSession: session));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An empty conversation history: no messages, so no context usage is shown.
class StubSessionMessagesCubit extends Cubit<SessionMessagesState> implements SessionMessagesCubit {
  StubSessionMessagesCubit() : super(const SessionMessagesState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
