import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../sanad_home/sanad_home_bootstrap.dart';

abstract interface class AgentSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class AgentSecretStoreUnavailable implements Exception {
  const AgentSecretStoreUnavailable(this.message);

  final String message;

  @override
  String toString() => 'AgentSecretStoreUnavailable: $message';
}

AgentSecretStore createAgentSecretStore() {
  final scope = sha256
      .convert(utf8.encode(SanadHomeBootstrap.identity().canonicalRoot()))
      .toString();
  if (Platform.isMacOS) return MacOsKeychainAgentSecretStore(scope: scope);
  if (Platform.isLinux) return LinuxSecretServiceAgentSecretStore(scope: scope);
  if (Platform.isWindows) return WindowsDpapiAgentSecretStore(scope: scope);
  throw const AgentSecretStoreUnavailable(
    'This operating system has no supported Sanad credential vault.',
  );
}

class MacOsKeychainAgentSecretStore implements AgentSecretStore {
  MacOsKeychainAgentSecretStore({required this.scope, DynamicLibrary? library})
    : _security =
          library ??
          DynamicLibrary.open(
            '/System/Library/Frameworks/Security.framework/Security',
          );

  static const _service = 'ai.eaststar.sanad.agent';
  static const _itemNotFound = -25300;

  final String scope;
  final DynamicLibrary _security;

  String _account(String key) => '$scope:$key';

  @override
  Future<String?> read(String key) async {
    final service = _service.toNativeUtf8();
    final account = _account(key).toNativeUtf8();
    final length = calloc<Uint32>();
    final data = calloc<Pointer<Void>>();
    try {
      final status = _find(
        nullptr,
        service.length,
        service.cast(),
        account.length,
        account.cast(),
        length,
        data,
        nullptr,
      );
      if (status == _itemNotFound) return null;
      if (status != 0) throw _failure('read', status);
      return utf8.decode(data.value.cast<Uint8>().asTypedList(length.value));
    } finally {
      if (data.value != nullptr) _freeContent(nullptr, data.value);
      calloc.free(data);
      calloc.free(length);
      calloc.free(account);
      calloc.free(service);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final service = _service.toNativeUtf8();
    final account = _account(key).toNativeUtf8();
    final secret = Uint8List.fromList(utf8.encode(value));
    final secretPointer = calloc<Uint8>(secret.length)
      ..asTypedList(secret.length).setAll(0, secret);
    final item = calloc<Pointer<Void>>();
    try {
      final findStatus = _find(
        nullptr,
        service.length,
        service.cast(),
        account.length,
        account.cast(),
        nullptr,
        nullptr,
        item,
      );
      final status = findStatus == _itemNotFound
          ? _add(
              nullptr,
              service.length,
              service.cast(),
              account.length,
              account.cast(),
              secret.length,
              secretPointer.cast(),
              nullptr,
            )
          : findStatus == 0
          ? _modify(item.value, nullptr, secret.length, secretPointer.cast())
          : findStatus;
      if (status != 0) throw _failure('write', status);
    } finally {
      if (item.value != nullptr) _cfRelease(item.value);
      secretPointer.asTypedList(secret.length).fillRange(0, secret.length, 0);
      calloc.free(item);
      calloc.free(secretPointer);
      calloc.free(account);
      calloc.free(service);
    }
  }

  @override
  Future<void> delete(String key) async {
    final service = _service.toNativeUtf8();
    final account = _account(key).toNativeUtf8();
    final item = calloc<Pointer<Void>>();
    try {
      final findStatus = _find(
        nullptr,
        service.length,
        service.cast(),
        account.length,
        account.cast(),
        nullptr,
        nullptr,
        item,
      );
      if (findStatus == _itemNotFound) return;
      if (findStatus != 0) throw _failure('delete', findStatus);
      final status = _deleteItem(item.value);
      if (status != 0) throw _failure('delete', status);
    } finally {
      if (item.value != nullptr) _cfRelease(item.value);
      calloc.free(item);
      calloc.free(account);
      calloc.free(service);
    }
  }

  AgentSecretStoreUnavailable _failure(String operation, int status) =>
      AgentSecretStoreUnavailable(
        'macOS Keychain $operation failed ($status).',
      );

  late final _find = _security
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<Void>,
          int,
          Pointer<Void>,
          Pointer<Uint32>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        )
      >('SecKeychainFindGenericPassword');
  late final _add = _security
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<Void>,
          int,
          Pointer<Void>,
          int,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        )
      >('SecKeychainAddGenericPassword');
  late final _modify = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Void>)
      >('SecKeychainItemModifyAttributesAndData');
  late final _deleteItem = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('SecKeychainItemDelete');
  late final _freeContent = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('SecKeychainItemFreeContent');
  late final _cfRelease =
      DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      ).lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
}

typedef SecretToolRun = Future<ProcessResult> Function(List<String> arguments);
typedef SecretToolStart = Future<Process> Function(List<String> arguments);

class LinuxSecretServiceAgentSecretStore implements AgentSecretStore {
  LinuxSecretServiceAgentSecretStore({
    required this.scope,
    SecretToolRun? run,
    SecretToolStart? start,
  }) : _run = run ?? ((arguments) => Process.run('secret-tool', arguments)),
       _start =
           start ?? ((arguments) => Process.start('secret-tool', arguments));

