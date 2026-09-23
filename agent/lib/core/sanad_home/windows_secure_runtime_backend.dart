import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _tokenQuery = 0x0008;
const _tokenUser = 1;
const _sddlRevision1 = 1;
const _seFileObject = 1;
const _daclSecurityInformation = 0x00000004;
const _protectedDaclSecurityInformation = 0x80000000;
const _moveFileReplaceExisting = 0x00000001;
const _moveFileWriteThrough = 0x00000008;

/// Applies the Windows security and replacement primitives used by secure
/// runtime files without starting a shell or helper process.
class WindowsSecureRuntimeBackend {
  WindowsSecureRuntimeBackend({
    DynamicLibrary? advapi32,
    DynamicLibrary? kernel32,
  }) : _advapi32 = advapi32 ?? DynamicLibrary.open('advapi32.dll'),
       _kernel32 = kernel32 ?? DynamicLibrary.open('kernel32.dll') {
    _openProcessToken = _advapi32
        .lookupFunction<_OpenProcessTokenNative, _OpenProcessTokenDart>(
          'OpenProcessToken',
        );
    _getTokenInformation = _advapi32
        .lookupFunction<_GetTokenInformationNative, _GetTokenInformationDart>(
          'GetTokenInformation',
        );
    _convertSidToStringSid = _advapi32
        .lookupFunction<
          _ConvertSidToStringSidNative,
          _ConvertSidToStringSidDart
        >('ConvertSidToStringSidW');
    _convertStringSecurityDescriptor = _advapi32
        .lookupFunction<
          _ConvertStringSecurityDescriptorNative,
          _ConvertStringSecurityDescriptorDart
        >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
    _getSecurityDescriptorDacl = _advapi32
        .lookupFunction<
          _GetSecurityDescriptorDaclNative,
          _GetSecurityDescriptorDaclDart
        >('GetSecurityDescriptorDacl');
    _setNamedSecurityInfo = _advapi32
        .lookupFunction<_SetNamedSecurityInfoNative, _SetNamedSecurityInfoDart>(
          'SetNamedSecurityInfoW',
        );
    _getCurrentProcess = _kernel32
        .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
          'GetCurrentProcess',
        );
    _closeHandle = _kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
      'LocalFree',
    );
    _moveFileEx = _kernel32.lookupFunction<_MoveFileExNative, _MoveFileExDart>(
      'MoveFileExW',
    );
  }

  final DynamicLibrary _advapi32;
  final DynamicLibrary _kernel32;
  late final _OpenProcessTokenDart _openProcessToken;
  late final _GetTokenInformationDart _getTokenInformation;
  late final _ConvertSidToStringSidDart _convertSidToStringSid;
  late final _ConvertStringSecurityDescriptorDart
  _convertStringSecurityDescriptor;
  late final _GetSecurityDescriptorDaclDart _getSecurityDescriptorDacl;
  late final _SetNamedSecurityInfoDart _setNamedSecurityInfo;
  late final _GetCurrentProcessDart _getCurrentProcess;
  late final _CloseHandleDart _closeHandle;
  late final _LocalFreeDart _localFree;
  late final _MoveFileExDart _moveFileEx;
  late final String _currentUserSid = _readCurrentUserSid();

  void restrictPath(String path, {required bool directory}) {
    final inheritance = directory ? 'OICI' : '';
    final sddl = 'D:P(A;$inheritance;FA;;;$_currentUserSid)';
    final sddlPointer = sddl.toNativeUtf16();
    final descriptorPointer = calloc<Pointer<Void>>();
    final descriptorSize = calloc<Uint32>();
    Pointer<Void> descriptor = nullptr;
    try {
      if (_convertStringSecurityDescriptor(
            sddlPointer,
            _sddlRevision1,
            descriptorPointer,
            descriptorSize,
          ) ==
          0) {
        throw const WindowsSecureRuntimeException(
          'invalid_security_descriptor',
        );
      }
      descriptor = descriptorPointer.value;
      final daclPresent = calloc<Int32>();
      final daclDefaulted = calloc<Int32>();
      final daclPointer = calloc<Pointer<Void>>();
      try {
        if (_getSecurityDescriptorDacl(
                  descriptor,
                  daclPresent,
                  daclPointer,
                  daclDefaulted,
                ) ==
                0 ||
            daclPresent.value == 0 ||
            daclPointer.value == nullptr) {
          throw const WindowsSecureRuntimeException('invalid_dacl');
        }
        final pathPointer = path.toNativeUtf16();
        try {
          final result = _setNamedSecurityInfo(
            pathPointer,
            _seFileObject,
            _daclSecurityInformation | _protectedDaclSecurityInformation,
            nullptr,
            nullptr,
            daclPointer.value,
            nullptr,
          );
          if (result != 0) {
            throw WindowsSecureRuntimeException('set_dacl_failed:$result');
          }
        } finally {
          calloc.free(pathPointer);
        }
      } finally {
        calloc.free(daclPresent);
        calloc.free(daclDefaulted);
        calloc.free(daclPointer);
      }
    } finally {
      if (descriptor != nullptr) _localFree(descriptor);
      calloc.free(sddlPointer);
      calloc.free(descriptorPointer);
      calloc.free(descriptorSize);
    }
  }

  void replaceFile(String source, String destination) {
    final sourcePointer = source.toNativeUtf16();
    final destinationPointer = destination.toNativeUtf16();
    try {
      var success = false;
      for (var i = 0; i < 10; i++) {
        if (_moveFileEx(
              sourcePointer,
              destinationPointer,
              _moveFileReplaceExisting | _moveFileWriteThrough,
            ) !=
            0) {
          success = true;
          break;
        }
        sleep(const Duration(milliseconds: 50));
      }
      if (!success) {
        throw const WindowsSecureRuntimeException('move_file_failed');
      }
    } finally {
      calloc.free(sourcePointer);
      calloc.free(destinationPointer);
    }
  }

  String _readCurrentUserSid() {
    final tokenPointer = calloc<Pointer<Void>>();
    Pointer<Void> token = nullptr;
    try {
      if (_openProcessToken(_getCurrentProcess(), _tokenQuery, tokenPointer) ==
          0) {
        throw const WindowsSecureRuntimeException('open_process_token_failed');
      }
      token = tokenPointer.value;
      final requiredLength = calloc<Uint32>();
      try {
        _getTokenInformation(token, _tokenUser, nullptr, 0, requiredLength);
        if (requiredLength.value == 0) {
          throw const WindowsSecureRuntimeException('token_user_size_failed');
        }
        final tokenUser = calloc<Uint8>(requiredLength.value).cast<Void>();
        try {
          if (_getTokenInformation(
                token,
                _tokenUser,
                tokenUser,
                requiredLength.value,
                requiredLength,
              ) ==
              0) {
            throw const WindowsSecureRuntimeException('token_user_failed');
          }
          final sid = tokenUser.cast<Pointer<Void>>().value;
          if (sid == nullptr) {
            throw const WindowsSecureRuntimeException('token_sid_missing');
          }
          final sidStringPointer = calloc<Pointer<Utf16>>();
          Pointer<Utf16> sidString = nullptr;
          try {
            if (_convertSidToStringSid(sid, sidStringPointer) == 0) {
              throw const WindowsSecureRuntimeException(
                'sid_string_conversion_failed',
              );
            }
            sidString = sidStringPointer.value;
            return sidString.toDartString();
          } finally {
            if (sidString != nullptr) _localFree(sidString.cast<Void>());
            calloc.free(sidStringPointer);
          }
        } finally {
          calloc.free(tokenUser);
        }
      } finally {
        calloc.free(requiredLength);
      }
    } finally {
      if (token != nullptr) _closeHandle(token);
      calloc.free(tokenPointer);
    }
  }
}

