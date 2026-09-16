import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/core/di/injection.dart';
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

extension ViewImageMediaEvent on CanonicalEvent {
  ViewImageMedia? get viewImageMedia => ViewImageMedia.fromJson(tool?['media']);
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
  const ViewImageMediaLoad({required this.bytes, required this.cancel});

  final Future<Uint8List> bytes;
  final CancelMediaLoad cancel;
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
    this.maximumCacheEntries = 12,
    this.maximumCacheBytes = 24 * 1024 * 1024,
    this.maximumMediaBytes = 12 * 1024 * 1024,
  }) : _headerProvider = headerProvider ?? credentialProvider.headers,
       _clientFactory = clientFactory ?? http.Client.new;

  static ViewImageMediaRepository? _localInstance;

  factory ViewImageMediaRepository.local() => _localInstance ??= ViewImageMediaRepository(
    baseUrl: AppConfig.localGatewayUrl,
    hardwareId: getIt<String>(instanceName: 'hardwareId'),
  );

  final String baseUrl;
  final String hardwareId;
  final Future<Map<String, String>> Function() _headerProvider;
  final http.Client Function() _clientFactory;
  final int maximumCacheEntries;
  final int maximumCacheBytes;
  final int maximumMediaBytes;
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  final Map<String, _SharedMediaRequest> _inFlight = {};
  int _cachedBytes = 0;

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
  );

  ViewImageMediaLoad _loadResource({
    required String sessionId,
    required String mediaId,
    required String route,
    required String mimeType,
    required int maximumBytes,
  }) {
    final key = '$route\u0000$hardwareId\u0000$sessionId\u0000$mediaId';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return ViewImageMediaLoad(
        bytes: Future<Uint8List>.value(cached),
        cancel: () {},
      );
    }

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
              if (!shared.cancelled) _store(key, bytes);
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

  void _store(String key, Uint8List bytes) {
    if (bytes.length > maximumCacheBytes || maximumCacheEntries <= 0) return;
    final replaced = _cache.remove(key);
    if (replaced != null) _cachedBytes -= replaced.length;
    _cache[key] = bytes;
    _cachedBytes += bytes.length;
    while (_cache.length > maximumCacheEntries || _cachedBytes > maximumCacheBytes) {
      final oldestKey = _cache.keys.first;
      _cachedBytes -= _cache.remove(oldestKey)!.length;
    }
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
