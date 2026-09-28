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
- Reduce Motion: the action palette fades in and match stepping jumps instead of scrolling. Increase Contrast: filter chips and match labels get a stronger fill and a solid outline.
- The Delete key removes the selected saved search, and ⌘Z brings a deleted saved search back.
- Edit › Next Match and Previous Match (⌘G / ⇧⌘G) step through the matching lines in the preview.
- Dropping a folder from Finder on a Moria window searches inside it.
- Find Similar (with Meaning on): `similar:<file>` lists the documents closest in meaning to a file, narrowed by any filters or words; in the File menu, the action palette and result context menus, and in the CLI.
- `moria mcp`: a Model Context Protocol server (stdio) with read-only `search`, `regex_search` and `index_status` tools for local AI agents.
- Finder tags: `tag:red,"Needs Review"` and `-tag:done` filters, a Tags criterion, an optional Tags column, tags in the preview info, and tag suggestions. Tags are read where contents are read and follow changes live; an existing index is rescanned once to pick them up.
- Greek and Russian stemming: a word finds its other forms in names, contents, exclusions and highlighted excerpts (“αποδείξεις” finds “απόδειξη”), without re-indexing.
- External drives and network volumes: an ejected location keeps its entries (shown as Offline, with a note in the sidebar and preview) instead of being deleted, files waiting to be read wait for the drive, and a returning drive is read again. The resume point is checked per location rather than only for the first.
- Photo, audio and document details: `taken:` (EXIF date taken), `duration:>10m` (audio and video length) and `author:` (PDF and Office authors), with criteria, optional Date Taken, Duration and Author columns, and rows in the preview info. Existing indexes read the details in the background.
- Photos are found by what they show: words like “beach”, “document” or “dog” match Vision’s high-precision labels for a photo (“In picture”, with the labels as the excerpt). On by default beside text recognition (Settings › Contents, `imageLabels`); existing photos are read once in the background.
- Duplicates: `duplicates:yes` lists identical files in groups (most space wasted first, “N copies” on each), narrowed by any filters or words; a Duplicates collection covers files over 1 MB outside Library. Files are compared by size, then the first 64 KB, then in full, and hashes are kept for the next search. Hard links count once; cloud-only files are never read.
- Shortcuts actions: Search in Moria (opens a search) and Find Files with Moria (returns matching files to the next action without showing Moria), both using the query syntax, with Spotlight phrases.
- Upgrading an existing index: the first launch applies four schema migrations (about 6 seconds on a 4-million-entry index, before the window appears), then rescans every location once to read Finder tags, then reads photo, audio and document details and photo labels in the background (on the order of an hour for tens of thousands of photos).
- A file that keeps changing while it waits to be read (an active log, or the index’s own files inside an indexed folder) is given up on after three tries instead of being read again forever; it is tried again when it next changes.
- Updates through Sparkle: Moria › Check for Updates…, automatic checks (asked at the second launch; Settings › General), and releases published on GitHub as notarized disk images.
