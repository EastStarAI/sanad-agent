import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../constants.dart';
import '../sanad_home/sanad_home_bootstrap.dart';
import '../sanad_home/test_runtime_isolation.dart';
import 'agent_secret_store_contract.dart';
import 'linux_auto_secret_store.dart';

export 'agent_secret_store_contract.dart';
export 'linux_auto_secret_store.dart';
export 'linux_secret_service.dart';

/// Whether this process must keep secrets out of the OS credential vault.
///
/// Deterministic E2E processes (`SANAD_E2E_TEST_MODE=true`, the switch the
/// subprocess and daemon E2E suites already set) and the Dart test runtime use
/// the owner-only file store inside the selected Home, so no test reads or
/// writes the real Keychain, DPAPI or Secret Service.
bool usesTestAgentSecretStore() => isDartTestRuntime() || isSanadE2eTestMode();

AgentSecretStore createAgentSecretStore() {
  if (usesTestAgentSecretStore()) {
    requireSanadE2eTestIsolation();
    rejectUnisolatedTestHomeAccess(
      'open the Agent secret store',
      path: getSanadHome(),
    );
    return LinuxOwnerFileAgentSecretStore();
  }
  final scope = sha256
      .convert(utf8.encode(SanadHomeBootstrap.identity().canonicalRoot()))
      .toString();
  if (Platform.isMacOS) return MacOsKeychainAgentSecretStore(scope: scope);
  if (Platform.isLinux) return LinuxAutoAgentSecretStore(scope: scope);
  if (Platform.isWindows) return WindowsDpapiAgentSecretStore(scope: scope);
  throw const AgentSecretStoreUnavailable(
    'This operating system has no supported Sanad credential vault.',
  );
}

class MacOsKeychainAgentSecretStore implements AgentSecretStore {
  MacOsKeychainAgentSecretStore({
    required this.scope,
    DynamicLibrary? securityLibrary,
    DynamicLibrary? coreFoundationLibrary,
  }) : _security =
           securityLibrary ??
           DynamicLibrary.open(
             '/System/Library/Frameworks/Security.framework/Security',
           ),
       _cf =
           coreFoundationLibrary ??
           DynamicLibrary.open(
             '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
           );

  static const _service = 'ai.eaststar.sanad.agent';
  static const _itemNotFound = -25300;

  /// Security-framework statuses that mean "the item exists, but reading it
  /// needs an interactive authorization prompt".
  static const _interactionNotAllowed = -25308;
  static const _interactionRequired = -25315;
  static const _authFailed = -25293;
  static const _userCanceled = -128;

  final String scope;
  final DynamicLibrary _security;
  final DynamicLibrary _cf;

  String _account(String key) => '$scope:$key';

  Pointer<Void> _createString(String str) {
    final native = str.toNativeUtf8();
    try {
      return _cfStringCreate(nullptr, native, 0x08000100);
    } finally {
      calloc.free(native);
    }
  }

  Pointer<Void> _createData(Uint8List bytes) {
    final ptr = calloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    try {
      return _cfDataCreate(nullptr, ptr, bytes.length);
    } finally {
      ptr.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(ptr);
    }
  }

  Pointer<Void> _createDictionary(Map<Pointer<Void>, Pointer<Void>> entries) {
    final count = entries.length;
    final keys = calloc<Pointer<Void>>(count);
    final values = calloc<Pointer<Void>>(count);
    var i = 0;
    for (final entry in entries.entries) {
      keys[i] = entry.key;
      values[i] = entry.value;
      i++;
    }
    try {
      return _cfDictionaryCreate(
        nullptr,
        keys,
        values,
        count,
        _kCFTypeDictionaryKeyCallBacks,
        _kCFTypeDictionaryValueCallBacks,
      );
    } finally {
      calloc.free(keys);
      calloc.free(values);
    }
  }

