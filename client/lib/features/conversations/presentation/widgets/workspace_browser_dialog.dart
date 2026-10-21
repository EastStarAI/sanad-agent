import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_command_failure.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

typedef WorkspaceTreeLoader = Future<WorkspaceTreeSnapshot> Function({String? path});
typedef WorkspaceFolderCreator =
    Future<void> Function(
      String parentPath,
      String name,
    );
typedef WorkspaceFolderRenamer =
    Future<void> Function(
      String path,
      String newName,
    );
typedef WorkspaceFolderDeleter = Future<void> Function(String path);

/// The four folder-browser operations, all bound to one device.
///
/// Built with [WorkspaceBrowserCallbacks.forDevice] for the device being set
/// up, so every browse and folder command targets that device rather than
/// whichever device owns the active session.
class WorkspaceBrowserCallbacks {
  const WorkspaceBrowserCallbacks({
    required this.loader,
    this.onCreateFolder,
    this.onRenameFolder,
    this.onDeleteFolder,
  });

  factory WorkspaceBrowserCallbacks.forDevice(
    ConversationCacheRepository repository,
    DeviceConfig device,
  ) {
    return WorkspaceBrowserCallbacks(
      loader: ({path}) => repository.browseWorkspaceTree(device, path: path),
      onCreateFolder: (parentPath, name) => repository.createFolder(
        device,
        parentPath: parentPath,
        name: name,
      ),
      onRenameFolder: (path, newName) => repository.renameFolder(
        device,
        path: path,
        newName: newName,
      ),
      onDeleteFolder: (path) => repository.deleteFolder(device, path: path),
    );
  }

  final WorkspaceTreeLoader loader;
  final WorkspaceFolderCreator? onCreateFolder;
  final WorkspaceFolderRenamer? onRenameFolder;
  final WorkspaceFolderDeleter? onDeleteFolder;
}

/// The single folder picker for a device reached remotely.
///
/// It lists folders only. The Agent confines a remote browse to its Home's
/// workspaces root and opens there for an empty path; "Use This Folder" is
/// disabled at that root, which the Agent also refuses to register.

class WorkspaceBrowserDialog extends StatefulWidget {
  final WorkspaceTreeLoader loader;
  final WorkspaceFolderCreator? onCreateFolder;
  final WorkspaceFolderRenamer? onRenameFolder;
  final WorkspaceFolderDeleter? onDeleteFolder;

  const WorkspaceBrowserDialog({
    super.key,
    required this.loader,
    this.onCreateFolder,
    this.onRenameFolder,
    this.onDeleteFolder,
  });

  @override
  State<WorkspaceBrowserDialog> createState() => _WorkspaceBrowserDialogState();
}

