import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_media_byte_cache.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';

class ViewImageMedia {
  const ViewImageMedia({
    required this.mediaId,
    required this.name,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.isAvailable,
  });

  final String mediaId;
  final String name;
  final String mimeType;
  final int width;
  final int height;
  final bool isAvailable;

  static ViewImageMedia? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<Object?, Object?>();
    final mediaId = json['media_id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final mimeType = json['mime_type']?.toString().trim() ?? '';
    final width = _positiveInt(json['width']);
    final height = _positiveInt(json['height']);
    final availability = json['availability']?.toString();
    if (!RegExp(r'^[A-Za-z0-9_-]{20,128}$').hasMatch(mediaId) ||
        !RegExp(r'^view-image\.(png|jpg|webp)$').hasMatch(name) ||
        !const {'image/png', 'image/jpeg', 'image/webp'}.contains(mimeType) ||
        width == null ||
        height == null ||
        (availability != 'available' && availability != 'unavailable')) {
      return null;
    }
    return ViewImageMedia(
      mediaId: mediaId,
      name: name,
      mimeType: mimeType,
      width: width,
      height: height,
      isAvailable: availability == 'available',
    );
  }
}

/// Tools whose rows render through the shared image media card.
const Set<String> mediaToolNames = {'view_image', 'system_screenshot'};

extension ViewImageMediaEvent on CanonicalEvent {
  ViewImageMedia? get viewImageMedia => ViewImageMedia.fromJson(tool?['media']);

  /// Whether this row belongs to a media-bearing tool by name.
  bool get isMediaToolName => mediaToolNames.contains(toolName);

  /// Whether this row is presented as media: a media-bearing tool, or any
  /// tool row that carries validated media metadata.
  bool get isMediaToolEvent => isMediaToolName || viewImageMedia != null;

  /// Whether this row renders through the shared image media card (running,
  /// error, thumbnail, or neutral unavailable state). A completed
  /// `system_screenshot` without any media metadata is a text-only outcome and
  /// keeps the regular tool presentation instead. The single-row branch and
  /// the tool-group gallery both use this rule.
  bool get rendersAsMediaCard {
    if (!isMediaToolEvent) return false;
    if (status == EventStatus.running || isError) return true;
    return toolName == 'view_image' || tool?['media'] != null;
  }
}

int? _positiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

class UserMessageAttachment {
  const UserMessageAttachment({
    required this.id,
    required this.mediaId,
    required this.safeName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    required this.isImage,
    required this.isAvailable,
  });

  final String id;
  final String mediaId;
  final String safeName;
  final String mimeType;
  final int sizeBytes;
  final String sha256;
  final bool isImage;
  final bool isAvailable;

  static UserMessageAttachment? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<Object?, Object?>();
    final id = json['id']?.toString() ?? '';
    final mediaId = json['mediaId']?.toString() ?? '';
    final safeName = json['safeName']?.toString() ?? '';
    final mimeType = json['mimeType']?.toString() ?? '';
    final sizeBytes = json['sizeBytes'];
    final sha = json['sha256']?.toString() ?? '';
    final kind = json['kind']?.toString();
    final status = json['status']?.toString();
    if (json.keys.any((key) => !_publicAttachmentKeys.contains(key)) ||
        json['schemaVersion'] != 1 ||
        !_opaqueId.hasMatch(id) ||
        !_opaqueId.hasMatch(mediaId) ||
        safeName.isEmpty ||
        safeName == '.' ||
        safeName == '..' ||
        safeName.contains('/') ||
        safeName.contains(r'\') ||
        !_mimeType.hasMatch(mimeType) ||
        sizeBytes is! int ||
        sizeBytes < 0 ||
        sizeBytes > 5 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
        (kind != 'image' && kind != 'file') ||
        (status != 'available' && status != 'unavailable') ||
        (kind == 'image') != mimeType.startsWith('image/')) {
      return null;
    }
    return UserMessageAttachment(
      id: id,
      mediaId: mediaId,
      safeName: safeName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      sha256: sha,
      isImage: kind == 'image',
      isAvailable: status == 'available',
    );
  }

  static const _publicAttachmentKeys = {
    'schemaVersion',
    'id',
    'safeName',
    'mimeType',
    'sizeBytes',
    'sha256',
    'kind',
    'mediaId',
    'status',
  };
  static final _opaqueId = RegExp(r'^[^/\\\x00-\x20\x7f]{1,200}$');
  static final _mimeType = RegExp(
    r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$',
  );
}

extension UserMessageAttachmentsEvent on CanonicalEvent {
  List<UserMessageAttachment> get userAttachments {
    final raw = metadata?['attachments'];
    if (raw is! List || raw.length > 4) return const [];
    final parsed = <UserMessageAttachment>[];
    final ids = <String>{};
    var totalBytes = 0;
    for (final value in raw) {
      final attachment = UserMessageAttachment.fromJson(value);
      if (attachment == null || !ids.add(attachment.id)) return const [];
      totalBytes += attachment.sizeBytes;
      if (totalBytes > 20 * 1024 * 1024) return const [];
      parsed.add(attachment);
    }
    return List.unmodifiable(parsed);
  }
}

typedef CancelMediaLoad = void Function();

class ViewImageMediaLoad {
  const ViewImageMediaLoad({required this.bytes, required this.cancel, this.cachedBytes});

  /// A load already satisfied by [ConversationMediaByteCache]: presentation
  /// can paint [cachedBytes] on the first frame instead of a loading state.
  ViewImageMediaLoad.cached(Uint8List value) : bytes = Future<Uint8List>.value(value), cancel = _noop, cachedBytes = value;

  final Future<Uint8List> bytes;
  final CancelMediaLoad cancel;

