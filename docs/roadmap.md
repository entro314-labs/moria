# Roadmap

Work worth doing, grouped by size, smallest first. The tiers describe scope, not order or
schedule. Read with `rejected-ideas.md`: nothing turned down there belongs here without new
reasons.

Anything that stores new data in the index needs a new migration (`v4`, …); applied migrations
are never edited.

## Fixes

Defects found in a review against Apple's macOS guidelines. They come before new work.

- **Undo Move to Trash.** `SearchModel.moveSelectionToTrash` gets back where each file went but
  registers no undo, so ⌘Z doesn't put files back as it does in Finder. Undo moves each file
  back and re-applies it to the index, the same way trashing removes it.
- **Quick search and action palette rows for VoiceOver.** Rows in `QuickPanel.swift` and
  `ActionPalette` (`FilterBar.swift`) are tap gestures on plain views: VoiceOver sees no
  buttons, and moving the selection with the arrow keys announces nothing.
- **Chosen sidebar folders are lost.** "Choose Folder…" in `SidebarView` keeps folders in view
  state: they vanish when the window closes or the app quits, and can't be removed.

## Polish

- **Reduce Motion.** The action palette scales in (`MainView`) and match stepping scrolls with
  animation (`InspectorView`); both should fade or jump when Reduce Motion is on.
- **Increase Contrast.** Filter chips (14% tint, 25% dashed border) and match labels (14%
  capsules in `ResultsTable` and `InspectorView`) need stronger variants when Increase Contrast
  is on.
- **Context menus on Locations.** Location rows have none: Show in Finder, and Remove for
  chosen folders.
- **Saved searches: Delete key and undo.** Deleting is permanent and only reachable from the
  context menu.
- **Match stepping in the menu bar.** ⌘G / ⇧⌘G exist only as buttons in the inspector, so the
  menu bar doesn't show them.
- **Folder picker as a sheet.** "Choose Folder…" runs an app-modal open panel; attach it to the
  window.

## Nice to have

- **Drop folders onto the window.** Dragging a folder from Finder onto the sidebar or results
  searches inside it, like Services › Search in Folder with Moria does today.
- **Finder tags.** A `tag:` filter, a Tags column and a tag criterion. Needs tags stored per file
  (migration) and a check that tag changes reach the index through FSEvents.
- **More like this.** With Meaning on, find documents close to a selected result. The vectors
  are already in `VectorIndex`; this needs a search entry point that starts from a file instead
  of a query.
- **Labels for photos.** Vision's image classification (the SDK has `VNClassifyImageRequest`)
  turns photos into searchable words ("beach", "receipt", "dog"), next to the text already
  recognized in images. A setting beside OCR; decide whether labels share the content index or
  get their own column.
- **Shortcuts actions.** App Intents for "Search Moria" and "Open search in Moria", on top of
  the `moria://` links and `SearchEngine`.
- **MCP server in the CLI.** `moria mcp` serving read-only search over stdio, so local AI agents
  can query the index. The CLI already has `search --json`; this adds the protocol.

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
