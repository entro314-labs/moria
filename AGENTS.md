# Moria

Native macOS deep file search: filenames, contents, regex, meaning. SwiftPM package, no Xcode project.

## Layout

- `Sources/MoriaCore` — engine, shared by the app and CLI.
  - `Crawl/` — `Crawler` (fts(3) walk, exclusion and content-scope rules), `PipelinedCrawl` (crawl thread with backpressure).
  - `Database/` — `IndexDatabase` (schema, settings in `meta`), `FileStore` (`MetadataWriter`, extraction/embedding storage), `Folding` (diacritic-folding FTS5 tokenizer `moria_fold`).
  - `Extract/` — `ContentExtractor` (text/PDF/Office/zip/HTML/OCR), `MaterializationGuard` (blocks cloud downloads), `ProcessRunner`, `AsyncLimiter`.
  - `Index/IndexController` — the one actor that scans, applies FSEvents changes, extracts and embeds.
  - `Search/` — `QueryParser`/`SearchQuery`, `QueryFormatter`, `SearchEngine` (RRF fusion, on-demand snippets, `similar:`), `RegexSearcher` (ripgrep + stored text), `NaturalLanguageQuery` (Foundation Models), `Stemmer` (Greek/Russian query stems).
  - `MCP/MCPServer` — `moria mcp`: JSON-RPC tools over the index, transport-free so it is testable.
  - `Semantic/` — `Embedder` (NLContextualEmbedding, mean-pooled), `VectorIndex` (in-memory Float16, vDSP).
  - `Watch/FileWatcher` — FSEvents stream.
- `Sources/CSnowball` — vendored Snowball runtime with the UTF-8 Greek and Russian stemmers (BSD).
- `Sources/MoriaCLI` — the `moria` executable (target `moria`).
- `Sources/MoriaApp` — the app (target `MoriaApp`, bundled as `Moria.app`). Default isolation is `MainActor`.
- `Scripts/package_app.sh` — builds and signs `build/Moria.app` with bundled ripgrep and icon.

## Key design decisions

- Schema: folders keep full paths in `dir`; files store `(dirId, name)`. Both FTS5 tables are contentless; only PDF/Office/OCR text is stored (`doc_text`). Snippets are built on demand (`SearchEngine.snippet`).
- Content scope: names are indexed everywhere; text is extracted only outside `~/Library`, hidden folders and dependency/build folders (`contentState = 5` = excluded). Symlinks are names only (`7`); their targets are read where they live.
- Changing an extraction setting marks indexed files stale (`contentState = 6`): their text stays searchable until they are read again. The invalidation trigger treats 1 and 6 alike.
- Settings live in the index (`meta`); the running app re-reads them (`IndexController.reloadSettings`) so `moria config` changes apply. A change to what is crawled clears the FSEvents resume point until a full scan completes.
- Stemming: the content index stems English at index time (FTS5 `porter`). Greek and Cyrillic (Russian) words are stemmed at query time with vendored Snowball (`Sources/CSnowball`, `Stemmer`) and searched as a prefix of the stem, which the stored folded forms share, so no re-indexing is involved. Latin-script words in other languages aren't stemmed: their language can't be told from the word.
- Regex: names and stored text use ICU; files use ripgrep with `--engine auto` (PCRE2 when a pattern needs it). Case-sensitive patterns carry `(?-i)`. Homebrew's ripgrep, linked against Homebrew's PCRE2, misses some PCRE2 matches; the app bundles the official static build.
- The process sets `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` so reading a cloud placeholder fails instead of downloading it. Keep it that way.
- External drives: `fsevents.volumes` (meta) records each location's mount point and FSEvents database at its last scan. A location whose recorded volume isn't mounted is offline: full scans don't crawl or prune it, `apply` ignores its changes (an eject reports everything as gone), extraction and embedding skip it, and results under it are `isOffline`. Connected locations on other volumes are crawled again at launch and when FSEvents reports their root changed.
- Finder tags are a `file.tags` column ("\nRed\nWork\n", NULL when untagged), read during the crawl only where contents are read: `getxattr` costs ~25 µs per file even when absent. The upsert always takes the tags read, since tagging changes neither mtime nor size.
- Schema changes go in new migrations (`v3`, …): real indexes exist with `v1` and `v2-filter-indexes` applied; `v3-stale-content` and `v4-tags` are applied the first time a build with them opens an index (`v4-tags` drops the resume point so the next start scans for tags). Never edit applied migrations.
- `MoriaSettings` decodes missing keys with defaults; keep that when adding settings.

## Build, test, run

- `swift build`, `swift test` (Swift Testing; tests use temp directories only). `MoriaCoreTests` covers the engine; `MoriaAppTests` covers app logic with an `AppModel` on a scratch index and its own defaults (`makeAppModel()`).
- `swift build --product MoriaApp && .build/debug/MoriaApp -initialQuery "invoice" -indexPath /tmp/x.sqlite` runs the app unbundled (no Full Disk Access of its own) on a scratch index.
- `Scripts/package_app.sh` then `open build/Moria.app` for the real thing. It signs with the first "Apple Development" identity so Full Disk Access survives rebuilds.
- `.build/debug/moria --help` for the CLI; `--db <path>` points it at a scratch index.