  /// Synchronously available bytes when the load was a cache hit.
  final Uint8List? cachedBytes;

  static void _noop() {}
}

abstract interface class ViewImageMediaLoader {
  ViewImageMediaLoad load({
    required ViewImageMedia media,
    required String sessionId,
  });
}

abstract interface class UserAttachmentMediaLoader {
  ViewImageMediaLoad loadAttachment({
    required UserMessageAttachment attachment,
    required String sessionId,
  });
}

class ViewImageMediaRepository implements ViewImageMediaLoader, UserAttachmentMediaLoader {
  ViewImageMediaRepository({
    required this.baseUrl,
    required this.hardwareId,
    LocalGatewayCredentialProvider credentialProvider = const LocalGatewayCredentialProvider(),
    Future<Map<String, String>> Function()? headerProvider,
    http.Client Function()? clientFactory,
    ConversationMediaByteCache? cache,
    this.maximumMediaBytes = 12 * 1024 * 1024,
  }) : _headerProvider = headerProvider ?? credentialProvider.headers,
       _clientFactory = clientFactory ?? http.Client.new,
       _cache = cache ?? ConversationMediaByteCache.shared;

  static ViewImageMediaRepository? _localInstance;

  factory ViewImageMediaRepository.local() => _localInstance ??= ViewImageMediaRepository(
    baseUrl: AppConfig.localGatewayUrl,
    hardwareId: getIt<String>(instanceName: 'hardwareId'),
  );

  final String baseUrl;
  final String hardwareId;
  final Future<Map<String, String>> Function() _headerProvider;
  final http.Client Function() _clientFactory;
  final int maximumMediaBytes;
  final ConversationMediaByteCache _cache;
  final Map<String, _SharedMediaRequest> _inFlight = {};

  @override
  ViewImageMediaLoad load({
    required ViewImageMedia media,
    required String sessionId,
  }) => _loadResource(
    sessionId: sessionId,
    mediaId: media.mediaId,
    route: 'view-image',
    mimeType: media.mimeType,
    maximumBytes: maximumMediaBytes,
    kind: 'view-image',
  );

  @override
  ViewImageMediaLoad loadAttachment({
    required UserMessageAttachment attachment,
    required String sessionId,
  }) => _loadResource(
    sessionId: sessionId,
    mediaId: attachment.mediaId,
    route: 'attachment',
    mimeType: attachment.mimeType,
    maximumBytes: 5 * 1024 * 1024,
    kind: 'attachment',
    sha256: attachment.sha256,
  );

  ViewImageMediaLoad _loadResource({
    required String sessionId,
    required String mediaId,
    required String route,
    required String mimeType,
    required int maximumBytes,
    required String kind,
    String? sha256,
  }) {
    final key = ConversationMediaByteCache.keyFor(
      transport: ConversationMediaByteCache.localTransport,
      deviceId: hardwareId,
      sessionId: sessionId,
      kind: kind,
      mediaId: mediaId,
      sha256: sha256,
    );
    final cached = _cache.get(key);
    if (cached != null) return ViewImageMediaLoad.cached(cached);

    final existing = _inFlight[key];
    if (existing != null) {
      existing.listeners++;
      return _handleFor(key, existing);
    }

    final client = _clientFactory();
    final shared = _SharedMediaRequest(client)..listeners = 1;
    _inFlight[key] = shared;
    shared.future =
        _fetch(
              client,
              sessionId: sessionId,
              mediaId: mediaId,
              route: route,
              mimeType: mimeType,
              maximumBytes: maximumBytes,
            )
            .then((bytes) {
              if (!shared.cancelled) _cache.put(key, bytes);
              return bytes;
            })
            .whenComplete(() {
              if (_inFlight[key] == shared) _inFlight.remove(key);
              client.close();
            });
    return _handleFor(key, shared);
  }

  ViewImageMediaLoad _handleFor(String key, _SharedMediaRequest shared) {
    var released = false;
    return ViewImageMediaLoad(
      bytes: shared.future,
      cancel: () {
        if (released) return;
        released = true;
        shared.listeners--;
        if (shared.listeners <= 0 && _inFlight[key] == shared) {
          shared.cancelled = true;
          _inFlight.remove(key);
          shared.client.close();
        }
      },
    );
  }

  Future<Uint8List> _fetch(
    http.Client client, {
    required String sessionId,
    required String mediaId,
    required String route,
    required String mimeType,
    required int maximumBytes,
  }) async {
    final base = Uri.parse(baseUrl);
    if ((base.scheme != 'http' && base.scheme != 'https') ||
        !const {'127.0.0.1', 'localhost', '::1'}.contains(base.host)) {
      throw const ViewImageMediaException('unsafe_gateway');
    }
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/media/$route/${Uri.encodeComponent(mediaId)}',
      queryParameters: {
        'session_id': sessionId,
        'device_id': hardwareId,
      },
    );
    final request = http.Request('GET', uri)..headers.addAll(await _headerProvider());
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw ViewImageMediaException('http_${response.statusCode}');
    }
    final contentType = response.headers['content-type']?.split(';').first.trim();
    if (contentType != mimeType) {
      throw const ViewImageMediaException('mime_mismatch');
    }
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength > maximumBytes) {
      throw const ViewImageMediaException('media_too_large');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > maximumBytes) {
        client.close();
        throw const ViewImageMediaException('media_too_large');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

class ViewImageMediaException implements Exception {
  const ViewImageMediaException(this.code);

  final String code;

  @override
  String toString() => 'ViewImageMediaException($code)';
}

class _SharedMediaRequest {
  _SharedMediaRequest(this.client);

  final http.Client client;
  late Future<Uint8List> future;
  int listeners = 0;
  bool cancelled = false;
}
