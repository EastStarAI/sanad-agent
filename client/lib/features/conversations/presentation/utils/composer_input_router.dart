import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:universal_io/io.dart';

enum ComposerItemFormatKind {
  safeImage,
  unsafeImage,
  nonImage,
}

enum ComposerRoutingDecision {
  attachment,
  filePathToken,
  rejectTooLarge,
  rejectUnsupported,
}

class ComposerRoutableItem {
  final String? path;
  final String? name;
  final Uint8List? bytes;
  final int sizeBytes;

  /// Platform-neutral byte source (an [XFile] reader). Web drop/picker paths
  /// are blob URLs that `dart:io` cannot open, so attachment bytes must come
  /// from the originating [XFile] rather than from [path].
  final Future<Uint8List> Function()? readBytes;

  const ComposerRoutableItem({
    this.path,
    this.name,
    this.bytes,
    required this.sizeBytes,
    this.readBytes,
  });

  /// Reads the attachment payload: in-memory bytes first, then the
  /// originating file reader, then the local filesystem path.
  Future<Uint8List> loadBytes() async {
    final inMemory = bytes;
    if (inMemory != null && inMemory.isNotEmpty) return inMemory;
    final reader = readBytes;
    if (reader != null) {
      try {
        return await reader();
      } catch (_) {}
    }
    final localPath = path;
    if (localPath != null) {
      try {
        final file = File(localPath);
        if (file.existsSync()) return await file.readAsBytes();
      } catch (_) {}
    }
    return Uint8List(0);
  }

  static ComposerRoutableItem fromXFileSync(XFile file) {
    final path = file.path.isNotEmpty ? file.path : null;
    final name = file.name;
    Uint8List? bytes;
    int size = 0;
    if (path != null) {
      try {
        final ioFile = File(path);
        if (ioFile.existsSync()) {
          size = ioFile.lengthSync();
        }
      } catch (_) {}
    }
    return ComposerRoutableItem(
      path: path,
      name: name,
      bytes: bytes,
      sizeBytes: size,
      readBytes: file.readAsBytes,
    );
  }

  static Future<ComposerRoutableItem> fromXFile(XFile file) async {
    final item = fromXFileSync(file);
    if (item.path == null && item.bytes == null) {
      Uint8List? bytes;
      int size = 0;
      try {
        bytes = await file.readAsBytes();
        size = bytes.length;
      } catch (_) {
        try {
          size = await file.length();
        } catch (_) {}
      }
      return ComposerRoutableItem(
        path: item.path,
        name: item.name,
        bytes: bytes,
        sizeBytes: size,
        readBytes: file.readAsBytes,
      );
    }
    return item;
  }

  static ComposerRoutableItem fromFilePathSync(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    int size = 0;
    try {
      final file = File(path);
      if (file.existsSync()) {
        size = file.lengthSync();
      }
    } catch (_) {}
    return ComposerRoutableItem(
      path: path,
      name: name.isNotEmpty ? name : 'file',
      sizeBytes: size,
    );
  }

  static Future<ComposerRoutableItem> fromFilePath(String path) async {
    return fromFilePathSync(path);
  }

  static ComposerRoutableItem fromImageBytes({
    required Uint8List bytes,
    String? formatName,
    String? suggestedName,
  }) {
    final ext = formatName ?? 'png';
    // The routed format is what was actually read from the clipboard, so the
    // name must carry that extension even when the source app suggested a
    // different one (for example `photo.heic` delivered as PNG bytes).
    final suggested = suggestedName?.trim() ?? '';
    final dot = suggested.lastIndexOf('.');
    final base = dot > 0 ? suggested.substring(0, dot) : suggested;
    final name = '${base.isEmpty ? 'pasted-image' : base}.$ext';
    return ComposerRoutableItem(
      name: name,
      bytes: bytes,
      sizeBytes: bytes.length,
    );
  }
}

class ComposerInputRouter {
  ComposerInputRouter._();

  static const int defaultMaxAttachmentBytes = 5 * 1024 * 1024; // 5 MiB

  static ComposerItemFormatKind detectFormatKind(String fileName) {
    final ext = fileName.toLowerCase().split('.').lastOrNull ?? '';
    switch (ext) {
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
      case 'gif':
        return ComposerItemFormatKind.safeImage;
      case 'heic':
      case 'heif':
      case 'tiff':
      case 'tif':
      case 'bmp':
      case 'svg':
      case 'ico':
        return ComposerItemFormatKind.unsafeImage;
      default:
        return ComposerItemFormatKind.nonImage;
    }
  }

