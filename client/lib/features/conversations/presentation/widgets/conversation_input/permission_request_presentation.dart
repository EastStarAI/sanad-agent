import '../../../domain/models/device_suspended_request.dart';

class PermissionRequestDetail {
  final String? label;
  final String value;

  const PermissionRequestDetail({this.label, required this.value});
}

class PermissionRequestPresentation {
  final String title;
  final List<PermissionRequestDetail> details;

  const PermissionRequestPresentation({
    required this.title,
    required this.details,
  });

  factory PermissionRequestPresentation.fromRequest(
    DeviceSuspendedRequest request,
  ) {
    final action = _normalizedAction(request);
    final toolSource = request.tool['source'];
    final isMcp =
        action.startsWith('mcp__') ||
        request.tool['category'] == 'mcp' ||
        (toolSource is Map && toolSource['type'] == 'mcp_server');

    if (isMcp) {
      return PermissionRequestPresentation(
        title: 'Allow Sanad to use this MCP tool?',
        details: _mcpDetails(request, action),
      );
    }

    final title = switch (action) {
      'shell_execute' => 'Allow Sanad to run this command?',
      'file_read' => 'Allow Sanad to read this file?',
      'file_write' => 'Allow Sanad to write to this file?',
      'file_edit' => 'Allow Sanad to edit this file?',
      'search_glob' => 'Allow Sanad to search for matching files?',
      'search_grep' => 'Allow Sanad to search these files?',
      _ => 'Allow Sanad to use this tool?',
    };

    final details = <PermissionRequestDetail>[];
    if (action == 'shell_execute') {
      _addDetail(details, null, request.toolInput['command']);
      _addDetail(details, 'Working directory', request.toolInput['cwd']);
      _addRemainingInputs(
        details,
        request.toolInput,
        excludedKeys: const {'action', 'command', 'cwd'},
      );
    } else if (_knownActions.contains(action)) {
      _addDetail(details, null, request.toolInput['path']);
      _addDetail(details, 'Pattern', request.toolInput['pattern']);
      _addRemainingInputs(
        details,
        request.toolInput,
        excludedKeys: const {'action', 'path', 'pattern'},
      );
    } else {
      _addDetail(
        details,
        null,
        request.tool['display_name'] ?? request.toolName,
      );
      _addRemainingInputs(
        details,
        request.toolInput,
        excludedKeys: const {'action'},
      );
    }

    if (details.isEmpty) {
      _addDetail(details, null, request.toolName);
    }
    return PermissionRequestPresentation(title: title, details: details);
  }

  static const _knownActions = {
    'shell_execute',
    'file_read',
    'file_write',
    'file_edit',
    'search_glob',
    'search_grep',
  };

  static String _normalizedAction(DeviceSuspendedRequest request) {
    final displayAction = request.toolInput['action']?.toString().trim();
    if (displayAction != null && displayAction.isNotEmpty) {
      return displayAction;
    }
    return request.toolName.trim();
  }

  static List<PermissionRequestDetail> _mcpDetails(
    DeviceSuspendedRequest request,
    String action,
  ) {
    final details = <PermissionRequestDetail>[];
    final source = request.tool['source'];
    final sourceMap = source is Map ? source : const <String, dynamic>{};
    final nameParts = action.split('__');
    final server = request.tool['server_name'] ?? sourceMap['id'] ?? (nameParts.length >= 3 ? nameParts[1] : null);
    final toolName =
        request.tool['display_name'] ??
        sourceMap['original_name'] ??
        (nameParts.length >= 3 ? nameParts.sublist(2).join('__') : action);

    final identity = [
      server,
      toolName,
    ].where((value) => value != null && value.toString().trim().isNotEmpty).join(' / ');
    _addDetail(details, null, identity);
    _addRemainingInputs(
      details,
      request.toolInput,
      excludedKeys: const {'action'},
    );
    return details;
  }

  static void _addRemainingInputs(
    List<PermissionRequestDetail> details,
    Map<String, dynamic> inputs, {
    required Set<String> excludedKeys,
  }) {
    for (final entry in inputs.entries) {
      if (excludedKeys.contains(entry.key)) continue;
      _addDetail(details, _humanize(entry.key), entry.value);
    }
  }

  static void _addDetail(
    List<PermissionRequestDetail> details,
    String? label,
    Object? value,
  ) {
    if (value == null) return;
    final formatted = _formatValue(value);
    if (formatted.isEmpty) return;
    details.add(PermissionRequestDetail(label: label, value: formatted));
  }

  static String _humanize(String key) {
    final words = key
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match[1]} ${match[2]}',
        )
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
    if (words.isEmpty) return 'Value';
    return '${words[0].toUpperCase()}${words.substring(1)}';
  }

  static String _formatValue(Object? value, {int depth = 0}) {
    if (value == null) return 'None';
    if (value is Map) {
      if (value.isEmpty) return 'None';
      return value.entries
          .map(
            (entry) => '${_humanize(entry.key.toString())}: ${_formatValue(entry.value, depth: depth + 1)}',
          )
          .join('\n');
    }
    if (value is Iterable) {
      if (value.isEmpty) return 'None';
      return value.map((item) => '• ${_formatValue(item, depth: depth + 1)}').join('\n');
    }
    return value.toString();
  }
}
