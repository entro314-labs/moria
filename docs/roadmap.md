# Roadmap

Work worth doing, grouped by size, smallest first. The tiers describe scope, not order or
schedule. Read with `rejected-ideas.md`: nothing turned down there belongs here without new
reasons.

Anything that stores new data in the index needs a new migration (`v4`, …); applied migrations
are never edited.

## Nice to have

- **Finder tags.** A `tag:` filter, a Tags column and a tag criterion. Needs tags stored per file
  (migration) and a check that tag changes reach the index through FSEvents.
- **Labels for photos.** Vision's image classification (the SDK has `VNClassifyImageRequest`)
  turns photos into searchable words ("beach", "receipt", "dog"), next to the text already
  recognized in images. A setting beside OCR; decide whether labels share the content index or
  get their own column.
- **Shortcuts actions.** App Intents for "Search Moria" and "Open search in Moria", on top of
  the `moria://` links and `SearchEngine`.

## Significant

- **External and removable volumes.** Roots on other volumes can be added, but from the code:
  the FSEvents resume point is stored and checked only for the first root
  (`IndexController.resumableEventID`), and a full scan while a volume is unmounted prunes all
  of its entries (`pruneUnseen`). Needed: a resume point per volume, entries kept and marked
  offline while their volume is away, and a volume filter.
- **Stemming beyond English.** The content index uses FTS5's Porter stemmer, which only stems
  English. Other languages (Greek included) match only exact word forms after folding. Options:
  lemmas from NaturalLanguage for the languages it supports, or per-language tokenization.
  Either way it means new FTS tables in a migration and reading all text again.
- **Duplicates.** Group files by size from the index, then hash only the candidates. Needs a
  hash column (migration), must skip cloud-only files (`MaterializationGuard`), and a place in
  the UI (a collection or a mode).
- **Media and document metadata.** Date taken, camera and location for photos; duration for
  audio and video; author for documents. New filters (`taken:`, `duration:`, …) and criteria.
  Migration for the new columns.
- **Tests for the app layer.** Only `MoriaCore` has tests. `SearchModel` (search modes,
  hand-offs, selection, Trash) has none, and several recent fixes were in that logic.

## Major

- **Distribution.** Signing with a Developer ID already works through `SIGN_IDENTITY`, and
  the hardened runtime is on. Still missing: secure timestamps (`package_app.sh` passes
  `--timestamp=none`, which notarization rejects), notarization and stapling, a disk image, an
  update mechanism, and release versioning beyond `version.env`.
- **Answers from files.** Ask a question and get an answer with the files it came from. As
  `rejected-ideas.md` notes, the fit is a custom Foundation Models tool over `SearchEngine`
  that retrieves passages (Meaning's chunks) and cites them. The on-device context window limits
  how much can be passed in.
- **Spoken words in recordings.** Transcribe audio and video on-device (the Speech framework's
  `SpeechAnalyzer` is in the SDK) so voice memos, meetings and videos are searchable, with
  timestamps to jump to. Opt-in and throttled: transcription is far heavier than text
  extraction. Transcripts are stored like PDF and OCR text (`doc_text`), for snippets and
  timestamps.
