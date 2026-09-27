# Changelog

## Unreleased

### Added
- Index of every file and folder name under the chosen locations, including hidden files, app data and cloud folders (cloud-only files are indexed by name and never downloaded).
- Content search across plain text and code, PDFs (with text recognition for scanned pages), Word, RTF, OpenDocument, PowerPoint, Excel, EPUB, HTML, email files, and text in images.
- Query syntax: phrases, exclusions, `name:`, `content:`, `ext:`, `kind:`, `size:`, `modified:`, `created:`, `in:` / `-in:`, `hidden:`, `cloud:`.
- Accent- and case-insensitive matching in every script (Greek included) and English stemming.
- Regex search over names, contents and extracted document text, powered by a bundled ripgrep.
- Live updates from filesystem events, resuming where Moria left off after a restart.
- Optional semantic search ("Meaning") and plain-language requests ("Ask") using Apple's on-device models, off by default.
- Mac app: filter sidebar, sortable results with highlighted excerpts, Quick Look preview inspector, quick search panel on a global shortcut, menu bar item, and settings.
- `moria` command-line tool sharing the app's index: `index`, `watch`, `search` (`--regex`, `--semantic`, `--ask`, `--json`), `stats`, `config`.
