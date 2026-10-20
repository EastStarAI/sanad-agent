import 'dart:io';

/// Reservation attempts a caller may spend before a port collision is treated
/// as a real failure rather than a concurrent-suite race.
const defaultPortReservationAttempts = 5;

/// Returns a loopback port that was free at reservation time.
///
/// The probe socket is closed before returning because neither [ServerSocket]
/// nor [HttpServer] can adopt it, so the port is advisory: another suite may
/// claim it before the caller binds. Bind through
/// [bindOnReservedLoopbackPort] to survive that.
Future<int> reserveFreeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Binds on a freshly reserved loopback port and returns [bind]'s result.
///
/// A server cannot adopt an already-open probe socket, so the close/rebind
/// window between [reserveFreeLoopbackPort] and [bind] is inherent: a
/// concurrent `dart test` isolate can legitimately take the port first. The
/// collision is therefore handled, not ignored: an "address already in use"
/// failure re-reserves a new ephemeral port instead of failing an otherwise
/// healthy test, and every other failure is rethrown immediately. Without a
/// free port after [maxAttempts] the last collision is rethrown.
///
/// [reserve] exists so tests can inject a stolen reservation deterministically.
Future<T> bindOnReservedLoopbackPort<T>(
  Future<T> Function(int port) bind, {
  Future<int> Function() reserve = reserveFreeLoopbackPort,
  int maxAttempts = defaultPortReservationAttempts,
}) async {
  assert(maxAttempts > 0, 'A port reservation needs at least one attempt.');
  SocketException? lastError;
  StackTrace? lastStackTrace;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final port = await reserve();
    try {
      return await bind(port);
    } on SocketException catch (error, stackTrace) {
      if (!_isAddressInUse(error)) rethrow;
      lastError = error;
      lastStackTrace = stackTrace;
    }
  }
  Error.throwWithStackTrace(lastError!, lastStackTrace!);
}

/// OS "address already in use" codes: Linux 98, macOS/BSD 48, Windows 10048.
const _addressInUseCodes = {48, 98, 10048};

bool _isAddressInUse(SocketException error) {
  final osError = error.osError;
  if (osError != null && _addressInUseCodes.contains(osError.errorCode)) {
    return true;
  }
  return _mentionsAddressInUse(error.message) ||
      _mentionsAddressInUse(osError?.message ?? '');
}

bool _mentionsAddressInUse(String message) {
  final normalized = message.toLowerCase();
  return normalized.contains('address already in use') ||
      normalized.contains('only one usage of each socket address') ||
      // macOS refuses a repeat bind of an exclusively held port with this hint
      // instead of the POSIX EADDRINUSE text, and reports `errorCode == -1`.
      normalized.contains('shared flag to bind() needs to be');
}
