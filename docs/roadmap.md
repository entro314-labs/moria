# Roadmap

Work worth doing, grouped by size, smallest first. The tiers describe scope, not order or
schedule. Read with `rejected-ideas.md`: nothing turned down there belongs here without new
reasons.

Anything that stores new data in the index needs a new migration (`v4`, …); applied migrations
are never edited.

## Significant

- **Tests for the app layer.** `MoriaAppTests` covers Trash undo, saved searches, sidebar
  folders, folder drops, the Find Files action, Stop Search, query building (modes and
  filters) and the model side of the hand-offs (requests, saved searches, Find Similar, the
  sidebar, chips); the views' side of them (builder buttons, the quick panel's ⌘O) and the
  selection still have none.

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