  @override
  Future<String?> read(String key) async {
    _forbidUserInteraction();
    final cfService = _createString(_service);
    final cfAccount = _createString(_account(key));
    final query = _createDictionary({
      _kSecClass: _kSecClassGenericPassword,
      _kSecAttrService: cfService,
      _kSecAttrAccount: cfAccount,
      _kSecReturnData: _kCFBooleanTrue,
      _kSecMatchLimit: _kSecMatchLimitOne,
      ..._nonInteractiveAttributes,
    });
    final result = calloc<Pointer<Void>>();
    try {
      final status = _secItemCopyMatching(query, result);
      if (status == _itemNotFound) return null;
      if (status != 0) throw _failure('read', status);
      final dataRef = result.value;
      if (dataRef == nullptr) return null;
      try {
        final length = _cfDataGetLength(dataRef);
        final bytes = _cfDataGetBytePtr(dataRef);
        return utf8.decode(bytes.asTypedList(length));
      } finally {
        _cfRelease(dataRef);
      }
    } finally {
      calloc.free(result);
      _cfRelease(query);
      _cfRelease(cfAccount);
      _cfRelease(cfService);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    _forbidUserInteraction();
    final cfService = _createString(_service);
    final cfAccount = _createString(_account(key));
    final secretBytes = Uint8List.fromList(utf8.encode(value));
    final cfData = _createData(secretBytes);
    final query = _createDictionary({
      _kSecClass: _kSecClassGenericPassword,
      _kSecAttrService: cfService,
      _kSecAttrAccount: cfAccount,
      ..._nonInteractiveAttributes,
    });
    try {
      final updateAttrs = _createDictionary({_kSecValueData: cfData});
      try {
        final updateStatus = _secItemUpdate(query, updateAttrs);
        if (updateStatus == 0) return;
        if (updateStatus != _itemNotFound) {
          throw _failure('write (update)', updateStatus);
        }
      } finally {
        _cfRelease(updateAttrs);
      }

      final addDict = _createDictionary({
        _kSecClass: _kSecClassGenericPassword,
        _kSecAttrService: cfService,
        _kSecAttrAccount: cfAccount,
        _kSecValueData: cfData,
        _kSecAttrAccessible: _kSecAttrAccessibleAfterFirstUnlock,
      });
      try {
        final addStatus = _secItemAdd(addDict, nullptr);
        if (addStatus != 0) throw _failure('write (add)', addStatus);
      } finally {
        _cfRelease(addDict);
      }
    } finally {
      _cfRelease(query);
      _cfRelease(cfData);
      _cfRelease(cfAccount);
      _cfRelease(cfService);
    }
  }

  @override
  Future<void> delete(String key) async {
    _forbidUserInteraction();
    final cfService = _createString(_service);
    final cfAccount = _createString(_account(key));
    final query = _createDictionary({
      _kSecClass: _kSecClassGenericPassword,
      _kSecAttrService: cfService,
      _kSecAttrAccount: cfAccount,
      ..._nonInteractiveAttributes,
    });
    try {
      final status = _secItemDelete(query);
      if (status == _itemNotFound) return;
      if (status != 0) throw _failure('delete', status);
    } finally {
      _cfRelease(query);
      _cfRelease(cfAccount);
      _cfRelease(cfService);
    }
  }

  AgentSecretStoreUnavailable _failure(String operation, int status) {
    if (status == _interactionNotAllowed ||
        status == _interactionRequired ||
        status == _authFailed ||
        status == _userCanceled) {
      return const AgentSecretStoreUnavailable(
        'The macOS Keychain wants an interactive authorization for the Agent '
        'vault, and a Sanad runtime never prompts. Authorize the running Agent '
        'binary for the vault item in Keychain Access > Access Control, or use '
        'the Agent build that created it.',
      );
    }
    return AgentSecretStoreUnavailable(
      'macOS Keychain $operation failed ($status).',
    );
  }

  /// Whether this process already forbade Keychain user interaction.
  bool _interactionForbidden = false;

  /// Forbids every interactive authorization path for this process, once.
  ///
  /// macOS answers a read of a generic-password item that was created by a
  /// *different* code identity with an authorization prompt (`SecurityAgent`)
  /// and blocks the calling thread until somebody answers it. A Sanad runtime
  /// never has somebody to answer — the CLI runs under a Client, a scheduler,
  /// or a terminal that owns no Security prompt — so the read blocked inside
  /// the security framework: no output, no socket, no exit. Forbidding
  /// interaction turns that prompt into `errSecInteractionNotAllowed`, which
  /// [read] reports as a closed vault instead of a hung process.
  void _forbidUserInteraction() {
    if (_interactionForbidden) return;
    _interactionForbidden = true;
    try {
      _setUserInteractionAllowed(0);
    } catch (_) {
      // A future macOS that drops the legacy switch is still covered by the
      // per-query attribute below.
    }
  }

  /// Per-query suppression for items that honour `kSecUseAuthenticationUI`
  /// (the data-protection keychain), where the legacy switch has no effect.
  Map<Pointer<Void>, Pointer<Void>> get _nonInteractiveAttributes {
    final ui = _kSecUseAuthenticationUI;
    final fail = _kSecUseAuthenticationUIFail;
    if (ui == null || fail == null) return const {};
    return {ui: fail};
  }

  Pointer<Void>? _optionalConstant(String name) {
    try {
      return _security.lookup<Pointer<Void>>(name).value;
    } catch (_) {
      return null;
    }
  }

  late final _kSecClass = _security.lookup<Pointer<Void>>('kSecClass').value;
  late final _kSecClassGenericPassword = _security
      .lookup<Pointer<Void>>('kSecClassGenericPassword')
      .value;
  late final _kSecAttrService = _security
      .lookup<Pointer<Void>>('kSecAttrService')
      .value;
  late final _kSecAttrAccount = _security
      .lookup<Pointer<Void>>('kSecAttrAccount')
      .value;
  late final _kSecValueData = _security
      .lookup<Pointer<Void>>('kSecValueData')
      .value;
  late final _kSecReturnData = _security
      .lookup<Pointer<Void>>('kSecReturnData')
      .value;
  late final _kSecMatchLimit = _security
      .lookup<Pointer<Void>>('kSecMatchLimit')
      .value;
  late final _kSecMatchLimitOne = _security
      .lookup<Pointer<Void>>('kSecMatchLimitOne')
      .value;
  late final _kSecAttrAccessible = _security
      .lookup<Pointer<Void>>('kSecAttrAccessible')
      .value;
  late final _kSecAttrAccessibleAfterFirstUnlock = _security
      .lookup<Pointer<Void>>('kSecAttrAccessibleAfterFirstUnlock')
      .value;

  late final _kCFBooleanTrue = _cf
      .lookup<Pointer<Void>>('kCFBooleanTrue')
      .value;
  late final _kCFTypeDictionaryKeyCallBacks = _cf.lookup<Void>(
    'kCFTypeDictionaryKeyCallBacks',
  );
  late final _kCFTypeDictionaryValueCallBacks = _cf.lookup<Void>(
    'kCFTypeDictionaryValueCallBacks',
  );

  late final _cfRelease = _cf
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
  late final _cfStringCreate = _cf
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
      >('CFStringCreateWithCString');
  late final _cfDataCreate = _cf
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, IntPtr),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int)
      >('CFDataCreate');
  late final _cfDataGetBytePtr = _cf
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)
      >('CFDataGetBytePtr');
  late final _cfDataGetLength = _cf
      .lookupFunction<
        IntPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CFDataGetLength');
  late final _cfDictionaryCreate = _cf
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          IntPtr,
          Pointer<Void>,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          int,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('CFDictionaryCreate');

  late final _secItemAdd = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      >('SecItemAdd');
  late final _secItemCopyMatching = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      >('SecItemCopyMatching');
  late final _secItemUpdate = _security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('SecItemUpdate');
  late final _secItemDelete = _security
      .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'SecItemDelete',
      );

  /// `SecKeychainSetUserInteractionAllowed`, or a throwing lookup on a system
  /// that no longer exports the legacy switch.
  late final _setUserInteractionAllowed = _security
      .lookupFunction<Int32 Function(Uint8), int Function(int)>(
        'SecKeychainSetUserInteractionAllowed',
      );

  late final Pointer<Void>? _kSecUseAuthenticationUI = _optionalConstant(
    'kSecUseAuthenticationUI',
  );
  late final Pointer<Void>? _kSecUseAuthenticationUIFail = _optionalConstant(
    'kSecUseAuthenticationUIFail',
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
