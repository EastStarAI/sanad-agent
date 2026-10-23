import 'package:flutter/material.dart';

import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Renders the daemon inspection result of an MCP server draft.
///
/// The host screen owns the disabled-tool set and reports every switch change
/// through [onToolToggled].
class McpInspectionReview extends StatelessWidget {
  const McpInspectionReview({
    super.key,
    required this.result,
    required this.disabledTools,
    required this.onToolToggled,
  });

  final McpServerInspection result;
  final Set<String> disabledTools;
  final void Function(String toolName, bool enabled) onToolToggled;

  @override
  Widget build(BuildContext context) {
    final success = result.success;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  success ? Icons.check_circle : Icons.error_outline,
                  color: success ? Colors.green : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(success ? 'Connection succeeded' : result.error ?? 'Connection failed')),
              ],
            ),
            const SizedBox(height: 8),
            Text('Transport: ${result.transport?.displayName ?? 'Unknown'}'),
            Text('Authentication: ${result.authState}'),
            if (result.tools.isNotEmpty) ...[
              const Divider(),
              const Text('Allowed tools', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final tool in result.tools)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: !disabledTools.contains(tool.name),
                  onChanged: (enabled) => onToolToggled(tool.name, enabled),
                  title: Text(tool.name),
                  subtitle: tool.description.isEmpty ? null : Text(tool.description),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Renders the placeholder shown before an MCP server draft was tested.
class McpInspectionPlaceholder extends StatelessWidget {
  const McpInspectionPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.18)),
      ),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          children: [
            Icon(
              Icons.sensors_outlined,
              size: 36,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context)!.mcpNoInspectionResults,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Test the server connection to discover available tools and verify communication.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
