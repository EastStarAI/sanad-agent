import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Shows the one-server Advanced JSON editor for [server].
///
/// The daemon preview stays mandatory: Save is enabled only after a successful
/// preview of the same document, and the revision pair is forwarded untouched.
/// Returns `true` when the daemon accepted the save.
Future<bool?> showMcpAdvancedJsonDialog({
  required BuildContext context,
  required DeviceConfig device,
  required McpServerConfig server,
  required McpConfigScope scope,
  required String? workspaceId,
  required McpAdvancedDocument document,
}) async {
  final controller = TextEditingController(text: document.json);
  McpConfigPreview? preview;
  String? error;
  var busy = false;
  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Advanced JSON · ${server.name}'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppLocalizations.of(context)!.mcpPreviewRequiredNote),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  minLines: 12,
                  maxLines: 20,
                  style: const TextStyle(fontFamily: 'monospace'),
                  onChanged: (_) => setDialogState(() {
                    preview = null;
                    error = null;
                  }),
                ),
                if (preview != null) ...[
                  const SizedBox(height: 12),
                  Text('${preview!.diff.length} fields changed'),
                  for (final item in preview!.diff) Text('• ${item.field}'),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: Text(AppLocalizations.of(context)!.mcpCancel)),
          OutlinedButton(
            onPressed: busy
                ? null
                : () async {
                    setDialogState(() => busy = true);
                    try {
                      final value = await dialogContext.read<McpRuntimeClient>().previewAdvanced(
                        device: device,
                        serverName: server.name,
                        scope: scope,
                        workspaceId: workspaceId,
                        input: controller.text,
                      );
                      setDialogState(() {
                        preview = value;
                        error = null;
                      });
                    } catch (value) {
                      setDialogState(() => error = value.toString());
                    } finally {
                      setDialogState(() => busy = false);
                    }
                  },
            child: Text(AppLocalizations.of(context)!.mcpPreviewChanges),
          ),
          FilledButton(
            onPressed: busy || preview == null
                ? null
                : () async {
                    setDialogState(() => busy = true);
                    try {
                      await dialogContext.read<McpRuntimeClient>().saveAdvanced(
                        device: device,
                        serverName: server.name,
                        scope: scope,
                        workspaceId: workspaceId,
                        input: controller.text,
                        baseRevision: document.baseRevision,
                        previewRevision: preview!.revision,
                      );
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (value) {
                      setDialogState(() => error = value.toString());
                    } finally {
                      if (context.mounted) setDialogState(() => busy = false);
                    }
                  },
            child: Text(AppLocalizations.of(context)!.mcpSave),
          ),
        ],
      ),
    ),
  );
  await Future<void>.delayed(kThemeAnimationDuration);
  controller.dispose();
  return saved;
}
