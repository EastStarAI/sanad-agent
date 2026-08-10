---
title: "Clarifying Question RTL QA"
description: "Verification matrix for Arabic directionality and platform-aware multiline behavior in clarifying questions."
---

# Clarifying Question RTL QA

## Scope

This matrix covers text direction in the active `system_ask_user` suspension card, completed ask-user tool results, and conversation event headers.

## Automated Coverage

| Scenario | Expected result |
|---|---|
| Arabic question with Arabic choices | The question and every Arabic choice use RTL direction and right alignment. |
| English question or choice | The individual string remains LTR and left-aligned. |
| Mixed Arabic and English choices | Direction is resolved independently per choice; the card itself is not globally mirrored. |
| Arabic custom answer input | The input switches to RTL and right alignment as Arabic content is entered. |
| Custom answer desktop `Enter` | A non-empty custom answer is submitted. |
| Custom answer desktop `Shift+Enter` | The editor remains open and accepts a multiline line break without submission. |
| Custom answer Android/iOS software-keyboard `Enter` | A line break is inserted and the answer remains open until the visible submit action is used. |
| Completed Arabic question and answer | Question and answer each render RTL and right-aligned. |
| Arabic extended Unicode characters | Direction detection classifies the text as RTL. |
| Arabic ask-user event header | The complete header row follows RTL direction, including status, title, expansion, and error indicators. |
| English event header | The header row retains LTR ordering and alignment. |

## Visual Review

Open a conversation that receives a `system_ask_user` request containing Arabic questions and choices. Confirm that dynamic Arabic strings begin on the right while the fixed English header, dismiss action, and navigation controls retain their normal layout. Submit an Arabic answer and confirm that the completed tool result keeps the question and answer right-aligned.
