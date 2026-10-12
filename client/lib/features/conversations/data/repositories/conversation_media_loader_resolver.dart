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
  }) : _cloudSocketService = cloudSocketService,
       _hardwareId = hardwareId;

  final SanadSocketService _cloudSocketService;
  final String _hardwareId;

  ConversationMediaLoaders resolve(String? deviceId) {
    if (deviceId == null || deviceId == _hardwareId) {
      return (viewImage: null, attachment: null);
    }
    final hosted = HostedViewImageMediaRepository(
      socketService: _cloudSocketService,
      deviceId: deviceId,
    );
    return (viewImage: hosted, attachment: hosted);
  }
}