  final String scope;
  final SecretToolRun _run;
  final SecretToolStart _start;

  @override
  Future<String?> read(String key) async {
    try {
      final result = await _run([
        'lookup',
        'application',
        'sanad-agent',
        'home',
        scope,
        'entry',
        key,
      ]);
      if (result.exitCode == 1) return null;
      if (result.exitCode != 0) throw _failure('read');
      return (result.stdout as String).replaceFirst(RegExp(r'\r?\n$'), '');
    } on ProcessException {
      throw _failure('read');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final process = await _start([
        'store',
        '--label=Sanad Agent credential',
        'application',
        'sanad-agent',
        'home',
        scope,
        'entry',
        key,
      ]);
      process.stdin.write(value);
      await process.stdin.close();
      if (await process.exitCode != 0) throw _failure('write');
    } on ProcessException {
      throw _failure('write');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      final result = await _run([
        'clear',
        'application',
        'sanad-agent',
        'home',
        scope,
        'entry',
        key,
      ]);
      if (result.exitCode != 0 && result.exitCode != 1) {
        throw _failure('delete');
      }
    } on ProcessException {
      throw _failure('delete');
    }
  }

  AgentSecretStoreUnavailable _failure(String operation) =>
      AgentSecretStoreUnavailable(
        'Linux Secret Service $operation failed or is unavailable. Install '
        '`secret-tool` and ensure a Secret Service session is available.',
      );
}

final class _DataBlob extends Struct {
  @Uint32()
  external int length;

  external Pointer<Uint8> data;
}

class WindowsDpapiAgentSecretStore implements AgentSecretStore {
  WindowsDpapiAgentSecretStore({required this.scope, DynamicLibrary? library})
    : _providedLibrary = library;

  static const _uiForbidden = 0x1;
  final String scope;
  final DynamicLibrary? _providedLibrary;
  late final DynamicLibrary _crypt32 =
      _providedLibrary ?? DynamicLibrary.open('crypt32.dll');

  String _fileName(String key) =>
      'agent_vault_${sha256.convert(utf8.encode('$scope:$key'))}.bin';

  @override
  Future<String?> read(String key) => _guard('read', () async {
    final boundary = SanadHomeBootstrap.identity();
    final fileName = _fileName(key);
    if (!boundary.fileExists(fileName)) return null;
    final encrypted = boundary.readSecretBytes(fileName);
    final input = _blob(encrypted);
    final output = calloc<_DataBlob>();
    try {
      final ok = _unprotect(
        input,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) throw _failure('read');
      return utf8.decode(output.ref.data.asTypedList(output.ref.length));
    } finally {
      _freeBlob(input);
      if (output.ref.data != nullptr) _localFree(output.ref.data.cast());
      calloc.free(output);
    }
  });

  @override
  Future<void> write(String key, String value) => _guard('write', () async {
    final plain = Uint8List.fromList(utf8.encode(value));
    final input = _blob(plain);
    final output = calloc<_DataBlob>();
    try {
      final ok = _protect(
        input,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) throw _failure('write');
      await SanadHomeBootstrap.identity().writeSecretBytes(
        _fileName(key),
        output.ref.data.asTypedList(output.ref.length),
      );
    } finally {
      input.ref.data
          .asTypedList(input.ref.length)
          .fillRange(0, input.ref.length, 0);
      _freeBlob(input);
      if (output.ref.data != nullptr) _localFree(output.ref.data.cast());
      calloc.free(output);
    }
  });

  @override
  Future<void> delete(String key) => _guard(
    'delete',
    () => SanadHomeBootstrap.identity().deleteFile(_fileName(key)),
  );

  Future<T> _guard<T>(String operation, Future<T> Function() action) async {
    try {
      return await action();
    } on AgentSecretStoreUnavailable {
      rethrow;
    } catch (_) {
      throw _failure(operation);
    }
  }

  Pointer<_DataBlob> _blob(List<int> bytes) {
    final blob = calloc<_DataBlob>();
    blob.ref.length = bytes.length;
    blob.ref.data = calloc<Uint8>(bytes.length);
    blob.ref.data.asTypedList(bytes.length).setAll(0, bytes);
    return blob;
  }

  void _freeBlob(Pointer<_DataBlob> blob) {
    calloc.free(blob.ref.data);
    calloc.free(blob);
  }

  AgentSecretStoreUnavailable _failure(String operation) =>
      AgentSecretStoreUnavailable('Windows DPAPI $operation failed.');

  late final _protect = _crypt32
      .lookupFunction<
        Int32 Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_DataBlob>,
        ),
        int Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_DataBlob>,
        )
      >('CryptProtectData');
  late final _unprotect = _crypt32
      .lookupFunction<
        Int32 Function(
          Pointer<_DataBlob>,
          Pointer<Pointer<Utf16>>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_DataBlob>,
        ),
        int Function(
          Pointer<_DataBlob>,
          Pointer<Pointer<Utf16>>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_DataBlob>,
        )
      >('CryptUnprotectData');
  late final _localFree = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
}