class WindowsSecureRuntimeException implements Exception {
  const WindowsSecureRuntimeException(this.code);

  final String code;

  @override
  String toString() => 'WindowsSecureRuntimeException($code)';
}

typedef _OpenProcessTokenNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>);
typedef _OpenProcessTokenDart =
    int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _GetTokenInformationNative =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
    );
typedef _GetTokenInformationDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>);
typedef _ConvertSidToStringSidNative =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _ConvertSidToStringSidDart =
    int Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _ConvertStringSecurityDescriptorNative =
    Int32 Function(
      Pointer<Utf16>,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Uint32>,
    );
typedef _ConvertStringSecurityDescriptorDart =
    int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _GetSecurityDescriptorDaclNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Int32>,
      Pointer<Pointer<Void>>,
      Pointer<Int32>,
    );
typedef _GetSecurityDescriptorDaclDart =
    int Function(
      Pointer<Void>,
      Pointer<Int32>,
      Pointer<Pointer<Void>>,
      Pointer<Int32>,
    );
typedef _SetNamedSecurityInfoNative =
    Uint32 Function(
      Pointer<Utf16>,
      Int32,
      Uint32,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
    );
typedef _SetNamedSecurityInfoDart =
    int Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
    );
typedef _GetCurrentProcessNative = Pointer<Void> Function();
typedef _GetCurrentProcessDart = Pointer<Void> Function();
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);
typedef _MoveFileExNative =
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _MoveFileExDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
