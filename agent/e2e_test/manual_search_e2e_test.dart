import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/capabilities/runtime/web_search/web_search_service.dart';
import 'package:sanad_agent/capabilities/runtime/web_search/web_fetch_service.dart';
import 'package:sanad_agent/capabilities/runtime/web_search/duckduckgo_provider.dart';
import 'package:sanad_agent/capabilities/runtime/web_search/serper_provider.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory sanadHome;
  late Directory sanadStateHome;

  setUp(() async {
    sanadHome = await Directory.systemTemp.createTemp('manual-search-home-');
    sanadStateHome = await Directory.systemTemp.createTemp(
      'manual-search-state-',
    );
    setSanadHomeOverride(sanadHome.path);
    setSanadStateHomeOverride(sanadStateHome.path);
  });

  tearDown(() async {
    await getIt.reset();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (await sanadHome.exists()) await sanadHome.delete(recursive: true);
    if (await sanadStateHome.exists()) {
      await sanadStateHome.delete(recursive: true);
    }
  });

  test(
    'manual search and fetch e2e verification',
    () async {
      print('=============================================');
      print('Running Web Search & Fetch Verification Tool');
      print('=============================================\n');

      // Initialize Dependency Injection container and configurations
      setupDI();

      final config = getIt<Config>();
      final client = http.Client();

      print('Configuration Loaded:');
      print('* Active Provider: ${config.activeProvider}');
      print('* Preferred Search Provider: ${config.webSearchProvider}');
      print(
        '* Serper API Key configured: ${config.serperApiKey.isNotEmpty ? "YES (ends in ...${config.serperApiKey.substring(config.serperApiKey.length - 6)})" : "NO"}',
      );
      print('--------------------------------------------\n');

      // Retrieve wired instances from DI (these use config keys dynamically)
      final searchService = getIt<WebSearchService>();
      final fetchService = getIt<WebFetchService>();

      final ddgProvider = DuckDuckGoProvider(client: client);
      final serperProvider = SerperProvider(
        client: client,
        apiKey: config.serperApiKey,
      );

      // 1. Test DuckDuckGo Scraper Directly
      print('--- Test 1: DuckDuckGo Scraper (Direct Scrape) ---');
      try {
        print('Searching DuckDuckGo for "Dart programming language"...');
        final result = await ddgProvider.search('Dart programming language');
        print('Success! Found ${result.hits.length} hits:');
        for (final hit in result.hits) {
          print('* ${hit.title} -> ${hit.url}');
        }
      } catch (e) {
        print('DuckDuckGo Scrape Exception: $e');
        print(
          '\n[NOTE] DuckDuckGo typically returns a 202 CAPTCHA block when queried from cloud/datacenter IPs.',
        );
        print(
          'This is expected behavior in the cloud development environment. On residential desktop IPs, it runs freely.',
        );
      }
      print('\n----------------------------------------\n');

      // 2. Test Serper Provider directly
      print('--- Test 2: Serper Search Provider (API-based) ---');
      if (serperProvider.isConfigured) {
        try {
          print('Searching Serper for "Dart programming language"...');
          final result = await serperProvider.search(
            'Dart programming language',
          );
          print('Success! Found ${result.hits.length} hits:');
          if (result.directAnswer != null) {
            print('Direct Answer: ${result.directAnswer}');
          }
          for (final hit in result.hits) {
            print('* ${hit.title} -> ${hit.url}');
          }
        } catch (e) {
          print('Serper Search failed: $e');
        }
      } else {
        print(
          'Serper Search Provider is not configured (missing API key). Skipping direct test.',
        );
      }
      print('\n----------------------------------------\n');

      // 3. Test WebSearchService fallback pipeline (wired via DI)
      print('--- Test 3: WebSearchService fallback pipeline (DI Wired) ---');
      try {
        print('Searching WebSearchService for "Flutter framework"...');
        final output = await searchService.search('Flutter framework');
        print(output);
      } catch (e) {
        print('WebSearchService search failed: $e');
      }
      print('\n----------------------------------------\n');

      // 4. Test WebSearchService domain limits
      print('--- Test 4: WebSearchService with domain limit (Wikipedia) ---');
      try {
        print('Searching Wikipedia for "Dart language"...');
        final output = await searchService.search(
          'Dart language',
          allowedDomains: ['wikipedia.org'],
        );
        print(output);
      } catch (e) {
        print('WebSearchService domain limit failed: $e');
      }
      print('\n----------------------------------------\n');

      // 5. Test standard Web Fetch (Wikipedia Page)
      print('--- Test 5: Standard Web Fetch (DOM-based parser) ---');
      try {
        final fetchResults = await fetchService.fetch([
          'https://en.wikipedia.org/wiki/Dart_(programming_language)',
        ], prompt: 'Summarize Dart details');
        final firstResult = fetchResults.first;
        print('Response Code: ${firstResult.code} (${firstResult.codeText})');
        print('Bytes Fetched: ${firstResult.bytes}');
        print('Content Snippet (first 400 chars):');
        final content = firstResult.result;
        print(
          content.length > 400 ? '${content.substring(0, 400)}...' : content,
        );
      } catch (e) {
        print('Fetch failed: $e');
      }
      print('\n----------------------------------------\n');

      // 6. Test SSRF blocking (localhost / private subnet)
      print('--- Test 6: SSRF Blocking validation (Parallel Fetch) ---');
      final urlsToTest = [
        'http://127.0.0.1:8000/api/v1/health',
        'http://localhost/index.html',
        'https://192.168.1.1/admin',
      ];

      try {
        final fetchResults = await fetchService.fetch(urlsToTest);
        for (final fetchResult in fetchResults) {
          print('URL: ${fetchResult.url} -> Code: ${fetchResult.code}');
          print('Response Message: ${fetchResult.result}');
          print('---');
        }
      } catch (e) {
        print('Parallel fetch validation failed: $e');
      }

      client.close();
      print('\nVerification Complete!');
    },
    skip:
        'Requires live internet connection and Serper API config. Run manually as needed.',
  );
}
