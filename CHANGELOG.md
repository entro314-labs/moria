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
- Mac app: search modes (Everything, Names, Contents, Regex, Ask), a filter bar with editable chips and kind facets, a home screen of recently changed files and collections, saved searches, sortable results that show why each file matched, a preview/info inspector with match navigation, a ⌘K action palette, and a glass quick-search panel on a global shortcut.
- Full menus and shortcuts, Open With, Move to Trash, Export Results (CSV), Services for text and Finder folders, `moria://` links, Dock and menu bar menus, Help window, pause/rescan/rebuild indexing, and settings for locations, contents, intelligence and the index.
- Power searching: a criteria builder (⇧⌘F) with name, extension, contents, kind, path, folder, size, date, hidden and cloud criteria that round-trips to query text; name operators (`name:foo*`, `name:*foo`, `name:=foo`, `name:/regex/`), `path:` and `-ext:`; a regex builder (⌥⌘R) with building blocks, common patterns, live testing and explanations; saved searches (including regex) that can be edited, renamed, duplicated and reordered; sorting by any column including Where, Extension and Created.
- `moria` command-line tool sharing the app's index: `index`, `watch`, `search` (`--regex`, `--semantic`, `--ask`, `--json`, `--show`), `stats`, `config`.
- Undo (⌘Z) for Move to Trash puts the files back where they were and back in the index.
- VoiceOver reads quick search and action palette rows as buttons, announces the row the arrow keys select, and opens or runs it on activation.
- Folders added to the sidebar with Choose Folder… are kept across windows and launches; Locations have a context menu (Show in Finder, Remove from Sidebar).
- Choose Folder… opens as a sheet on its window instead of blocking the whole app.
