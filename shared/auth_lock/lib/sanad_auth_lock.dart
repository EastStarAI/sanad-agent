library;

export 'src/auth_file_lock_stub.dart'
    if (dart.library.io) 'src/native_auth_file_lock.dart';
