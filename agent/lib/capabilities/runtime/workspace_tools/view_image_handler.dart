import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/models/tool_execution_result.dart';
import '../../image/image_policy.dart';
import '../../image/image_worker.dart';
import '../../tools/base_tool.dart';
import '../workspace_path_resolver.dart';

typedef ExternalImagePathAuthorizer =
    Future<void> Function(
      String canonicalPath,
      Map<String, dynamic> arguments,
      ToolContext? context,
    );
typedef ImageByteReader = Future<List<int>> Function(String canonicalPath);

class ViewImageHandler {
  ViewImageHandler(
    this._pathResolver, {
    ImageWorker? imageWorker,
    ImageByteReader? readBytes,
  }) : _imageWorker = imageWorker ?? ImageWorker(),
       _readBytes = readBytes ?? _readFileBytes;

  final WorkspacePathResolver _pathResolver;
  final ImageWorker _imageWorker;
  final ImageByteReader _readBytes;

  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> arguments, {
    required String? workspacePath,
    required List<String> admittedAttachmentPaths,
    required ExternalImagePathAuthorizer authorizeExternal,
    ToolContext? context,
  }) async {
    final inputPath = arguments['path'];
    if (inputPath is! String || inputPath.trim().isEmpty) {
      return _failure(
        ToolResultErrorCode.invalidInput,
        'view_image requires one local file path.',
      );
    }
    final trimmedPath = inputPath.trim();
    if (_isRemoteOrDataSource(trimmedPath)) {
      return _failure(
        ToolResultErrorCode.invalidInput,
        'view_image accepts local file paths only.',
      );
    }
    final detail = _parseDetail(arguments['detail']);
    if (detail == null) {
      return _failure(
        ToolResultErrorCode.invalidInput,
        'Image detail must be low, auto, high, or original.',
      );
    }

    WorkspacePathResolution resolution;
    try {
      resolution = _resolveTarget(
        trimmedPath,
        workspacePath: workspacePath,
        admittedAttachmentPaths: admittedAttachmentPaths,
      );
    } on FileSystemException {
      return _failure(
        ToolResultErrorCode.notFound,
        'Image file was not found.',
      );
    } on FormatException {
      return _failure(
        ToolResultErrorCode.invalidInput,
        'view_image requires one local file path.',
      );
    }

    final canonicalAttachments = _canonicalAttachmentPaths(
      admittedAttachmentPaths,
    );
    final grantedByAttachment = canonicalAttachments.contains(
      resolution.resolvedPath,
    );
    if (!grantedByAttachment &&
        (workspacePath == null || workspacePath.trim().isEmpty)) {
      return _failure(
        ToolResultErrorCode.permissionDenied,
        'Image path is outside the admitted attachment scope.',
      );
    }
    if (!grantedByAttachment && resolution.isExternal) {
      try {
        await authorizeExternal(resolution.resolvedPath, arguments, context);
      } catch (_) {
        return _failure(
          ToolResultErrorCode.permissionDenied,
          'Permission to read the image was denied.',
        );
      }
    }

    try {
      final type = FileSystemEntity.typeSync(
        resolution.resolvedPath,
        followLinks: true,
      );
      if (type == FileSystemEntityType.notFound) {
        return _failure(
          ToolResultErrorCode.notFound,
          'Image file was not found.',
        );
      }
      if (type != FileSystemEntityType.file) {
        return _failure(
          ToolResultErrorCode.invalidInput,
          'view_image accepts one file, not a directory.',
        );
      }
      final stat = await File(resolution.resolvedPath).stat();
      if (!ImagePolicy.isInputWithinLimit(stat.size)) {
        return _failure(
          ToolResultErrorCode.tooLarge,
          'Image exceeds the 20 MiB input limit.',
        );
      }
      final bytes = await _readBytes(resolution.resolvedPath);
      final processed = await _imageWorker.process(
        Uint8List.fromList(bytes),
        detail: detail,
      );
      if (processed is ImagePolicyFailure) {
        return _failure(processed.code, processed.message);
      }
      final success = processed as ImagePolicySuccess;
      return ToolExecutionResult(
        blocks: [
          ToolTextBlock(
            text:
                'Image loaded (${success.width}×${success.height}, ${success.mimeType}, ${detail.name}).',
          ),
          ToolImageBlock(
            dataBase64: base64.encode(success.bytes),
            mimeType: success.mimeType,
            width: success.width,
            height: success.height,
            detail: detail,
          ),
        ],
      );
    } on FileSystemException {
      return _failure(
        ToolResultErrorCode.notFound,
        'Image file was not found.',
      );
    } catch (_) {
      return _failure(
        ToolResultErrorCode.processingFailed,
        'Image processing failed.',
      );
    }
  }

  WorkspacePathResolution _resolveTarget(
    String inputPath, {
    required String? workspacePath,
    required List<String> admittedAttachmentPaths,
  }) {
    if (workspacePath != null && workspacePath.trim().isNotEmpty) {
      return _pathResolver.classifyExistingPath(
        workspaceRoot: workspacePath,
        inputPath: inputPath,
      );
    }
    if (!p.isAbsolute(inputPath) || admittedAttachmentPaths.isEmpty) {
      throw const FormatException('Attachment-only paths must be absolute.');
    }
    return _pathResolver.classifyExistingPath(
      workspaceRoot: p.dirname(admittedAttachmentPaths.first),
      inputPath: inputPath,
    );
  }

  Set<String> _canonicalAttachmentPaths(List<String> paths) {
    final canonical = <String>{};
    for (final path in paths) {
      if (path.trim().isEmpty || !p.isAbsolute(path)) {
        continue;
      }
      try {
        canonical.add(
          _pathResolver
              .classifyExistingPath(
                workspaceRoot: p.dirname(path),
                inputPath: path,
              )
              .resolvedPath,
        );
      } on FileSystemException {
        // Stale grants do not authorize any path.
      }
    }
    return canonical;
  }

  ToolImageDetail? _parseDetail(Object? value) {
    final wireValue = value?.toString() ?? ToolImageDetail.auto.name;
    for (final detail in ToolImageDetail.values) {
      if (detail.name == wireValue) {
        return detail;
      }
    }
    return null;
  }

  bool _isRemoteOrDataSource(String path) {
    final lower = path.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:') ||
        lower.startsWith('file://');
  }

  static Future<List<int>> _readFileBytes(String path) =>
      File(path).readAsBytes();

  ToolExecutionResult _failure(ToolResultErrorCode code, String message) =>
      ToolExecutionResult.text(message, isError: true, errorCode: code);
}
