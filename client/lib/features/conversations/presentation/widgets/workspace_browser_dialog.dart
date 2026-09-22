import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';

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
  String? _loadError;
  String? _mutationError;

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
        _loadError = error.toString();
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
            child: const Text('Cancel'),
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
    return name.isNotEmpty && name != '.' && name != '..' && !name.contains('/') && !name.contains(r'\');
  }

  Future<void> _showCreateFolderDialog(String currentPath) async {
    final name = await _promptForFolderName(
      title: 'New Folder',
      label: 'Folder Name',
      actionLabel: 'Create',
    );
    if (!mounted || name == null) return;
    if (!_isValidFolderName(name)) {
      setState(() {
        _mutationError = 'Folder name must be a single path segment.';
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
    final newName = await _promptForFolderName(
      title: 'Rename Folder',
      label: 'New Folder Name',
      actionLabel: 'Rename',
      initialValue: currentName,
    );
    if (!mounted || newName == null || newName.trim() == currentName) return;
    if (!_isValidFolderName(newName)) {
      setState(() {
        _mutationError = 'Folder name must be a single path segment.';
      });
      return;
    }

    await _runMutation(
      () => widget.onRenameFolder!(folderPath, newName.trim()),
      refreshPath: _snapshot?.path,
    );
  }

  Future<void> _showDeleteFolderDialog(String folderPath, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Folder'),
        content: Text(
          'Delete "$name" and all files and folders inside it? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('workspace_folder_delete_confirm_button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
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
        _mutationError = error.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    final directories = snapshot?.entries.where((entry) => entry.isDirectory).toList(growable: false) ?? const [];
    final canGoUp = snapshot?.parentPath != null;
    final canMutateCurrentPath = snapshot != null && snapshot.path.isNotEmpty;

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Choose Workspace')),
          if (canMutateCurrentPath && widget.onCreateFolder != null)
            IconButton(
              key: const Key('workspace_browser_new_folder_button'),
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: 'New Folder',
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
                child: Text(
                  snapshot.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
                  _mutationError!,
                  key: const ValueKey('workspace-folder-mutation-error'),
                  style: GoogleFonts.inter(
                    color: colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            if (_isLoading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null)
              Expanded(
                child: Center(
                  child: Text(
                    _loadError!,
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
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.arrow_upward_outlined,
                          size: 18,
                        ),
                        title: const Text('..'),
                        onTap: () => _load(path: snapshot!.parentPath),
                      ),
                    Expanded(
                      child: directories.isEmpty
                          ? Center(
                              child: Text(
                                'No folders found here.',
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
                                                icon: const Icon(
                                                  Icons.edit_outlined,
                                                  size: 16,
                                                ),
                                                tooltip: 'Rename Folder',
                                                onPressed: () => _showRenameFolderDialog(
                                                  entry.path,
                                                  entry.name,
                                                ),
                                              ),
                                            if (widget.onDeleteFolder != null)
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.delete_outline,
                                                  size: 16,
                                                ),
                                                tooltip: 'Delete Folder',
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
                          'Showing the first set of entries for this folder.',
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
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isLoading || snapshot == null ? null : () => Navigator.of(context).pop(snapshot.path),
          child: const Text('Use This Folder'),
        ),
      ],
    );
  }
}
