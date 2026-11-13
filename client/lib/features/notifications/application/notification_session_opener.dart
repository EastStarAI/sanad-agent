import 'package:logging/logging.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';

/// Opens the session and request a notification points at.
///
/// A notification is raised by an agent that may not be the active device, so
/// the destination is resolved from the payload identity first and from the
/// cached session index second. Navigation itself stays with the caller: this
/// class owns resolution and the window restore, not routing.
class NotificationSessionOpener {
  NotificationSessionOpener({
    required List<DeviceConfig> Function() readDevices,
    required List<Session> Function(String deviceId) sessionsForDevice,
    required String? Function() activeDeviceId,
    required Future<void> Function(ConversationDestination destination) openDestination,
    required Future<void> Function() showWindow,
  })  : _readDevices = readDevices,
        _sessionsForDevice = sessionsForDevice,
        _activeDeviceId = activeDeviceId,
        _openDestination = openDestination,
        _showWindow = showWindow;

  final List<DeviceConfig> Function() _readDevices;
  final List<Session> Function(String deviceId) _sessionsForDevice;
  final String? Function() _activeDeviceId;
  final Future<void> Function(ConversationDestination destination) _openDestination;
  final Future<void> Function() _showWindow;

  static final Logger _logger = Logger('notifications.open');

  /// The agent that owns [sessionId], when it can be resolved.
  ///
  /// The envelope's `device_id`/`hardware_id` identity wins because it names the
  /// agent that raised the ask. A notification that arrives without it is
  /// resolved through the cached session index, then through the active device
  /// as a last resort; a resolution that finds nothing fails closed instead of
  /// opening the wrong device.
  DeviceConfig? resolveAgent({
    required String sessionId,
    String? deviceId,
    String? hardwareId,
  }) {
    final devices = _readDevices();
    if (devices.isEmpty) return null;
    for (final device in devices) {
      if (deviceId != null && deviceId.isNotEmpty && device.representsDeviceId(deviceId)) {
        return device;
      }
      if (hardwareId != null && hardwareId.isNotEmpty && device.representsDeviceId(hardwareId)) {
        return device;
      }
    }
    for (final device in devices) {
      for (final session in _sessionsForDevice(device.id)) {
        if (session.id == sessionId) return device;
      }
    }
    final activeDeviceId = _activeDeviceId();
    if (activeDeviceId != null && activeDeviceId.isNotEmpty) {
      for (final device in devices) {
        if (device.id == activeDeviceId) return device;
      }
    }
    return null;
  }

  /// Brings Sanad forward and opens the session a notification points at.
  Future<void> open(NotificationPayload payload) async {
    await openSession(
      sessionId: payload.sessionId,
      requestId: payload.requestId,
      deviceId: payload.deviceId,
      hardwareId: payload.hardwareId,
    );
  }

  /// Opens a session by identity, for a launch URL a notification click
  /// produced. Returns whether a destination was reached; a click on a cold
  /// start retries once the device inventory arrives.
  Future<bool> openSession({
    required String sessionId,
    String? requestId,
    String? deviceId,
    String? hardwareId,
  }) async {
    await _showWindow();
    final agent = resolveAgent(
      sessionId: sessionId,
      deviceId: deviceId,
      hardwareId: hardwareId,
    );
    if (agent == null) {
      _logger.warning('could not resolve the device for a notification; nothing was opened');
      return false;
    }
    await _openDestination(
      ConversationDestination.session(deviceId: agent.id, sessionId: sessionId),
    );
    return true;
  }
}
