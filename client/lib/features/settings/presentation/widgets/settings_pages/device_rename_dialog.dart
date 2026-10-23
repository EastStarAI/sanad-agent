import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

class DeviceNameEditor extends StatelessWidget {
  const DeviceNameEditor({
    super.key,
    required this.device,
    required this.onRename,
  });

  final DeviceConfig device;
  final Future<void> Function(String name) onRename;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            device.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (device.accountDeviceId != null) ...[
          const SizedBox(width: 4),
          IconButton(
            key: const Key('device_name_edit_button'),
            tooltip: 'Rename device',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () {
              unawaited(
                showDialog<void>(
                  context: context,
                  builder: (context) => DeviceRenameDialog(
                    currentName: device.name,
                    onRename: onRename,
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class DeviceRenameDialog extends StatefulWidget {
  const DeviceRenameDialog({
    super.key,
    required this.currentName,
    required this.onRename,
  });

  final String currentName;
  final Future<void> Function(String name) onRename;

  @override
  State<DeviceRenameDialog> createState() => _DeviceRenameDialogState();
}

class _DeviceRenameDialogState extends State<DeviceRenameDialog> {
  late final TextEditingController _controller;
  String? _requestError;
  bool _saving = false;

  String get _name => _controller.text.trim();
  bool get _canSubmit =>
      !_saving && _name.isNotEmpty && _name != widget.currentName.trim() && _name.length <= DeviceConfig.maxNameLength;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.currentName.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _requestError = null;
    });
    try {
      await widget.onRename(_name);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _requestError = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename device'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const Key('device_name_field'),
          controller: _controller,
          autofocus: true,
          enabled: !_saving,
          maxLength: DeviceConfig.maxNameLength,
          decoration: InputDecoration(
            labelText: 'Device name',
            errorText: _requestError,
          ),
          onChanged: (_) => setState(() => _requestError = null),
          onSubmitted: (_) => unawaited(_submit()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('device_name_rename_button'),
          onPressed: _canSubmit ? () => unawaited(_submit()) : null,
          child: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: AppProgressIndicator(strokeWidth: 2),
                )
              : const Text('Rename'),
        ),
      ],
    );
  }
}
