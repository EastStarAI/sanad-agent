import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;
import 'web_search_provider.dart';

class DuckDuckGoProvider implements WebSearchProvider {
  final http.Client _client;

  static const _timeout = Duration(seconds: 15);
  static const _ddgUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Safari/537.36';

  @override
  String get name => 'ddg';

  @override
  bool get isConfigured => true; // Always available, no keys required

  DuckDuckGoProvider({required http.Client client}) : _client = client;

  @override
  Future<WebSearchResult> search(
    String query, {
    List<String>? allowedDomains,
    int? limit,
  }) async {
    final maxResults = limit ?? 6;
    var finalQuery = query.trim();

    if (allowedDomains != null && allowedDomains.isNotEmpty) {
      final domainFilter = allowedDomains.map((d) => 'site:$d').join(' OR ');
      finalQuery = '$finalQuery ($domainFilter)';
    }

    final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': finalQuery});
    final response = await _client
        .get(
          uri,
          headers: {
            'User-Agent': _ddgUserAgent,
            'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.5',
          },
        )
        .timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'DuckDuckGo HTML interface returned status ${response.statusCode}',
      );
    }

    final html = response.body;
    if (html.contains('anomaly-modal') ||
        html.contains('bots use DuckDuckGo too') ||
        html.contains('CAPTCHA')) {
      throw Exception(
        'DuckDuckGo rate-limited the request (CAPTCHA/Anomaly detected)',
      );
    }

    final document = parse(html);
    final hits = <SearchHit>[];
    final seenUrls = <String>{};

    // Try parsing using DuckDuckGo HTML structure (.result containers)
    final resultElements = document.querySelectorAll('.result');
    for (final element in resultElements) {
      if (hits.length >= maxResults) break;
      final link = element.querySelector('.result__a');
      if (link == null) continue;
      final href = link.attributes['href'];
      if (href == null) continue;

      final decodedUrl = _decodeDdgRedirect(href);
      if (decodedUrl == null || !seenUrls.add(decodedUrl)) continue;

      final title = link.text.trim();
      final snippet =
          element.querySelector('.result__snippet')?.text.trim() ?? '';

      if (title.isNotEmpty) {
        hits.add(SearchHit(title: title, url: decodedUrl, snippet: snippet));
      }
    }

    // Fallback: If no .result containers found, parse links and snippets by indices
    if (hits.isEmpty) {
      final links = document.querySelectorAll('.result__a');
      final snippets = document.querySelectorAll('.result__snippet');
      for (var i = 0; i < links.length; i++) {
        if (hits.length >= maxResults) break;
        final link = links[i];
        final href = link.attributes['href'];
        if (href == null) continue;

        final decodedUrl = _decodeDdgRedirect(href);
        if (decodedUrl == null || !seenUrls.add(decodedUrl)) continue;

        final title = link.text.trim();
        String snippet = '';
        if (i < snippets.length) {
          snippet = snippets[i].text.trim();
        }

        if (title.isNotEmpty) {
          hits.add(SearchHit(title: title, url: decodedUrl, snippet: snippet));
        }
      }
    }

    return WebSearchResult(hits: hits);
  }

  String? _decodeDdgRedirect(String url) {
    // DuckDuckGo currently emits both `/l/?...` and protocol-relative
    // `//duckduckgo.com/l/?...` redirect URLs. Normalize both before parsing;
    // otherwise the latter has no scheme and is rejected by SSRF validation.
    final normalizedUrl = url.startsWith('//')
        ? 'https:$url'
        : url.startsWith('/l/?')
        ? 'https://duckduckgo.com$url'
        : url;
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || uri.path != '/l/' || !uri.hasQuery) {
      return url.startsWith('//') ? null : url;
    }

    // Uri.queryParameters already percent-decodes `uddg` exactly once. A
    // second decode would corrupt legitimate percent-encoded path segments.
    final redirectedUrl = uri.queryParameters['uddg'];
    return redirectedUrl == null || redirectedUrl.isEmpty
        ? null
        : redirectedUrl;
  }
}
