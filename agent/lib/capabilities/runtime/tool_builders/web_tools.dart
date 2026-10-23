import 'dart:convert';

import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';

import '../web_search/web_fetch_service.dart';
import '../web_search/web_search_service.dart';

/// Web tool builders for `LocalRuntimeCatalog`: `web_search` and `web_fetch`.
///
/// Each builder receives the live service for the turn; the catalog still owns
/// per-turn assembly and never lets these functions become a second registry.
BaseTool buildWebSearchTool({required WebSearchService webSearchService}) {
  return CallbackTool(
    toolSpec: const LocalToolSpec(
      name: 'web_search',
      displayName: 'Web Search',
      description:
          'Search the web from the local runtime with optional domain filtering and result limits.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'allowed_domains': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Optional list of domains to restrict search results to (e.g. ["wikipedia.org"]).',
          },
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 10,
            'description':
                'Optional limit on the number of search hits returned.',
          },
        },
        'required': ['query'],
        'additionalProperties': false,
      },
      source: {'type': 'builtin_local', 'id': 'sanad-agent.web'},
      category: 'web',
      workspaceRequired: false,
      approval: {'mode': 'default', 'sensitive': false},
      execution: {'target': 'local_runtime', 'timeout_ms': 30000},
      serverName: 'web',
    ),
    onExecute: (args, {context}) async {
      final query = args['query']?.toString() ?? '';
      final limit = args['limit'] is int ? args['limit'] as int : null;

      final domainsRaw = args['allowed_domains'];
      List<String>? allowedDomains;
      if (domainsRaw is List) {
        allowedDomains = domainsRaw.map((d) => d.toString()).toList();
      }

      return webSearchService.search(
        query,
        allowedDomains: allowedDomains,
        limit: limit,
      );
    },
  );
}

BaseTool buildWebFetchTool({required WebFetchService webFetchService}) {
  return CallbackTool(
    toolSpec: const LocalToolSpec(
      name: 'web_fetch',
      displayName: 'Web Fetch',
      description:
          'Fetch the content of specific URLs concurrently and summarize them.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'urls': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'List of URLs to fetch content from (max 5 URLs).',
          },
          'prompt': {'type': 'string'},
        },
        'required': ['urls'],
        'additionalProperties': false,
      },
      source: {'type': 'builtin_local', 'id': 'sanad-agent.web'},
      category: 'web',
      workspaceRequired: false,
      approval: {'mode': 'default', 'sensitive': false},
      execution: {'target': 'local_runtime', 'timeout_ms': 30000},
      serverName: 'web',
    ),
    onExecute: (args, {context}) async {
      final urlsRaw = args['urls'];
      List<String> urls = [];
      if (urlsRaw is List) {
        urls = urlsRaw.map((u) => u.toString()).toList();
      } else if (urlsRaw is String) {
        urls = [urlsRaw];
      }

      final results = await webFetchService.fetch(
        urls,
        prompt: args['prompt']?.toString() ?? '',
      );
      final jsonList = results.map((r) => r.toJson()).toList();
      return const JsonEncoder.withIndent(
        '  ',
      ).convert({'results': jsonList});
    },
  );
}
