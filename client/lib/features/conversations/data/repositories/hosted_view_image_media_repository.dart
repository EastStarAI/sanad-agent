import 'package:crypto/crypto.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

final class HostedViewImageMediaRepository implements ViewImageMediaLoader, UserAttachmentMediaLoader {
  const HostedViewImageMediaRepository({
    required SanadSocketService socketService,
    required String deviceId,
  }) : _socketService = socketService,
       _deviceId = deviceId;

  final SanadSocketService _socketService;
  final String _deviceId;

  @override
  ViewImageMediaLoad load({
    required ViewImageMedia media,
    required String sessionId,
  }) {
    void Function() cancel = () {};
    final bytes = _socketService
        .fetchHostedConversationMedia(
          deviceId: _deviceId,
          sessionId: sessionId,
          mediaId: media.mediaId,
          purpose: 'view',
          registerCancel: (callback) => cancel = callback,
        )
        .then((result) {
          if (result.mimeType != media.mimeType) {
            throw const FormatException('Unexpected media type.');
          }
          return result.bytes;
        });
    return ViewImageMediaLoad(bytes: bytes, cancel: () => cancel());
  }

  @override
  ViewImageMediaLoad loadAttachment({
    required UserMessageAttachment attachment,
    required String sessionId,
  }) {
    void Function() cancel = () {};
    final bytes = _socketService
        .fetchHostedConversationMedia(
          deviceId: _deviceId,
          sessionId: sessionId,
          mediaId: attachment.mediaId,
          purpose: attachment.isImage ? 'thumbnail' : 'save',
          registerCancel: (callback) => cancel = callback,
        )
        .then((result) {
          if (result.mimeType != attachment.mimeType ||
              result.bytes.length != attachment.sizeBytes ||
              sha256.convert(result.bytes).toString() != attachment.sha256) {
            throw const FormatException('Unexpected attachment payload.');
          }
          return result.bytes;
        });
    return ViewImageMediaLoad(bytes: bytes, cancel: () => cancel());
  }
}
