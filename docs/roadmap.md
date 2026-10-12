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

Both items here were built on 2026-10-12: Answer mode (`Answerer`) and transcription
(`Transcriber`). What they leave open:

- **Answers over more than six passages.** The on-device window caps what the model sees; a
  second pass that asks the model to pick passages, or a larger model when Apple offers one,
  would let long documents be answered from more than their densest 600 characters.
- **Transcription in more than one language.** `SpeechAnalyzer` takes one locale per pass;
  recordings in another language than the system's come out as noise. Detecting the language
  first (a short pass with each installed locale) would fix it at the cost of time.