class _WorkspaceBrowserDialogState extends State<WorkspaceBrowserDialog> {
  WorkspaceTreeSnapshot? _snapshot;
  bool _isLoading = true;
  Object? _loadError;
  Object? _mutationError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({String? path}) async {
    setState(() {
      _isLoading = true;
      _loadError = null;
      _mutationError = null;
    });

    try {
      final snapshot = await widget.loader(path: path);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _isLoading = false;
      });
    }
  }

  Future<String?> _promptForFolderName({
    required String title,
    required String label,
    required String actionLabel,
    String initialValue = '',
  }) {
    final l10n = AppLocalizations.of(context)!;
    var value = initialValue;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          key: const Key('workspace_folder_name_input'),
          initialValue: initialValue,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onChanged: (nextValue) => value = nextValue,
          onFieldSubmitted: (nextValue) {
            if (_isValidFolderName(nextValue)) {
              Navigator.pop(dialogContext, nextValue);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('workspace_folder_dialog_confirm_button'),
            onPressed: () => Navigator.pop(dialogContext, value),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  bool _isValidFolderName(String value) {
    final name = value.trim();
    return name.isNotEmpty &&
        name != '.' &&
        name != '..' &&
        !name.contains('/') &&
        !name.contains(r'\') &&
        !name.contains('\u0000');
  }

  Future<void> _showCreateFolderDialog(String currentPath) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _promptForFolderName(
      title: l10n.workspaceBrowserNewFolder,
      label: l10n.workspaceBrowserFolderNameLabel,
      actionLabel: l10n.workspaceBrowserCreate,
    );
    if (!mounted || name == null) return;
    if (!_isValidFolderName(name)) {
      setState(() {
        _mutationError = const _InvalidFolderName();
      });
      return;
    }

    await _runMutation(
      () => widget.onCreateFolder!(currentPath, name.trim()),
      refreshPath: currentPath,
    );
  }

  Future<void> _showRenameFolderDialog(
    String folderPath,
    String currentName,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final newName = await _promptForFolderName(
      title: l10n.workspaceBrowserRenameFolder,
      label: l10n.workspaceBrowserNewFolderNameLabel,
      actionLabel: l10n.workspaceBrowserRename,
      initialValue: currentName,
    );
    if (!mounted || newName == null || newName.trim() == currentName) return;
    if (!_isValidFolderName(newName)) {
      setState(() {
        _mutationError = const _InvalidFolderName();
      });
      return;
    }

    await _runMutation(
      () => widget.onRenameFolder!(folderPath, newName.trim()),
      refreshPath: _snapshot?.path,
    );
  }

  Future<void> _showDeleteFolderDialog(String folderPath, String name) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.workspaceBrowserDeleteFolder),
        content: Text(l10n.workspaceBrowserDeleteConfirmation(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('workspace_folder_delete_confirm_button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    await _runMutation(
      () => widget.onDeleteFolder!(folderPath),
      refreshPath: _snapshot?.path,
    );
  }

  Future<void> _runMutation(
    Future<void> Function() operation, {
    required String? refreshPath,
  }) async {
    setState(() {
      _isLoading = true;
      _mutationError = null;
    });
    try {
      await operation();
      if (!mounted) return;
      await _load(path: refreshPath);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _mutationError = error;
        _isLoading = false;
      });
    }
  }

  /// A localized explanation. A known rejection code maps to its own
  /// message; any other failure shows the localized generic line followed by
  /// the Agent's reason, so an actionable detail is not lost.
  String _describeError(
    AppLocalizations l10n,
    Object error, {
    required bool load,
  }) {
    if (error is _InvalidFolderName) {
      return l10n.workspaceBrowserInvalidFolderName;
    }
    final code = error is WorkspaceCommandFailure ? error.code : null;
    return switch (code) {
      WorkspaceCommandFailure.pathNotAllowed =>
        l10n.workspaceBrowserErrorPathNotAllowed,
      WorkspaceCommandFailure.workspaceInUse =>
        l10n.workspaceBrowserErrorWorkspaceInUse,
      WorkspaceCommandFailure.staleConfirmation =>
        l10n.workspaceBrowserErrorStaleConfirmation,
      _ => _withDetail(
        load ? l10n.workspaceBrowserErrorLoad : l10n.workspaceBrowserErrorGeneric,
        error,
      ),
    };
  }

  String _withDetail(String generic, Object error) {
    final detail = error is StateError ? error.message.trim() : '';
    return detail.isEmpty ? generic : '$generic\n$detail';
  }

  /// The managed root itself cannot become a workspace.
  bool _isAtRoot(WorkspaceTreeSnapshot snapshot) =>
      snapshot.path.isEmpty ||
      (snapshot.parentPath == null && snapshot.path == snapshot.rootPath);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    final directories = snapshot?.entries.where((entry) => entry.isDirectory).toList(growable: false) ?? const [];
    final canGoUp = snapshot?.parentPath != null;
    final canMutateCurrentPath = snapshot != null && snapshot.path.isNotEmpty;
    final atRoot = snapshot == null || _isAtRoot(snapshot);

    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(l10n.workspaceBrowserTitle)),
          if (canMutateCurrentPath && widget.onCreateFolder != null)
            IconButton(
              key: const Key('workspace_browser_new_folder_button'),
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: l10n.workspaceBrowserNewFolder,
              onPressed: _isLoading ? null : () => _showCreateFolderDialog(snapshot.path),
            ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                // Host paths read left to right in every locale.
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    snapshot.path,
                    key: const Key('workspace_browser_current_path'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: GoogleFonts.inter(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            if (snapshot != null && atRoot && snapshot.path.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  l10n.workspaceBrowserRootHint,
                  key: const Key('workspace_browser_root_hint'),
                  style: GoogleFonts.inter(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            if (_mutationError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _describeError(l10n, _mutationError!, load: false),
                  key: const ValueKey('workspace-folder-mutation-error'),
                  style: GoogleFonts.inter(
                    color: colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            if (_isLoading)
              const Expanded(
                child: Center(child: AppProgressIndicator()),
              )
            else if (_loadError != null)
              Expanded(
                child: Center(
                  child: Text(
                    _describeError(l10n, _loadError!, load: true),
                    key: const Key('workspace_browser_load_error'),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      color: colorScheme.error,
                      fontSize: 13,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: Column(
                  children: [
                    if (canGoUp)
                      ListTile(
                        key: const Key('workspace_browser_parent_row'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.arrow_upward_outlined,
                          size: 18,
                          semanticLabel: l10n.workspaceBrowserParentFolder,
                        ),
                        title: const Text('..'),
                        onTap: () => _load(path: snapshot!.parentPath),
                      ),
                    Expanded(
                      child: directories.isEmpty
                          ? Center(
                              child: Text(
                                l10n.workspaceBrowserEmpty,
                                style: GoogleFonts.inter(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: directories.length,
                              itemBuilder: (context, index) {
                                final entry = directories[index];
                                return ListTile(
                                  key: ValueKey(
                                    'workspace_browser_folder_row:${entry.name}',
                                  ),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(
                                    Icons.folder_outlined,
                                    size: 18,
                                  ),
                                  title: Text(
                                    entry.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.inter(fontSize: 13),
                                  ),
                                  subtitle: entry.relativePath.isEmpty
                                      ? null
                                      : Text(
                                          entry.relativePath,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.inter(
                                            color: colorScheme.onSurfaceVariant,
                                            fontSize: 11,
                                          ),
                                        ),
                                  trailing: canMutateCurrentPath
                                      ? Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (widget.onRenameFolder != null)
                                              IconButton(
                                                key: ValueKey(
                                                  'workspace_browser_rename_button:${entry.name}',
                                                ),
                                                icon: const Icon(
                                                  Icons.edit_outlined,
                                                  size: 16,
                                                ),
                                                tooltip: l10n.workspaceBrowserRenameFolder,
                                                onPressed: () => _showRenameFolderDialog(
                                                  entry.path,
                                                  entry.name,
                                                ),
                                              ),
                                            if (widget.onDeleteFolder != null)
                                              IconButton(
                                                key: ValueKey(
                                                  'workspace_browser_delete_button:${entry.name}',
                                                ),
                                                icon: const Icon(
                                                  Icons.delete_outline,
                                                  size: 16,
                                                ),
                                                tooltip: l10n.workspaceBrowserDeleteFolder,
                                                onPressed: () => _showDeleteFolderDialog(
                                                  entry.path,
                                                  entry.name,
                                                ),
                                              ),
                                            const Icon(
                                              Icons.chevron_right,
                                              size: 18,
                                            ),
                                          ],
                                        )
                                      : const Icon(
                                          Icons.chevron_right,
                                          size: 18,
                                        ),
                                  onTap: () => _load(path: entry.path),
                                );
                              },
                            ),
                    ),
                    if (snapshot?.truncated == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          l10n.workspaceBrowserTruncated,
                          style: GoogleFonts.inter(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('workspace_browser_cancel_button'),
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('workspace_browser_use_folder_button'),
          onPressed: _isLoading || snapshot == null || atRoot ? null : () => Navigator.of(context).pop(snapshot.path),
          child: Text(l10n.workspaceBrowserUseFolder),
        ),
      ],
    );
  }
}

/// A folder name the dialog rejected before calling the device.
class _InvalidFolderName {
  const _InvalidFolderName();
}
