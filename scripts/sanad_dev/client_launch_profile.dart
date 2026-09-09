import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'runtime_context.dart';

const String canonicalPrimaryGatewayUrl = 'http://127.0.0.1:$canonicalPrimaryAgentPort';

class ClientLaunchProfile {
  const ClientLaunchProfile({
    required this.compileArguments,
    required this.defines,
    this.target,
    this.deviceId,
  });

  final List<String> compileArguments;
  final Map<String, String> defines;
  final String? target;
  final String? deviceId;

  String? define(String name) => defines[name];
  bool hasDefine(String name) => defines.containsKey(name);
}

ClientLaunchProfile withImplicitPrimaryClientDefaults(
  ClientLaunchProfile profile, {
  required bool allowed,
  required String primarySanadHome,
}) {
  if (!allowed) return profile;
  final defines = <String, String>{...profile.defines};
  defines.putIfAbsent('LOCAL_GATEWAY_URL', () => canonicalPrimaryGatewayUrl);
  defines.putIfAbsent('SANAD_HOME', () => primarySanadHome);
  defines.putIfAbsent('SANAD_SHARED_PREFERENCES_PREFIX', () => '');
  return ClientLaunchProfile(
    compileArguments: profile.compileArguments,
    defines: Map.unmodifiable(defines),
    target: profile.target,
    deviceId: profile.deviceId,
  );
}

ClientLaunchProfile extractClientLaunchProfile(List<String> arguments) {
  final compileArguments = <String>[];
  final defines = <String, String>{};
  String? target;
  String? deviceId;

  for (var index = 0; index < arguments.length; index++) {
    final token = arguments[index];
    String? value;
    if (token == '--dart-define' && index + 1 < arguments.length) {
      value = arguments[++index];
      compileArguments.add('--dart-define=$value');
      _recordDefine(defines, value);
      continue;
    }
    if (token.startsWith('--dart-define=')) {
      value = token.substring('--dart-define='.length);
      compileArguments.add('--dart-define=$value');
      _recordDefine(defines, value);
      continue;
    }
    if (token == '--dart-define-from-file' && index + 1 < arguments.length) {
      value = arguments[++index];
      compileArguments.add('--dart-define-from-file=$value');
      continue;
    }
    if (token.startsWith('--dart-define-from-file=')) {
      value = token.substring('--dart-define-from-file='.length);
      compileArguments.add('--dart-define-from-file=$value');
      continue;
    }
    if ((token == '--target' || token == '-t') && index + 1 < arguments.length) {
      target = arguments[++index];
      continue;
    }
    if (token.startsWith('--target=')) {
      target = token.substring('--target='.length);
      continue;
    }
    if ((token == '--device-id' || token == '-d') && index + 1 < arguments.length) {
      deviceId = arguments[++index];
      continue;
    }
    if (token.startsWith('--device-id=')) {
      deviceId = token.substring('--device-id='.length);
    }
  }

  return ClientLaunchProfile(
    compileArguments: List.unmodifiable(compileArguments),
    defines: Map.unmodifiable(defines),
    target: target,
    deviceId: deviceId,
  );
}

