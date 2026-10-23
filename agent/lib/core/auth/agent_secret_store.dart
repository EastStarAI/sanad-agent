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
import 'secret_vault_policy.dart';

export 'agent_secret_store_contract.dart';
export 'linux_auto_secret_store.dart';
export 'linux_secret_service.dart';
export 'secret_vault_policy.dart';

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
    reasonCode: AgentSecretStoreUnavailableReason.noStore,
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

  static const _service = agentVaultKeychainService;
  static const _itemNotFound = -25300;

  /// Security-framework statuses that mean "the item exists, but reading it
  /// needs an interactive authorization prompt" (`errSecInteractionNotAllowed`,
  /// `errSecInteractionRequired`), or that the prompt was answered by the wrong
  /// person (`errSecAuthFailed`, `errSecUserCanceled`).
  static const _interactionNotAllowed = -25308;
  static const _interactionRequired = -25315;
  static const _authFailed = -25293;
  static const _userCanceled = -128;

  /// Whether this process can build the never-prompt authentication context.
  ///
  /// The store calls the same builder when it suppresses interaction, so a macOS
  /// test pins the Objective-C FFI path here instead of against the real
  /// Keychain.
  static bool buildsNeverPromptAuthenticationContext() =>
      _NeverPromptAuthenticationContext.create() != null;

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
    _prepareInteraction();
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
    _prepareInteraction();
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
    _prepareInteraction();
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

  AgentSecretStoreUnavailable _failure(String operation, int status) =>
      classifyStatus(
        status,
        interactionAllowed: SecretVaultPolicy.interactionAllowed,
      ) ??
      AgentSecretStoreUnavailable(
        'macOS Keychain $operation failed ($status).',
        reasonCode: AgentSecretStoreUnavailableReason.backendError,
      );

  /// Maps a Security-framework status to a closed Agent vault, or `null` when
  /// the status is not about authorization.
  ///
  /// The mapping is a pure function of the status and the process interaction
  /// policy, so a test can pin every status this store must never mistake for
  /// success: `errSecInteractionNotAllowed` (`-25308`) and
  /// `errSecInteractionRequired` (`-25315`) mean "an interactive authorization
  /// was demanded", `errSecAuthFailed` (`-25293`) means the item's access
  /// control rejected this binary, and `errSecUserCanceled` (`-128`) means
  /// somebody dismissed the prompt. No message carries a secret value.
  static AgentSecretStoreUnavailable? classifyStatus(
    int status, {
    required bool interactionAllowed,
  }) {
    if (status == _userCanceled) {
      return const AgentSecretStoreUnavailable(
        'The macOS Keychain authorization was dismissed before it was approved, '
        'so the Agent vault stays closed. Run the command again from a terminal '
        'and approve the prompt.',
        reasonCode: AgentSecretStoreUnavailableReason.authorizationCanceled,
      );
    }
    if (status == _authFailed) {
      return const AgentSecretStoreUnavailable(
        'macOS Keychain rejected the authorization for the Agent vault item '
        '(errSecAuthFailed): its access control does not accept the binary this '
        'runtime runs as. Add that binary in Keychain Access > Access Control, '
        'or run the Agent build that created the item.',
        reasonCode: AgentSecretStoreUnavailableReason.authorizationDenied,
      );
    }
    if (status != _interactionNotAllowed && status != _interactionRequired) {
      return null;
    }
    if (!interactionAllowed) {
      return const AgentSecretStoreUnavailable(
        'The Agent vault item demands an interactive macOS Keychain '
        'authorization, and this process has no human to answer it '
        '(errSecInteractionNotAllowed), so the vault stays closed. Run the '
        'command interactively, or approve the binary in Keychain Access > '
        'Access Control.',
        reasonCode: AgentSecretStoreUnavailableReason.interactionForbidden,
      );
    }
    return const AgentSecretStoreUnavailable(
      'macOS asked for an interactive Keychain authorization that this process '
      'could not present (errSecInteractionRequired), so the Agent vault stays '
      'closed. Unlock the session, or approve the binary in Keychain Access > '
      'Access Control.',
      reasonCode: AgentSecretStoreUnavailableReason.interactionRequired,
    );
  }

  /// Whether this process already applied its Keychain interaction policy.
  bool _interactionPrepared = false;

  /// Whether the pending-authorization notice was already printed.
  bool _announcedPendingAuthorization = false;

  /// The never-prompt authentication context, once one was needed.
  _NeverPromptAuthenticationContext? _context;

  /// Applies this process's Keychain interaction policy before a query.
  ///
  /// A daemon or an interactive command keeps the normal behaviour, so the one
  /// authorization dialog macOS would show can appear and be approved. Only a
  /// process that detected nobody present suppresses the dialog, because there
  /// is no window to show it in: under automation the read otherwise blocks
  /// inside the security framework while the caller waits for output that never
  /// comes.
  void _prepareInteraction() {
    if (SecretVaultPolicy.interactionAllowed) {
      _announcePendingAuthorization();
      return;
    }
    if (_interactionPrepared) return;
    _interactionPrepared = true;
    _context = _NeverPromptAuthenticationContext.create();
    try {
      // The legacy file-based keychain honours only this process-wide switch;
      // `kSecUseAuthenticationContext` is ignored for its items. It is safe
      // here precisely because this process already established that no human
      // can answer a prompt for anything it does.
      _setUserInteractionAllowed(0);
    } catch (_) {
      // A macOS that no longer exports the legacy switch still suppresses the
      // data-protection path through the per-query context below.
    }
  }

  /// Prints the one stderr line that explains a pending authorization dialog.
  ///
  /// It is written before the first Keychain query of an interactive process so
  /// a person knows why the command stopped, and it never contains a secret.
  void _announcePendingAuthorization() {
    if (_announcedPendingAuthorization) return;
    _announcedPendingAuthorization = true;
    try {
      stderr.writeln(keychainApprovalWaitNotice(_service));
    } on Object {
      // A detached or closed stderr must not fail the Keychain query; trust the
      // authorization dialog itself to explain the wait.
    }
  }

  /// Per-query suppression for items that honour an authentication context.
  ///
  /// `kSecUseAuthenticationContext` with an `LAContext` whose
  /// `interactionNotAllowed` is set is the supported replacement for the
  /// deprecated `kSecUseAuthenticationUI`/`kSecUseAuthenticationUIFail` pair.
  /// macOS applies it to data-protection keychain items; the legacy file
  /// keychain keeps using [_prepareInteraction]'s process-wide switch.
  Map<Pointer<Void>, Pointer<Void>> get _nonInteractiveAttributes {
    if (SecretVaultPolicy.interactionAllowed) return const {};
    final key = _kSecUseAuthenticationContext;
    final context = _context?.handle;
    if (key == null || context == null) return const {};
    return {key: context};
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
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('SecItemDelete');

  /// `SecKeychainSetUserInteractionAllowed`, or a throwing lookup on a system
  /// that no longer exports the legacy switch.
  late final _setUserInteractionAllowed = _security
      .lookupFunction<Int32 Function(Uint8), int Function(int)>(
        'SecKeychainSetUserInteractionAllowed',
      );

  late final Pointer<Void>? _kSecUseAuthenticationContext = _optionalConstant(
    'kSecUseAuthenticationContext',
  );
}

