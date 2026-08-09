import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';

enum McpConfigScope { global, workspace, effective }

extension McpConfigScopeWire on McpConfigScope {
  String get wireValue => switch (this) {
    McpConfigScope.global => 'global',
    McpConfigScope.workspace => 'workspace',
    McpConfigScope.effective => 'effective',
  };
}

class McpRuntimeServerEntry {
  const McpRuntimeServerEntry({
    required this.name,
    required this.source,
    required this.config,
    this.workspaceId,
  });

  final String name;
  final String source;
  final McpServerConfig config;
  final String? workspaceId;

  factory McpRuntimeServerEntry.fromJson(Map<String, dynamic> json) {
    final configJson = Map<String, dynamic>.from(json['config'] as Map? ?? const {});
    configJson.putIfAbsent('name', () => json['name']?.toString() ?? '');
    return McpRuntimeServerEntry(
      name: json['name']?.toString() ?? '',
      source: json['source']?.toString() ?? 'unknown',
      workspaceId: json['workspace_id']?.toString(),
      config: McpServerConfig.fromJson(configJson),
    );
  }
}

class McpRuntimeSection {
  const McpRuntimeSection({
    required this.scope,
    required this.document,
    required this.servers,
  });

  final McpConfigScope scope;
  final Map<String, dynamic> document;
  final List<McpRuntimeServerEntry> servers;

  factory McpRuntimeSection.fromJson(Map<String, dynamic> json) {
    final scopeName = json['scope']?.toString() ?? 'effective';
    final scope = McpConfigScope.values.firstWhere(
      (value) => value.wireValue == scopeName,
      orElse: () => McpConfigScope.effective,
    );
    final servers = (json['servers'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => McpRuntimeServerEntry.fromJson(Map<String, dynamic>.from(entry)))
        .toList(growable: false);
    return McpRuntimeSection(
      scope: scope,
      document: Map<String, dynamic>.from(json['document'] as Map? ?? const {'mcpServers': {}}),
      servers: servers,
    );
  }
}

class McpRuntimeSnapshot {
  const McpRuntimeSnapshot({
    required this.global,
    required this.workspace,
    required this.effective,
    this.workspaceId,
  });

  final String? workspaceId;
  final McpRuntimeSection global;
  final McpRuntimeSection workspace;
  final McpRuntimeSection effective;

  factory McpRuntimeSnapshot.fromJson(Map<String, dynamic> json) {
    return McpRuntimeSnapshot(
      workspaceId: json['workspace_id']?.toString(),
      global: McpRuntimeSection.fromJson(Map<String, dynamic>.from(json['global'] as Map? ?? const {})),
      workspace: McpRuntimeSection.fromJson(Map<String, dynamic>.from(json['workspace'] as Map? ?? const {})),
      effective: McpRuntimeSection.fromJson(Map<String, dynamic>.from(json['effective'] as Map? ?? const {})),
    );
  }
}

class McpRuntimeTool {
  const McpRuntimeTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  factory McpRuntimeTool.fromJson(Map<String, dynamic> json) {
    return McpRuntimeTool(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      inputSchema: Map<String, dynamic>.from(json['input_schema'] as Map? ?? const {}),
    );
  }
}

class McpDraftPreviewEntry {
  const McpDraftPreviewEntry({required this.name, required this.config});

  final String name;
  final McpServerConfig config;

  factory McpDraftPreviewEntry.fromJson(Map<String, dynamic> json) {
    final configJson = Map<String, dynamic>.from(json['config'] as Map? ?? const {});
    configJson.putIfAbsent('name', () => json['name']?.toString() ?? '');
    return McpDraftPreviewEntry(
      name: json['name']?.toString() ?? '',
      config: McpServerConfig.fromJson(configJson),
    );
  }
}

class McpConfigFieldDiff {
  const McpConfigFieldDiff({required this.field, this.before, this.after});

  final String field;
  final Object? before;
  final Object? after;

  factory McpConfigFieldDiff.fromJson(Map<String, dynamic> json) => McpConfigFieldDiff(
    field: json['field']?.toString() ?? '',
    before: json['before'],
    after: json['after'],
  );
}

class McpConfigPreview {
  const McpConfigPreview({
    required this.servers,
    required this.warnings,
    required this.unsupportedFields,
    required this.revision,
    this.diff = const [],
  });

  final List<McpDraftPreviewEntry> servers;
  final List<String> warnings;
  final List<String> unsupportedFields;
  final String revision;
  final List<McpConfigFieldDiff> diff;

