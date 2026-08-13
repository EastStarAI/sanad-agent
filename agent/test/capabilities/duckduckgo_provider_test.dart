import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/capabilities/runtime/web_search/duckduckgo_provider.dart';
import 'package:test/test.dart';

void main() {
  test('decodes DuckDuckGo protocol-relative redirect URLs', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'html.duckduckgo.com');
      return http.Response('''
        <html>
          <div class="result results_links">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fopenai.com%2Fguides%2Fbuilding%2520agents&amp;rut=test">
              Building AI Agents
            </a>
            <a class="result__snippet">A guide to building agents.</a>
          </div>
        </html>
      ''', 200);
    });

    final result = await DuckDuckGoProvider(
      client: client,
    ).search('Building AI Agents');

    expect(result.hits, hasLength(1));
    expect(result.hits.single.title, 'Building AI Agents');
    expect(
      result.hits.single.url,
      'https://openai.com/guides/building%20agents',
    );
    expect(result.hits.single.snippet, 'A guide to building agents.');
  });

  test('keeps direct result URLs unchanged', () async {
    final client = MockClient((request) async {
      return http.Response('''
        <div class="result">
          <a class="result__a" href="https://example.com/result">Example</a>
        </div>
      ''', 200);
    });

    final result = await DuckDuckGoProvider(client: client).search('example');

    expect(result.hits.single.url, 'https://example.com/result');
  });
}
