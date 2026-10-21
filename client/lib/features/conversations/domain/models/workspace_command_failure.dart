/// A workspace or folder command the Agent rejected with an `error` event.
///
/// [code] is the Agent's machine-readable rejection code, when it sent one,
/// so presentation can choose a localized explanation instead of showing the
/// Agent's English-only message. It extends [StateError] so existing callers
/// that catch state errors keep working.
class WorkspaceCommandFailure extends StateError {
  WorkspaceCommandFailure(String message, {this.code}) : super(message);

  /// The path is outside the device's managed workspaces root, or is not
  /// usable there (link, file, traversal, relative path).
  static const pathNotAllowed = 'path_not_allowed';

  /// The folder is, or contains, a registered workspace.
  static const workspaceInUse = 'workspace_in_use';

  /// A confirmed delete no longer matches its preview.
  static const staleConfirmation = 'stale_confirmation';

  final String? code;

  /// Builds a failure from an Agent `error` response, or `null` when
  /// [result] is not an error.
  static WorkspaceCommandFailure? fromErrorResponse(
    Map<String, dynamic>? result, {
    required String fallbackMessage,
  }) {
    if (result?['event']?.toString() != 'error') return null;
    final payload = result?['payload'];
    final map = payload is Map ? payload : result;
    final code = map?['code']?.toString();
    return WorkspaceCommandFailure(
      map?['message']?.toString() ?? fallbackMessage,
      code: code == null || code.isEmpty ? null : code,
    );
  }
}