  factory McpConfigPreview.fromJson(Map<String, dynamic> json) => McpConfigPreview(
    servers: (json['servers'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => McpDraftPreviewEntry.fromJson(Map<String, dynamic>.from(entry)))
        .toList(growable: false),
    warnings: _runtimeStringList(json['warnings']),
    unsupportedFields: _runtimeStringList(json['unsupported_fields']),
    revision: json['revision']?.toString() ?? '',
    diff: (json['diff'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => McpConfigFieldDiff.fromJson(Map<String, dynamic>.from(entry)))
        .toList(growable: false),
  );
}

class McpAdvancedDocument {
  const McpAdvancedDocument({
    required this.serverName,
    required this.json,
    required this.baseRevision,
    required this.credentialsExcluded,
  });

  final String serverName;
  final String json;
  final String baseRevision;
  final bool credentialsExcluded;

  factory McpAdvancedDocument.fromJson(Map<String, dynamic> json) => McpAdvancedDocument(
    serverName: json['server_name']?.toString() ?? '',
    json: json['json']?.toString() ?? '',
    baseRevision: json['base_revision']?.toString() ?? '',
    credentialsExcluded: json['credentials_excluded'] == true,
  );
}

class McpExportDocument {
  const McpExportDocument({required this.json, required this.credentialsExcluded});

  final String json;
  final bool credentialsExcluded;

  factory McpExportDocument.fromJson(Map<String, dynamic> json) => McpExportDocument(
    json: json['json']?.toString() ?? '',
    credentialsExcluded: json['credentials_excluded'] == true,
  );
}

List<String> _runtimeStringList(Object? value) =>
    value is List ? value.map((item) => item.toString()).toList(growable: false) : const [];

enum McpOAuthStatus {
  pending,
  authorizationRequired,
  approved,
  error,
  cancelled,
  expired,
}

class McpOAuthFlow {
  const McpOAuthFlow({
    required this.flowId,
    required this.status,
    required this.expiresAt,
    this.authorizationUrl,
    this.error,
  });

  final String flowId;
  final McpOAuthStatus status;
  final DateTime? expiresAt;
  final Uri? authorizationUrl;
  final String? error;

  bool get isTerminal => const {
    McpOAuthStatus.approved,
    McpOAuthStatus.error,
    McpOAuthStatus.cancelled,
    McpOAuthStatus.expired,
  }.contains(status);

  factory McpOAuthFlow.fromJson(Map<String, dynamic> json) {
    final raw = json['status']?.toString();
    return McpOAuthFlow(
      flowId: json['flow_id']?.toString() ?? '',
      status: raw == 'authorization_required'
          ? McpOAuthStatus.authorizationRequired
          : McpOAuthStatus.values.firstWhere(
              (value) => value.name == raw,
              orElse: () => McpOAuthStatus.error,
            ),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      authorizationUrl: Uri.tryParse(json['authorization_url']?.toString() ?? ''),
      error: json['error']?.toString(),
    );
  }
}

class McpServerInspection {
  const McpServerInspection({
    required this.name,
    required this.success,
    required this.tools,
    this.scope = McpConfigScope.effective,
    this.workspaceId,
    this.error,
    this.transport,
    this.authState = 'not_required',
  });

  final String name;
  final bool success;
  final List<McpRuntimeTool> tools;
  final McpConfigScope scope;
  final String? workspaceId;
  final String? error;
  final McpTransportType? transport;
  final String authState;

  factory McpServerInspection.fromJson(Map<String, dynamic> json) {
    final scopeName = json['scope']?.toString() ?? 'effective';
    return McpServerInspection(
      name: json['name']?.toString() ?? '',
      success: json['success'] == true,
      error: json['error']?.toString(),
      authState: json['auth_state']?.toString() ?? 'not_required',
      transport: McpTransportType.values
          .where(
            (value) => value.name == json['transport']?.toString(),
          )
          .firstOrNull,
      workspaceId: json['workspace_id']?.toString(),
      scope: McpConfigScope.values.firstWhere(
        (value) => value.wireValue == scopeName,
        orElse: () => McpConfigScope.effective,
      ),
      tools: (json['tools'] as List? ?? const [])
          .whereType<Map>()
          .map((entry) => McpRuntimeTool.fromJson(Map<String, dynamic>.from(entry)))
          .toList(growable: false),
    );
  }
}
