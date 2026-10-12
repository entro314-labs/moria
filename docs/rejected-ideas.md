# Rejected ideas

Reviewed and turned down, so they aren't proposed again without new reasons.

## SpotlightSearchTool for Ask

Foundation Models' `SpotlightSearchTool` (WWDC26, "LLM search using Core Spotlight"; Core
Spotlight docs: "Spotlight search tool") lets the on-device model search an app's own Core
Spotlight index — the `CSSearchableItem`s the app donated — and answer from the results.

Rejected: Moria's index is its own SQLite database of millions of entries and never donates to
Core Spotlight, so using the tool would mean copying the whole index into Spotlight's store.
Ask also doesn't answer questions; it turns a request into filters the user can see and edit.
If Moria ever answers questions about files (RAG), the fit is a custom `Tool` over
`SearchEngine`, not this one.

## Reviewed 2026-09-29 (see `audit-2026-09-29.md`)

- **An SDK flow layout instead of `FlowLayout`.** The macOS 26 SwiftUI interface declares
  `GridLayout` and `AligningContentProviderLayout` only; nothing wraps.
- **swift-subprocess `.data(limit:)` instead of `ProcessRunner`'s truncation.** The limit throws
  `outputLimitExceeded`; `ProcessRunner.output` wants the first N bytes and a stopped child.
- **Re-vendoring Snowball 3.1.1 (from 3.0.1).** Its NEWS lists no change to the Greek or Russian
  algorithms, only C runtime refactors; regenerating both stemmers would change no result.
- **Unknown MCP tool as a protocol error (`-32602`).** The spec calls for it; the server returns a
  tool result with `isError` on purpose, so the model sees the message. Revisit only if a client
  is shown to mishandle it.
- **`resultType` and cache hints on handshake-era MCP responses.** Clients "MUST treat an absent
  `resultType` as complete"; adding them would change tested output for nothing.
- **A count-only engine method for sidebar badges.** Measured on 2026-10-12 on a 4.3-million-entry
  index (3.6 M files): the seven collection counts take 5, 67, 83, 17, 76, 51 and 82 ms, about
  0.4 s in all, once per sidebar appearance or saved-search change, in the background. A
  count-only query would save only the fetch of up to 1000 rows after the candidate scan, which
  is where the time goes. Not worth an engine entry point.

## An `answer` tool for `moria mcp`

Answer mode (2026-10-12) retrieves passages and has Apple's on-device model write an answer. An MCP client is itself a language model with a far larger context window; what it needs from Moria is the retrieval (`search`, `regex_search`), not a second, smaller model's prose. Not offered.