String? validateClientLaunchProfile(
  ClientLaunchProfile profile, {
  required bool isLinkedWorktree,
  required String expectedWorktreeName,
  required String expectedBranch,
  String? expectedWorkspaceHash,
  bool workspaceHashRequired = false,
  required int expectedAgentPort,
  required String emptyPreferencesSanadHome,
  required String Function(String sanadHome) derivePreferencesPrefix,
  String Function(String path)? canonicalizePath,
}) {
  if (profile.compileArguments.isEmpty) {
    return 'the running client has no discoverable Flutter launch profile';
  }
  final gatewayRaw = profile.define('LOCAL_GATEWAY_URL');
  final gateway = gatewayRaw == null ? null : Uri.tryParse(gatewayRaw);
  if (gateway == null || gateway.host.isEmpty || !gateway.hasPort) {
    return 'LOCAL_GATEWAY_URL is missing or invalid';
  }
  if (gateway.port != expectedAgentPort) {
    return 'LOCAL_GATEWAY_URL targets port ${gateway.port}, but this worktree agent uses port $expectedAgentPort';
  }
  final sanadHome = profile.define('SANAD_HOME');
  if (sanadHome == null || sanadHome.trim().isEmpty) {
    return 'SANAD_HOME is missing';
  }
  final canonicalize = canonicalizePath ?? _canonicalClientPath;
  final preferencesPrefix = profile.define('SANAD_SHARED_PREFERENCES_PREFIX');
  if (preferencesPrefix == null) {
    return 'SANAD_SHARED_PREFERENCES_PREFIX is missing';
  }
  final expectedPreferencesPrefix = canonicalize(sanadHome) == canonicalize(emptyPreferencesSanadHome)
      ? ''
      : derivePreferencesPrefix(sanadHome);
  if (preferencesPrefix != expectedPreferencesPrefix) {
    return 'SANAD_SHARED_PREFERENCES_PREFIX does not match SANAD_HOME';
  }
  final workspaceHash = profile.define('SANAD_DEV_WORKSPACE_HASH');
  if (workspaceHashRequired && (workspaceHash == null || workspaceHash.isEmpty)) {
    return 'SANAD_DEV_WORKSPACE_HASH is missing';
  }
  if (expectedWorkspaceHash != null && workspaceHash != null && workspaceHash != expectedWorkspaceHash) {
    return 'SANAD_DEV_WORKSPACE_HASH does not match the current workspace';
  }
  if (isLinkedWorktree) {
    if (profile.define('SANAD_DEV_WORKTREE_NAME') != expectedWorktreeName) {
      return 'SANAD_DEV_WORKTREE_NAME does not match the current worktree';
    }
    if (profile.define('SANAD_DEV_WORKTREE_BRANCH') != expectedBranch) {
      return 'SANAD_DEV_WORKTREE_BRANCH does not match the current branch';
    }
  }
  return null;
}

String resolveClientDirectoryForLaunchProfile({
  required ClientLaunchProfile profile,
  required String runtimeRepositoryRoot,
  required bool runtimeIsLinkedWorktree,
  required String runtimeWorktreeName,
  required String separator,
}) {
  final normalizedRoot = runtimeRepositoryRoot.replaceAll('\\', separator).replaceAll('/', separator);
  final worktreeMarker = '${separator}.agent${separator}worktrees${separator}';
  final markerIndex = normalizedRoot.indexOf(worktreeMarker);
  final primaryRepositoryRoot = markerIndex >= 0 ? normalizedRoot.substring(0, markerIndex) : normalizedRoot;

  if (profile.target != null) {
    final targetPath = profile.target!;
    final isAbsolute = targetPath.startsWith('/') ||
        targetPath.startsWith('\\') ||
        (targetPath.length > 2 && targetPath[1] == ':' && (targetPath[2] == '/' || targetPath[2] == '\\'));
    if (isAbsolute) {
      final canonicalTarget = _canonicalClientPath(targetPath);
      final canonicalRoot = _canonicalClientPath(primaryRepositoryRoot);
      final targetLower = canonicalTarget.toLowerCase().replaceAll('\\', '/');
      final rootLower = canonicalRoot.toLowerCase().replaceAll('\\', '/');
      final rootPrefix = rootLower.endsWith('/') ? rootLower : '$rootLower/';
      if (targetLower != rootLower && !targetLower.startsWith(rootPrefix)) {
        return '';
      }
    }
  }

  final profileWorktreeName = profile.define('SANAD_DEV_WORKTREE_NAME');
  if (profileWorktreeName == null || profileWorktreeName.isEmpty) {
    if (runtimeIsLinkedWorktree && markerIndex < 0) return '';
    return '$primaryRepositoryRoot${separator}client';
  }
  if (profileWorktreeName.contains('/') ||
      profileWorktreeName.contains('\\') ||
      profileWorktreeName == '.' ||
      profileWorktreeName == '..') {
    return '';
  }
  if (runtimeIsLinkedWorktree && profileWorktreeName == runtimeWorktreeName) {
    return '$normalizedRoot${separator}client';
  }
  return '$primaryRepositoryRoot${separator}.agent${separator}worktrees'
      '$separator$profileWorktreeName${separator}sanad-agent'
      '${separator}client';
}

