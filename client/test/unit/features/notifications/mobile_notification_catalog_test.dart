import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_notification_catalog.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';

NotificationPayload _payload({
  NotificationKind kind = NotificationKind.permissionRequest,
  String? channelHint,
  String? categoryHint,
}) {
  return NotificationPayload.fromEvent(<String, dynamic>{
    'event': 'notification',
    'event_id': 'evt-1',
    'session_id': 's1',
    'payload': <String, dynamic>{
      'kind': kind.wire,
      'deep_link': <String, dynamic>{'session_id': 's1'},
      if (channelHint != null || categoryHint != null)
        'platform_hints': <String, dynamic>{
          if (channelHint != null) 'android_channel_id': channelHint,
          if (categoryHint != null) 'ios_category': categoryHint,
        },
    },
  })!;
}

void main() {
  group('MobileNotificationCatalog', () {
    test('every kind owns one high importance channel from the first creation', () {
      final channels = MobileNotificationCatalog.channels;
      expect(channels.length, NotificationKind.values.length);
      for (final channel in channels) {
        expect(channel.isHighImportance, isTrue);
        expect(channel.id, 'sanad_${channel.kind.wire}_high');
      }
      // Muting one kind must never mute another, so no two kinds share a channel.
      expect(channels.map((channel) => channel.id).toSet().length, channels.length);
    });

    test('every kind owns one iOS category, and only an ask carries actions', () {
      final categories = MobileNotificationCatalog.categories;
      expect(categories.length, NotificationKind.values.length);
      expect(
        categories.map((category) => category.id),
        contains('SANAD_PERMISSION_REQUEST'),
      );
      for (final category in categories) {
        expect(category.offersApprovalActions, category.kind == NotificationKind.permissionRequest);
      }
    });

    test('an Agent hint is honoured only when it names a channel this Client owns', () {
      expect(
        MobileNotificationCatalog.channelIdFor(_payload(channelHint: 'sanad_permission_request_high')),
        'sanad_permission_request_high',
      );
      // A disagreeing hint is ignored, exactly like a disagreeing collapse key.
      expect(
        MobileNotificationCatalog.channelIdFor(_payload(channelHint: 'chat_messages')),
        'sanad_permission_request_high',
      );
      expect(
        MobileNotificationCatalog.categoryIdFor(_payload(categoryHint: 'SANAD_PERMISSION_REQUEST')),
        'SANAD_PERMISSION_REQUEST',
      );
      expect(
        MobileNotificationCatalog.categoryIdFor(_payload(categoryHint: 'OTHER_CATEGORY')),
        'SANAD_PERMISSION_REQUEST',
      );
    });

    test('the payload carries platform hints through a presentation round trip', () {
      final payload = _payload(
        channelHint: 'sanad_completed_high',
        categoryHint: 'SANAD_COMPLETED',
      );
      final restored = NotificationPayload.fromPresentationPayload(payload.toPresentationPayload());
      expect(restored, isNotNull);
      expect(restored!.androidChannelId, 'sanad_completed_high');
      expect(restored.iosCategory, 'SANAD_COMPLETED');
    });
  });
}