/// An `LAContext` whose `interactionNotAllowed` is set, so a Keychain query
/// that carries it can never raise an authorization dialog.
///
/// LocalAuthentication exposes no C entry point, so the class is reached through
/// the Objective-C runtime. Any failure returns `null`: the caller then keeps the
/// legacy process-wide switch, which still covers file-based keychain items.
final class _NeverPromptAuthenticationContext {
  _NeverPromptAuthenticationContext._(this.handle);

  static const _frameworkPath =
      '/System/Library/Frameworks/LocalAuthentication.framework/'
      'LocalAuthentication';

  /// The loaded framework; loading it is what registers `LAContext`.
  static DynamicLibrary? _framework;

  /// The retained `LAContext` instance.
  final Pointer<Void> handle;

  /// Builds one context for the process, or `null` when the framework is not
  /// reachable through the Objective-C runtime.
  ///
  /// The set value is read back through the property getter, so a wrong ABI for
  /// `objc_msgSend` fails here instead of leaving a context that still prompts.
  static _NeverPromptAuthenticationContext? create() {
    try {
      final runtime = DynamicLibrary.process();
      final getClass = runtime
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('objc_getClass');
      final selector = runtime
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('sel_registerName');
      final sendMessage = runtime
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
          >('objc_msgSend');
      final sendMessageBool = runtime
          .lookupFunction<
            Void Function(Pointer<Void>, Pointer<Void>, Bool),
            void Function(Pointer<Void>, Pointer<Void>, bool)
          >('objc_msgSend');
      final readBool = runtime
          .lookupFunction<
            Bool Function(Pointer<Void>, Pointer<Void>),
            bool Function(Pointer<Void>, Pointer<Void>)
          >('objc_msgSend');

      _framework ??= DynamicLibrary.open(_frameworkPath);
      final className = 'LAContext'.toNativeUtf8();
      final allocName = 'alloc'.toNativeUtf8();
      final initName = 'init'.toNativeUtf8();
      final interactionName = 'setInteractionNotAllowed:'.toNativeUtf8();
      final interactionGetter = 'interactionNotAllowed'.toNativeUtf8();
      final releaseName = 'release'.toNativeUtf8();
      try {
        final laContextClass = getClass(className);
        if (laContextClass == nullptr) return null;
        final allocated = sendMessage(laContextClass, selector(allocName));
        if (allocated == nullptr) return null;
        final instance = sendMessage(allocated, selector(initName));
        if (instance == nullptr) return null;
        sendMessageBool(instance, selector(interactionName), true);
        if (!readBool(instance, selector(interactionGetter))) {
          sendMessage(instance, selector(releaseName));
          return null;
        }
        return _NeverPromptAuthenticationContext._(instance);
      } finally {
        calloc.free(className);
        calloc.free(allocName);
        calloc.free(initName);
        calloc.free(interactionName);
        calloc.free(interactionGetter);
        calloc.free(releaseName);
      }
    } on Object {
      return null;
    }
  }
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
