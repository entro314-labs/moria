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
