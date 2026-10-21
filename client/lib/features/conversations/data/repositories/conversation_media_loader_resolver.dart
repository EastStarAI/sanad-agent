import 'package:sanad_client/features/conversations/data/repositories/conversation_media_byte_cache.dart';
import 'package:sanad_client/features/conversations/data/repositories/hosted_view_image_media_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/view_image_media_repository.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

typedef ConversationMediaLoaders = ({
  ViewImageMediaLoader? viewImage,
  UserAttachmentMediaLoader? attachment,
});

/// Selects the byte transport outside presentation while preserving the local
/// repository defaults for the co-located hardware identity.
final class ConversationMediaLoaderResolver {
  const ConversationMediaLoaderResolver({
    required SanadSocketService cloudSocketService,
    required String hardwareId,
    ConversationMediaByteCache? cache,
  }) : _cloudSocketService = cloudSocketService,
       _hardwareId = hardwareId,
       _cache = cache;

  final SanadSocketService _cloudSocketService;
  final String _hardwareId;

  /// Shared byte cache; `null` selects [ConversationMediaByteCache.shared].
  /// Hosted loaders are rebuilt per resolve, so the cache must outlive them.
  final ConversationMediaByteCache? _cache;

  ConversationMediaLoaders resolve(String? deviceId) {
    if (deviceId == null || deviceId == _hardwareId) {
      return (viewImage: null, attachment: null);
    }
    final hosted = HostedViewImageMediaRepository(
      socketService: _cloudSocketService,
      deviceId: deviceId,
      cache: _cache,
    );
    return (viewImage: hosted, attachment: hosted);
  }
}
