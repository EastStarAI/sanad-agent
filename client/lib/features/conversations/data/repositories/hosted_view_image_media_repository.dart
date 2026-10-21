import 'package:crypto/crypto.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_media_byte_cache.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/infrastructure/socket/hosted_conversation_media.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

final class HostedViewImageMediaRepository implements ViewImageMediaLoader, UserAttachmentMediaLoader {
  HostedViewImageMediaRepository({
    required SanadSocketService socketService,
    required String deviceId,
    ConversationMediaByteCache? cache,
  }) : _socketService = socketService,
       _deviceId = deviceId,
       _cache = cache ?? ConversationMediaByteCache.shared;

  final SanadSocketService _socketService;
  final String _deviceId;
  final ConversationMediaByteCache _cache;

  @override
  ViewImageMediaLoad load({
    required ViewImageMedia media,
    required String sessionId,
  }) => _load(
    sessionId: sessionId,
    mediaId: media.mediaId,
    kind: 'view-image',
    purpose: 'view',
    validate: (result) {
      if (result.mimeType != media.mimeType) {
        throw const FormatException('Unexpected media type.');
      }
    },
  );

  @override
  ViewImageMediaLoad loadAttachment({
    required UserMessageAttachment attachment,
    required String sessionId,
  }) => _load(
    sessionId: sessionId,
    mediaId: attachment.mediaId,
    kind: 'attachment',
    sha256: attachment.sha256,
    purpose: attachment.isImage ? 'thumbnail' : 'save',
    validate: (result) {
      if (result.mimeType != attachment.mimeType ||
          result.bytes.length != attachment.sizeBytes ||
          sha256.convert(result.bytes).toString() != attachment.sha256) {
        throw const FormatException('Unexpected attachment payload.');
      }
    },
  );

  ViewImageMediaLoad _load({
    required String sessionId,
    required String mediaId,
    required String kind,
    required String purpose,
    required void Function(HostedConversationMedia result) validate,
    String? sha256,
  }) {
    final key = ConversationMediaByteCache.keyFor(
      transport: 'hosted',
      deviceId: _deviceId,
      sessionId: sessionId,
      kind: kind,
      mediaId: mediaId,
      sha256: sha256,
    );
    final cached = _cache.get(key);
    if (cached != null) return ViewImageMediaLoad.cached(cached);
    void Function() cancel = () {};
    final bytes = _socketService
        .fetchHostedConversationMedia(
          deviceId: _deviceId,
          sessionId: sessionId,
          mediaId: mediaId,
          purpose: purpose,
          registerCancel: (callback) => cancel = callback,
        )
        .then((result) {
          validate(result);
          _cache.put(key, result.bytes);
          return result.bytes;
        });
    return ViewImageMediaLoad(bytes: bytes, cancel: () => cancel());
  }
}