List<String> buildClientAttachArguments({
  required ClientLaunchProfile profile,
  required String vmUrl,
  required String? deviceId,
}) {
  return [
    'attach',
    if (deviceId != null && deviceId.isNotEmpty) ...['-d', deviceId],
    '--debug-url=$vmUrl',
    ...profile.compileArguments,
    if (profile.target != null && profile.target!.isNotEmpty) ...[
      '-t',
      profile.target!,
    ],
  ];
}

void _recordDefine(Map<String, String> defines, String value) {
  final separator = value.indexOf('=');
  if (separator <= 0) return;
  defines[value.substring(0, separator)] = value.substring(separator + 1);
}

String _canonicalClientPath(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return Directory(path).absolute.path;
  }
}

List<String> splitNullTerminatedArguments(List<int> bytes) {
  final arguments = <String>[];
  var start = 0;
  for (var index = 0; index <= bytes.length; index++) {
    if (index != bytes.length && bytes[index] != 0) continue;
    if (index > start) {
      arguments.add(utf8.decode(bytes.sublist(start, index)));
    }
    start = index + 1;
  }
  return arguments;
}

List<String> parseMacOsProcessArguments(List<int> bytes) {
  if (bytes.length < 4) return const [];
  final argc = ByteData.sublistView(
    Uint8List.fromList(bytes),
  ).getInt32(0, Endian.host);
  if (argc <= 0) return const [];
  var cursor = 4;
  while (cursor < bytes.length && bytes[cursor] != 0) {
    cursor++;
  }
  while (cursor < bytes.length && bytes[cursor] == 0) {
    cursor++;
  }
  final arguments = <String>[];
  while (cursor < bytes.length && arguments.length < argc) {
    final end = bytes.indexOf(0, cursor);
    if (end < 0) return const [];
    arguments.add(utf8.decode(bytes.sublist(cursor, end)));
    cursor = end + 1;
  }
  return arguments.length == argc ? arguments : const [];
}

Future<Map<int, List<String>>> readMacOsCandidateArguments(
  Iterable<int> processIds,
  Future<List<String>> Function(int processId) readArguments,
) async {
  final argumentsByProcess = <int, List<String>>{};
  for (final processId in processIds) {
    final arguments = await readArguments(processId);
    if (arguments.isNotEmpty) {
      argumentsByProcess[processId] = arguments;
    }
  }
  return argumentsByProcess;
}

List<String> readMacOsProcessArguments(
  int processId, {
  DynamicLibrary? processLibrary,
}) {
  if (!Platform.isMacOS) return const [];
  final library = processLibrary ?? DynamicLibrary.process();
  final sysctl = library.lookupFunction<_SysctlNative, _SysctlDart>('sysctl');
  final malloc = library.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = library.lookupFunction<_FreeNative, _FreeDart>('free');
  final mib = malloc(3 * sizeOf<Int32>()).cast<Int32>();
  final sizePointer = malloc(sizeOf<IntPtr>()).cast<IntPtr>();
  Pointer<Void>? buffer;
  try {
    mib[0] = 1; // CTL_KERN
    mib[1] = 49; // KERN_PROCARGS2
    mib[2] = processId;
    sizePointer.value = 0;
    if (sysctl(mib, 3, nullptr, sizePointer, nullptr, 0) != 0 || sizePointer.value <= 0) {
      return const [];
    }
    buffer = malloc(sizePointer.value);
    if (buffer == nullptr) return const [];
    if (sysctl(mib, 3, buffer, sizePointer, nullptr, 0) != 0) {
      return const [];
    }
    return parseMacOsProcessArguments(
      buffer.cast<Uint8>().asTypedList(sizePointer.value),
    );
  } finally {
    if (buffer != null && buffer != nullptr) free(buffer);
    free(sizePointer.cast());
    free(mib.cast());
  }
}

typedef _SysctlNative =
    Int32 Function(
      Pointer<Int32>,
      Uint32,
      Pointer<Void>,
      Pointer<IntPtr>,
      Pointer<Void>,
      IntPtr,
    );
typedef _SysctlDart =
    int Function(
      Pointer<Int32>,
      int,
      Pointer<Void>,
      Pointer<IntPtr>,
      Pointer<Void>,
      int,
    );
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
