import 'dart:io';

import '../constants.dart';
import 'service_manager.dart';
import 'service_metadata.dart';
import 'service_unit_builder.dart';

/// The fields of a background service definition that decide which Agent
/// runs, how, and for which Home and service instance.
class ServiceDefinition {
  const ServiceDefinition({
    required this.executable,
    required this.arguments,
    required this.sanadHome,
    required this.serviceInstance,
  });

  final String executable;
  final List<String> arguments;
  final String sanadHome;

  /// Empty for the default service.
  final String serviceInstance;

  ServiceDefinition copyWith({
    String? executable,
    List<String>? arguments,
    String? sanadHome,
    String? serviceInstance,
  }) => ServiceDefinition(
    executable: executable ?? this.executable,
    arguments: arguments ?? this.arguments,
    sanadHome: sanadHome ?? this.sanadHome,
    serviceInstance: serviceInstance ?? this.serviceInstance,
  );

  Map<String, Object> toJson() => {
    'executable': executable,
    'arguments': arguments,
    'sanad_home': sanadHome,
    'service_instance': serviceInstance,
  };

  @override
  bool operator ==(Object other) =>
      other is ServiceDefinition &&
      other.executable == executable &&
      other.sanadHome == sanadHome &&
      other.serviceInstance == serviceInstance &&
      other.arguments.length == arguments.length &&
      Iterable<int>.generate(
        arguments.length,
      ).every((index) => other.arguments[index] == arguments[index]);

  @override
  int get hashCode => Object.hash(
    executable,
    Object.hashAll(arguments),
    sanadHome,
    serviceInstance,
  );

  @override
  String toString() => 'ServiceDefinition(${toJson()})';
}

/// Read-only comparison of the installed user service definition with the
/// one this Agent would generate. It never writes, registers, or starts.
///
/// Only the launchd plist and the systemd unit are inspected; Windows
/// Clients refresh the Scheduled Task on every registration.
abstract final class ServiceDefinitionInspector {
  /// The definition this Agent's `service install` would write.
  static ServiceDefinition expected({String? home}) {
    final invocation = ServiceManager.daemonInvocation();
    return ServiceDefinition(
      executable: invocation.executable,
      arguments: invocation.arguments,
      sanadHome: home ?? getSanadHome(),
      serviceInstance: ServiceManager.serviceInstance,
    );
  }

  /// The definition path and scope this Home's installation recorded, or null
  /// when this Home records no installation it may read.
  ///
  /// `service install` writes both into `<home>/service.json`, and every other
  /// service command resolves the live definition from them. Reading that same
  /// record is what lets this report see a system-scope unit under
  /// `/etc/systemd/system`: the caller's own user unit is only a default, not
  /// the definition a system installation owns.
  static ({String path, ServiceScope scope})? _installation(
    Map<String, Object?>? metadata,
  ) {
    final scope = ServiceScope.fromWireName(metadata?['scope'] as String?);
    final path = metadata?['config_path'];
    if (scope == null || path is! String || path.isEmpty) return null;
    return (path: path, scope: scope);
  }

  /// The JSON report printed by `sanad service definition`.
  ///
  /// [home], [configPath] and [metadata] exist for tests: production always
  /// reads this process's Sanad Home, the definition its installation recorded,
  /// and the default user definition as the fallback.
  static Future<Map<String, Object?>> report({
    String? home,
    String? configPath,
    ServiceMetadataStore metadata = const ServiceMetadataStore(),
  }) async {
    final sanadHome = home ?? getSanadHome();
    final expected = ServiceDefinitionInspector.expected(home: sanadHome);
    final installation = _installation(
      (await metadata.read(sanadHome)).payload,
    );
    final path =
        installation?.path ??
        configPath ??
        ServiceManager.getServiceConfigPath();
    ServiceDefinition? installed;
    final file = path.isEmpty ? null : File(path);
    if (file != null && file.existsSync()) {
      installed = _parse(
        file.readAsStringSync(),
        scope: installation?.scope,
        serviceInstance: expected.serviceInstance,
      );
    }
    return {
      'platform': Platform.operatingSystem,
      'supported': path.isNotEmpty,
      ...compare(expected: expected, installed: installed),
    };
  }

