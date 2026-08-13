---
title: "Web Search Runtime"
description: "Daemon-owned web search providers, DuckDuckGo redirect normalization, fallback behavior, and SSRF filtering."
---

# Web Search Runtime

The `web_search` tool is assembled by the daemon's local runtime catalog. The
service resolves `WEB_SEARCH_PROVIDER` and `SERPER_API_KEY` at execution time,
so settings changes apply without rebuilding the service.

## Providers

The default provider is the keyless DuckDuckGo HTML provider (`ddg`). Serper
(`serper`) is used when selected and configured with `SERPER_API_KEY`; the
service falls through the ordered provider list when a provider is unavailable,
throws, or returns no usable hits.

DuckDuckGo result links may be either `/l/?...` paths or protocol-relative
`//duckduckgo.com/l/?...` URLs. The provider normalizes both forms before
extracting the `uddg` target. `Uri.queryParameters` performs the one required
percent-decoding pass; decoding the extracted target again can corrupt valid
percent-encoded path segments.

## Safety boundary

Search hits are passed through `UrlSafetyValidator` before they are returned.
Only HTTP(S) URLs resolving exclusively to public addresses are allowed. This
prevents search results from becoming an SSRF path to loopback, private,
link-local, or multicast hosts. Provider failures and safety-filtered results
are intentionally represented as an empty search result by the service.

The provider regression tests use a representative DuckDuckGo HTML response so
redirect-shape changes are detected without depending on a live search engine.
