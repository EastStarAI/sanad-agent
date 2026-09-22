---
title: "OpenRouter App Attribution QA"
description: "Regression matrix for OpenRouter request attribution and provider isolation."
---

# OpenRouter App Attribution QA

## Scope

Verify that Sanad identifies itself on new OpenRouter chat-completion requests using OpenRouter's documented attribution headers without changing authentication, payloads, or unrelated provider traffic.

## Automated regression matrix

| Scenario | Expected result |
|---|---|
| Inspect the OpenRouter provider template | `HTTP-Referer` is exactly `https://sanad.eaststarai.com`; `X-OpenRouter-Title` is exactly `Sanad Agent`; legacy `X-Title` is absent. |
| Send a synchronous OpenRouter model request through the OpenAI-compatible adapter | Both attribution headers and the existing bearer authorization reach the outbound request. |
| Send a streaming OpenRouter model request through the same adapter | The same two attribution headers reach the outbound request and stream parsing remains successful. |
| Inspect an unrelated OpenAI provider template | Neither OpenRouter attribution header is present. |

The focused automated owner is `agent/test/engine/openrouter_attribution_test.dart`.

## Acceptance boundary

- Header ownership remains in the OpenRouter provider template rather than a provider-name branch in the shared adapter.
- Exact capitalization is documented for protocol clarity; verification may compare request-map keys case-insensitively because HTTP clients can normalize header names.
- The change applies to new requests only. Historical OpenRouter usage attributed as Unknown is not expected to be rewritten.