  /// The definition [content] holds, read in the form [scope] names.
  ///
  /// A Home that records no installation is read in this platform's default
  /// form, which is the form the caller's own user definition is written in.
  static ServiceDefinition? _parse(
    String content, {
    required ServiceScope? scope,
    required String serviceInstance,
  }) => switch (scope) {
    ServiceScope.systemdUser || ServiceScope.systemdSystem =>
      parseSystemdUnit(content, serviceInstance: serviceInstance),
    ServiceScope.launchdUser => parseLaunchdPlist(content),
    _ => Platform.isMacOS
        ? parseLaunchdPlist(content)
        : parseSystemdUnit(content, serviceInstance: serviceInstance),
  };

  static Map<String, Object?> compare({
    required ServiceDefinition expected,
    required ServiceDefinition? installed,
  }) => {
    'installed': installed != null,
    'matches': installed != null && installed == expected,
    'expected': expected.toJson(),
    'installed_definition': installed?.toJson(),
  };

  static ServiceDefinition? parseLaunchdPlist(String content) {
    final program = RegExp(
      r'<key>ProgramArguments</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(content);
    if (program == null) return null;
    final values = RegExp(
      r'<string>(.*?)</string>',
      dotAll: true,
    ).allMatches(program.group(1)!).map((m) => _unxml(m.group(1)!)).toList();
    if (values.isEmpty) return null;
    final environment = RegExp(
      r'<key>EnvironmentVariables</key>\s*<dict>(.*?)</dict>',
      dotAll: true,
    ).firstMatch(content)?.group(1);
    String? env(String key) {
      if (environment == null) return null;
      final match = RegExp(
        '<key>${RegExp.escape(key)}</key>\\s*<string>(.*?)</string>',
        dotAll: true,
      ).firstMatch(environment);
      return match == null ? null : _unxml(match.group(1)!);
    }

    final home = env('SANAD_HOME');
    if (home == null) return null;
    return ServiceDefinition(
      executable: values.first,
      arguments: values.sublist(1),
      sanadHome: home,
      serviceInstance: env('SANAD_SERVICE_INSTANCE') ?? '',
    );
  }

  /// systemd units carry the instance only in their file name, so the caller
  /// supplies the instance it located the unit by.
  static ServiceDefinition? parseSystemdUnit(
    String content, {
    required String serviceInstance,
  }) {
    final exec = RegExp(
      r'^ExecStart=(.*)$',
      multiLine: true,
    ).firstMatch(content);
    final home = ServiceUnitBuilder.declaredSanadHome(content);
    if (exec == null || home == null) return null;
    final tokens = _systemdTokens(exec.group(1)!);
    if (tokens.isEmpty) return null;
    return ServiceDefinition(
      executable: tokens.first,
      arguments: tokens.sublist(1),
      sanadHome: home,
      serviceInstance: serviceInstance,
    );
  }

  static List<String> _systemdTokens(String command) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    var inToken = false;
    for (var index = 0; index < command.length; index++) {
      final char = command[index];
      if (char == r'\' && quoted && index + 1 < command.length) {
        buffer.write(command[++index]);
      } else if (char == '"') {
        quoted = !quoted;
        inToken = true;
      } else if (char == ' ' && !quoted) {
        if (inToken) tokens.add(buffer.toString().replaceAll('%%', '%'));
        buffer.clear();
        inToken = false;
      } else {
        buffer.write(char);
        inToken = true;
      }
    }
    if (inToken) tokens.add(buffer.toString().replaceAll('%%', '%'));
    return tokens;
  }

  static String _unxml(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
