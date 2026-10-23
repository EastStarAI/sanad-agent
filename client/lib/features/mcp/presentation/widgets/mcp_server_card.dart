import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Renders one MCP server card with its connection status, tool list, and
/// actions.
///
/// The host screen owns connection, expansion, and mutation state and reports
/// every action through a typed callback.
class McpServerCard extends StatelessWidget {
  const McpServerCard({
    super.key,
    required this.server,
    required this.isConnected,
    required this.isConnecting,
    required this.error,
    required this.tools,
    required this.isExpanded,
    required this.originLabel,
    required this.showEdit,
    required this.canEditCurrentSource,
    required this.canTestOrEdit,
    required this.canMutate,
    required this.onToggleExpanded,
    required this.onToggleEnabled,
    required this.onToggleTool,
    required this.onTest,
    required this.onEdit,
    required this.onExport,
    required this.onEditJson,
    required this.onDelete,
  });

  final McpServerConfig server;
  final bool isConnected;
  final bool isConnecting;
  final String? error;
  final List<McpRuntimeTool> tools;
  final bool isExpanded;

  /// Origin chip label, rendered only when the host shows the effective scope.
  final String? originLabel;

  /// Whether the Edit action is offered for this server in the current scope.
  final bool showEdit;
  final bool canEditCurrentSource;

  /// Whether Test and Edit are enabled (device online, no pending mutation).
  final bool canTestOrEdit;
  final bool canMutate;
  final VoidCallback onToggleExpanded;
  final ValueChanged<bool> onToggleEnabled;
  final void Function(String toolName, bool enabled) onToggleTool;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onExport;
  final VoidCallback onEditJson;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final statusText = !server.enabled
        ? AppLocalizations.of(context)!.mcpDisabled
        : isConnecting
        ? AppLocalizations.of(context)!.mcpConnecting
        : error ?? (isConnected ? '${tools.length} tools' : 'Disconnected');

    final appearance = context.watch<AppearanceCubit?>()?.state;
    final isCustomBg = appearance != null && appearance.backgroundOption != AppBackgroundOption.defaultTheme;
    final cardColor = isCustomBg
        ? (Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface).withValues(alpha: 0.60)
        : Theme.of(context).colorScheme.surface;

    final card = Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: isCustomBg ? 0.25 : 0.12),
        ),
      ),
      child: Column(
          children: [
            Semantics(
              button: true,
              container: true,
              explicitChildNodes: true,
              label: '${isExpanded ? AppLocalizations.of(context)!.mcpCollapse : AppLocalizations.of(context)!.mcpExpand} ${server.name} details',

              child: InkWell(
                key: ValueKey('mcp_server_toggle_${server.name}'),
                excludeFromSemantics: true,
                onTap: onToggleExpanded,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      McpStatusDot(
                        color: !server.enabled
                            ? Theme.of(context).colorScheme.outline
                            : error != null
                            ? Theme.of(context).colorScheme.error
                            : isConnected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              server.name,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                McpMetaChip(label: server.enabled ? AppLocalizations.of(context)!.mcpEnabled : AppLocalizations.of(context)!.mcpDisabled),
                                McpMetaChip(label: _transportLabel(server)),
                                McpMetaChip(label: server.authType.displayName),
                                McpMetaChip(label: '${tools.length} tools'),
                                if (originLabel != null) McpMetaChip(label: originLabel!),
                                if (server.disabledTools.isNotEmpty)
                                  McpMetaChip(label: '${server.disabledTools.length} disabled'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              statusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: error != null
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Semantics(
                        excludeSemantics: true,
                        label: '${server.enabled ? AppLocalizations.of(context)!.mcpDisable : AppLocalizations.of(context)!.mcpEnable} ${server.name}',
                        toggled: server.enabled,

                        child: Switch(
                          value: server.enabled,
                          onChanged: canEditCurrentSource ? onToggleEnabled : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isExpanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.12)),
                    if (tools.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          server.enabled ? AppLocalizations.of(context)!.mcpConnectToDiscover : AppLocalizations.of(context)!.mcpServerDisabled,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ...tools.map(
                      (tool) => Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tool.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 4),
                                  Text(
                                    tool.description,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              children: [
                                Semantics(
                                  excludeSemantics: true,
                                  label: '${server.isToolDisabled(tool.name) ? AppLocalizations.of(context)!.mcpEnable : AppLocalizations.of(context)!.mcpDisable} tool ${tool.name}',
                                  toggled: !server.isToolDisabled(tool.name),
                                  child: Switch(
                                    value: !server.isToolDisabled(tool.name),
                                    onChanged: canEditCurrentSource
                                        ? (value) => onToggleTool(tool.name, value)
                                        : null,
                                  ),
                                ),
                                Text(
                                  server.isToolDisabled(tool.name) ? AppLocalizations.of(context)!.mcpDisabled : AppLocalizations.of(context)!.mcpEnabled,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: canTestOrEdit ? onTest : null,
                          icon: const Icon(Icons.wifi_find),
                          label: Text(AppLocalizations.of(context)!.mcpTest),
                        ),
                        if (showEdit)
                          OutlinedButton.icon(
                            onPressed: canTestOrEdit ? onEdit : null,
                            icon: Icon(Icons.edit_outlined),
                            label: Text(AppLocalizations.of(context)!.mcpEdit),
                          ),
                        PopupMenuButton<String>(
                          tooltip: AppLocalizations.of(context)!.mcpAdvancedActions,
                          onSelected: (value) {
                            if (value == 'export') onExport();
                            if (value == 'json') onEditJson();
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(value: 'export', child: Text(AppLocalizations.of(context)!.mcpExportJson)),
                            PopupMenuItem(value: 'json', child: Text(AppLocalizations.of(context)!.mcpEditJson)),
                          ],
                        ),
                        if (canMutate)
                          TextButton.icon(
                            key: ValueKey('mcp_server_remove_${server.name}'),
                            onPressed: onDelete,
                            icon: const Icon(Icons.delete_outline),
                            label: Text(AppLocalizations.of(context)!.mcpRemove),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      );

    final wrappedCard = isCustomBg
        ? ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: card,
            ),
          )
        : card;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '${server.name}, ${server.enabled ? AppLocalizations.of(context)!.mcpEnabled : AppLocalizations.of(context)!.mcpDisabled}, ${tools.length} tools',
      child: wrappedCard,
    );
  }
}

/// The connection-status dot rendered at the start of an MCP server card.
class McpStatusDot extends StatelessWidget {
  const McpStatusDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// The small pill label rendered in an MCP server card's metadata row.
class McpMetaChip extends StatelessWidget {
  const McpMetaChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _transportLabel(McpServerConfig server) {
  return switch (server.transport) {
    McpTransportType.auto => 'Auto',
    McpTransportType.stdio => 'STDIO',
    McpTransportType.sse => 'SSE',
    McpTransportType.streamableHttp => 'HTTP',
  };
}
