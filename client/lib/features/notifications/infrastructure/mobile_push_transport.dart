import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';

import 'mobile_push_transport_unsupported.dart'
    if (dart.library.io) 'mobile_push_transport_channel.dart'
    as backend;

/// The push wake-up path, selected at compile time.
///
/// A native target gets the platform channel; a target without `dart:io` (Web)
/// resolves a total no-op, so nothing above this boundary needs a web branch.
/// The channel implementation reports whether its platform can register a token
/// at all, which keeps a build without a provider honest instead of promising a
/// delivery it cannot make.
MobilePushTransport createMobilePushTransport() => backend.createMobilePushTransport();
