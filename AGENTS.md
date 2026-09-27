# Moria

Native macOS deep file search: filenames, contents, regex, meaning. SwiftPM package, no Xcode project.

## Layout

- `Sources/MoriaCore` — engine, shared by the app and CLI.
  - `Crawl/` — `Crawler` (fts(3) walk, exclusion and content-scope rules), `PipelinedCrawl` (crawl thread with backpressure).
  - `Database/` — `IndexDatabase` (schema, settings in `meta`), `FileStore` (`MetadataWriter`, extraction/embedding storage), `Folding` (diacritic-folding FTS5 tokenizer `moria_fold`).
  - `Extract/` — `ContentExtractor` (text/PDF/Office/zip/HTML/OCR), `MaterializationGuard` (blocks cloud downloads), `ProcessRunner`, `AsyncLimiter`.
  - `Index/IndexController` — the one actor that scans, applies FSEvents changes, extracts and embeds.
  - `Search/` — `QueryParser`/`SearchQuery`, `QueryFormatter`, `SearchEngine` (RRF fusion, on-demand snippets), `RegexSearcher` (ripgrep + stored text), `NaturalLanguageQuery` (Foundation Models).
  - `Semantic/` — `Embedder` (NLContextualEmbedding, mean-pooled), `VectorIndex` (in-memory Float16, vDSP).
  - `Watch/FileWatcher` — FSEvents stream.
- `Sources/MoriaCLI` — the `moria` executable (target `moria`).
- `Sources/MoriaApp` — the app (target `MoriaApp`, bundled as `Moria.app`). Default isolation is `MainActor`.
- `Scripts/package_app.sh` — builds and signs `build/Moria.app` with bundled ripgrep and icon.

## Key design decisions

- Schema: folders keep full paths in `dir`; files store `(dirId, name)`. Both FTS5 tables are contentless; only PDF/Office/OCR text is stored (`doc_text`). Snippets are built on demand (`SearchEngine.snippet`).
- Content scope: names are indexed everywhere; text is extracted only outside `~/Library`, hidden folders and dependency/build folders (`contentState = 5` = excluded).
- The process sets `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` so reading a cloud placeholder fails instead of downloading it. Keep it that way.
- Migration `v1` has not shipped; edit it in place until the first release, then add migrations.

## Build, test, run

- `swift build`, `swift test` (Swift Testing; tests use temp directories only).
- `swift build --product MoriaApp && .build/debug/MoriaApp -initialQuery "invoice" -indexPath /tmp/x.sqlite` runs the app unbundled (no Full Disk Access of its own) on a scratch index.
- `Scripts/package_app.sh` then `open build/Moria.app` for the real thing. It signs with the first "Apple Development" identity so Full Disk Access survives rebuilds.
- `.build/debug/moria --help` for the CLI; `--db <path>` points it at a scratch index.
