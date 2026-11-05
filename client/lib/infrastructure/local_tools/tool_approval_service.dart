import 'package:sanad_client/app.dart';
import 'package:sanad_client/core/theme/app_typography.dart';
import 'package:flutter/material.dart';

enum ToolApprovalScope {
  once,
  command,
  session,
  workspace,
  deny,
}

class ToolApprovalRequest {
  final String toolName;
  final String workspaceName;
  final String workspacePath;
  final String commandPreview;

  const ToolApprovalRequest({
    required this.toolName,
    required this.workspaceName,
    required this.workspacePath,
    required this.commandPreview,
  });
}

class ToolApprovalDecision {
  final ToolApprovalScope scope;

  const ToolApprovalDecision(this.scope);

  bool get isAllowed =>
      scope == ToolApprovalScope.once ||
      scope == ToolApprovalScope.command ||
      scope == ToolApprovalScope.session ||
      scope == ToolApprovalScope.workspace;
}

class ToolApprovalService {
  const ToolApprovalService();

  Future<ToolApprovalDecision> requestShellExecutionApproval(
    ToolApprovalRequest request,
  ) async {
    final context =
        appNavigatorKey.currentContext ??
        appNavigatorKey.currentState?.context ??
        appNavigatorKey.currentState?.overlay?.context;
    if (context == null) {
      return const ToolApprovalDecision(ToolApprovalScope.deny);
    }

    final result = await showDialog<ToolApprovalScope>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('Approve Shell Command'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sanad Agent wants to run a shell command in this workspace.',
                  style: AppTypography.text(context,
                    color: colorScheme.onSurface,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                _ApprovalDetail(label: 'Workspace', value: request.workspaceName),
                const SizedBox(height: 8),
                _ApprovalDetail(label: 'Path', value: request.workspacePath),
                const SizedBox(height: 8),
                _ApprovalDetail(label: 'Command', value: request.commandPreview, monospace: true),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(ToolApprovalScope.deny),
              child: const Text('Deny'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(ToolApprovalScope.once),
              child: const Text('Allow Once'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(ToolApprovalScope.session),
              child: const Text('Allow for Session'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(ToolApprovalScope.workspace),
              child: const Text('Always Allow in Workspace'),
            ),
          ],
        );
      },
    );

    return ToolApprovalDecision(result ?? ToolApprovalScope.deny);
  }
}

class _ApprovalDetail extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;

  const _ApprovalDetail({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTypography.text(context,
            color: colorScheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Text(
            value,
            style: monospace
                ? AppTypography.mono(
                    color: colorScheme.onSurface,
                    fontSize: 12,
                  )
                : AppTypography.text(context,
                    color: colorScheme.onSurface,
                    fontSize: 12,
                    height: 1.4,
                  ),
          ),
        ),
      ],
    );
  }
}