  /// Same-machine routing requires a desktop client: web and mobile are
  /// always remote, and an unknown agent identity is treated as remote.
  static bool isSameMachineAgent(DeviceConfig? activeAgent) {
    if (AppPlatform.isMobile || !AppPlatform.isDesktop) return false;
    if (activeAgent == null) return false;
    return activeAgent.isLocalCandidate;
  }

  static ComposerRoutingDecision decideRoute({
    required ComposerRoutableItem item,
    required bool isSameMachine,
    required bool supportsAttachments,
    int maxAttachmentFileBytes = defaultMaxAttachmentBytes,
  }) {
    final formatKind = detectFormatKind(item.name ?? '');
    final isSmallEnough = item.sizeBytes <= maxAttachmentFileBytes;

    switch (formatKind) {
      case ComposerItemFormatKind.safeImage:
        if (isSmallEnough) {
          if (supportsAttachments) {
            return ComposerRoutingDecision.attachment;
          } else {
            // Missing attachment capability on local agent: fall back to file path token
            if (isSameMachine && item.path != null) {
              return ComposerRoutingDecision.filePathToken;
            } else {
              return ComposerRoutingDecision.rejectUnsupported;
            }
          }
        } else {
          // Safe image > 5 MiB
          if (isSameMachine && item.path != null) {
            return ComposerRoutingDecision.filePathToken;
          } else {
            return ComposerRoutingDecision.rejectTooLarge;
          }
        }

      case ComposerItemFormatKind.unsafeImage:
        if (isSameMachine && item.path != null) {
          return ComposerRoutingDecision.filePathToken;
        } else {
          if (!supportsAttachments) {
            return ComposerRoutingDecision.rejectUnsupported;
          }
          if (!isSmallEnough) {
            return ComposerRoutingDecision.rejectTooLarge;
          }
          return ComposerRoutingDecision.attachment;
        }

      case ComposerItemFormatKind.nonImage:
        if (isSameMachine && item.path != null) {
          return ComposerRoutingDecision.filePathToken;
        } else {
          if (!supportsAttachments) {
            return ComposerRoutingDecision.rejectUnsupported;
          }
          if (!isSmallEnough) {
            return ComposerRoutingDecision.rejectTooLarge;
          }
          return ComposerRoutingDecision.attachment;
        }
    }
  }

  static Future<void> routeItem({
    required ComposerRoutableItem item,
    required SlashCommandTextController controller,
    required ConversationInputCubit inputCubit,
    required DeviceConfig? activeAgent,
    required Capability capability,
    required DraftAttachmentSource source,
  }) async {
    final isSameMachine = isSameMachineAgent(activeAgent);
    final maxAttachmentBytes = capability.attachmentMaxFileBytes > 0
        ? capability.attachmentMaxFileBytes
        : defaultMaxAttachmentBytes;
    final decision = decideRoute(
      item: item,
      isSameMachine: isSameMachine,
      supportsAttachments: capability.supportsAttachments,
      maxAttachmentFileBytes: maxAttachmentBytes,
    );

    switch (decision) {
      case ComposerRoutingDecision.attachment:
        final bytes = await item.loadBytes();
        await inputCubit.addDraftAttachment(
          name: item.name ?? 'attachment',
          bytes: bytes,
          source: source,
          capability: capability,
        );
        break;

      case ComposerRoutingDecision.filePathToken:
        if (item.path != null) {
          controller.insertFileToken(item.path!, fileName: item.name);
        }
        break;

      case ComposerRoutingDecision.rejectTooLarge:
        inputCubit.setAttachmentError(ConversationInputCubit.attachmentTooLargeError);
        break;

      case ComposerRoutingDecision.rejectUnsupported:
        inputCubit.setAttachmentError(ConversationInputCubit.attachmentsUnsupportedError);
        break;
    }
  }

  static Future<void> routeItems({
    required Iterable<ComposerRoutableItem> items,
    required SlashCommandTextController controller,
    required ConversationInputCubit inputCubit,
    required DeviceConfig? activeAgent,
    required Capability capability,
    required DraftAttachmentSource source,
  }) async {
    final seenPaths = <String>{};
    for (final item in items) {
      if (item.path != null && item.path!.isNotEmpty) {
        if (!seenPaths.add(item.path!)) continue;
      }
      await routeItem(
        item: item,
        controller: controller,
        inputCubit: inputCubit,
        activeAgent: activeAgent,
        capability: capability,
        source: source,
      );
    }
  }
}
