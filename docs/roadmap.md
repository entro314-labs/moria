# Roadmap

Work worth doing, grouped by size, smallest first. The tiers describe scope, not order or
schedule. Read with `rejected-ideas.md`: nothing turned down there belongs here without new
reasons.

Anything that stores new data in the index needs a new migration (`v4`, …); applied migrations
are never edited.

## Small

- **One transaction for a settings change.** `IndexController.updateSettings` saves the
  settings and clears the FSEvents resume point in two writes; a crash between them keeps new
  crawl rules with an old resume point until the next full scan. One `pool.write` for both.
- **Rescan Now while paused.** The scan is queued until indexing resumes, and nothing says so.
- **Failures behind `try?`.** Stats, sidebar counts and excerpts vanish silently on a database
  error (`AppModel.refreshStats`, `SearchModel.loadHome`, `requestDetails`); report them in
  `app.lastError` like the other app failures.
- **Sidebar counts.** `loadHome` counts each collection and saved search by fetching up to
  1000 full rows; measure on a large index before changing it, since the badge caps at 999+.

## Significant

- **Tests for the app layer.** `MoriaAppTests` covers Trash undo, saved searches, sidebar
  folders, folder drops, the Find Files action, Stop Search and query building (modes and
  filters); `SearchModel`'s hand-offs between the quick panel, builders and windows, and its
  selection, still have none.

## Major

- **Answers from files.** Ask a question and get an answer with the files it came from. As
  `rejected-ideas.md` notes, the fit is a custom Foundation Models tool over `SearchEngine`
  that retrieves passages (Meaning's chunks) and cites them. The on-device context window limits
  how much can be passed in.
- **Spoken words in recordings.** Transcribe audio and video on-device (the Speech framework's
  `SpeechAnalyzer` is in the SDK) so voice memos, meetings and videos are searchable, with
  timestamps to jump to. Opt-in and throttled: transcription is far heavier than text
  extraction. Transcripts are stored like PDF and OCR text (`doc_text`), for snippets and
  timestamps.
