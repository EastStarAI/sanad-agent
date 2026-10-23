/// Failure decoding shared by every `ConversationCommands` request helper.
///
/// A reply reaches the Client as raw gateway JSON, so one owner decides
/// whether it is a rejection and how a coded workspace rejection is raised.
library;

import 'package:sanad_client/features/conversations/domain/models/workspace_command_failure.dart';

/// The `payload` object of a correlated reply, or the reply itself.
Map<String, dynamic> responsePayload(Map<String, dynamic> response) =>
    Map<String, dynamic>.from(response['payload'] as Map? ?? response);

/// The rejection carried by a correlated reply, or `null` for a success.
///
/// The Gateway completes a request with any event that repeats its
/// `request_id`, so a correlated `error` event (an admission or relay
/// rejection) and an Agent reply whose payload holds an `error` object are
/// both failures, never an empty success.
({String? code, String? message})? responseError(Map<String, dynamic>? result) {
  if (result == null) return null;
  final payload = responsePayload(result);
  final nested = payload['error'];
  if (nested is Map) {
    return (code: nested['code']?.toString(), message: nested['message']?.toString());
  }
  if (result['event']?.toString() == 'error') {
    return (code: payload['code']?.toString(), message: payload['message']?.toString());
  }
  return null;
}

/// Throws a [StateError] when [result] is a correlated rejection.
void throwIfErrorResponse(Map<String, dynamic>? result, String fallbackMessage) {
  final error = responseError(result);
  if (error == null) return;
  final message = error.message ?? fallbackMessage;
  throw StateError(error.code == null ? message : '${error.code}: $message');
}

/// Throws a coded [WorkspaceCommandFailure] when [result] is an Agent
/// `error` response, so presentation can localize the rejection.
void throwIfWorkspaceError(
  Map<String, dynamic>? result,
  String fallbackMessage,
) {
  final failure = WorkspaceCommandFailure.fromErrorResponse(
    result,
    fallbackMessage: fallbackMessage,
  );
  if (failure != null) throw failure;
}
