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

class ViewImageMediaRepository implements ViewImageMediaLoader {
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
  }) {
    final key = '$hardwareId\u0000$sessionId\u0000${media.mediaId}';
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
    shared.future = _fetch(client, media, sessionId)
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
    http.Client client,
    ViewImageMedia media,
    String sessionId,
  ) async {
    final base = Uri.parse(baseUrl);
    if ((base.scheme != 'http' && base.scheme != 'https') ||
        !const {'127.0.0.1', 'localhost', '::1'}.contains(base.host)) {
      throw const ViewImageMediaException('unsafe_gateway');
    }
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/media/view-image/${Uri.encodeComponent(media.mediaId)}',
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
    if (contentType != media.mimeType) {
      throw const ViewImageMediaException('mime_mismatch');
    }
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength > maximumMediaBytes) {
      throw const ViewImageMediaException('media_too_large');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > maximumMediaBytes) {
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
