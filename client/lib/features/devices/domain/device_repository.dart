import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';

class DeviceMutationException implements Exception {
  const DeviceMutationException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class IDeviceRepository {
  Future<void> init();
  List<DeviceConfig> get agents;
  Stream<List<DeviceConfig>> get onAgentsUpdate;
  Future<List<DeviceConfig>> fetchAgents();
  DeviceConfig? getActiveAgent();

  /// The currently persisted active device id, regardless of whether the
  /// device list has loaded yet. Returns `null` when no active id is stored.
  /// Used to distinguish "no saved device" (safe to fall back to a default)
  /// from "saved device not loaded yet" (must not fall back).
  String? getActiveAgentId();

  /// Whether a cloud device inventory can still arrive for this Client: the
  /// cloud gateway is enabled, a Sanad account session exists, and the cloud
  /// socket is connecting, authenticating, reconnecting, or ready without an
  /// authoritative inventory yet. While it is pending, a persisted device that
  /// is not loaded yet is awaited; once it is not pending (cloud disabled,
  /// signed out, or the cloud socket failed) the persisted device cannot
  /// appear, so the active device falls back without forgetting it.
  bool get isCloudInventoryPending;
  Future<void> setActiveAgent(String? deviceId);
  void createAgent(String name, {String type = 'computer'});
  Future<void> renameAgent(DeviceConfig device, String name);
  void deleteAgent(String deviceId);
  Future<void> clearAgents();
  void dispose();
}
