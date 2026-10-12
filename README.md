# Moria

Deep search for macOS: every file name, the text inside documents, PDFs, code and images, regular expressions, and (optionally) meaning — from its own index, so it finds what Spotlight skips.

- **Updates itself** — through Sparkle, from GitHub Releases; turn automatic checks off in Settings.
- **Everything by name** — every file and folder under your locations, including hidden files, app data and cloud folders. Cloud-only files are indexed by name and never downloaded.
- **Contents** — plain text and code, PDFs (scanned pages via text recognition), Word, RTF, OpenDocument, PowerPoint, Excel, EPUB, HTML, email files, and text in screenshots and photos. Photos are also found by what they show (“beach”, “document”), recognized on this Mac. Accent- and case-insensitive in every script, with English, Greek and Russian stemming (a search for one form of a word finds the others).
- **Spoken words** (optional) — speech in audio and video files, transcribed on this Mac, with the time each line was said at.
- **Regex** over names, contents and extracted document text (bundled ripgrep).
- **Live** — follows filesystem events and catches up on changes made while it wasn't running.
- **External drives** — locations on external drives and network volumes stay searchable while ejected (marked Offline) and are read again when they return.
- **Ask** (optional) — plain-language requests turned into editable filters by Apple's on-device model.
- **Answer** (optional) — a question such as “what does the lease say about pets?” answered from the text of your files by the on-device model, with the files it drew on cited and previewable.
- **Meaning** (optional) — finds documents related to your words, with the closest passage, using on-device embeddings; **Find Similar** lists the documents closest to a selected one.

## Using it

- The search field is at the top. Results show why they matched (Name, Contents · N, Text in image, Meaning) with a highlighted excerpt.
- The bar under it holds the search **mode** (Everything, Names, Contents, Regex, Ask, Answer — ⌘1…⌘6), **+ Filter** menus, the active filters as chips, and one-click kind facets with counts.
- The sidebar has **Home** (recently changed files), **Collections** (Recent Documents, Downloads, Screenshots, PDFs, Images, Recent Code, Large Files, Duplicates), **Saved Searches** (⌘S) and **Locations**.
- The inspector shows the Quick Look preview, the info, or both, with every matching line (⌘G / ⇧⌘G to step through).
- **Criteria builder** (⇧⌘F) builds detailed searches row by row, HoudahSpot-style; **Regex builder** (⌥⌘R) composes and tests patterns. Both produce ordinary query text you can save.
- Results learn: what you open for a search comes first next time, and a search that names an app lists the app first, as in Spotlight.
- **⌃⌥Space** opens quick search from anywhere; **⌘K** lists actions for the selection; Space is Quick Look, ⌘R shows in Finder.
- Query syntax (also under the **?** button and Help › Moria Help):

```
invoice "rent receipt" -draft          words, phrase, exclusion
name:report  content:lease             only names / only contents
name:IMG*  name:*.draft  name:=README  name begins / ends / is
name:/^IMG_\d{4}$/  path:invoices      name regex, path contains
ext:pdf,docx  kind:image  -kind:folder file types
size:>10mb  size:1mb..5mb              size
modified:<7d  modified:2026-03..2026-05  created:2025
taken:2024-07  duration:>10m  author:smith   photos, recordings, documents
in:~/Documents  -in:~/Library          folders
tag:red,"Needs Review"  -tag:done      Finder tags
hidden:no  cloud:no
duplicates:yes size:>1mb               identical files, grouped
similar:~/Documents/lease.pdf          documents close in meaning (Meaning on)
```

## Command line

`Moria.app/Contents/Resources/moria` shares the app's index:

```
moria search "lease agreement" --json
moria search --regex 'INV-\d{4}-\d+' --filters "ext:pdf in:~/Documents"
moria search --ask "pdf invoices from last spring"
moria search --answer "what does the lease say about pets?"
moria search "budget" --show          # open the results in the app
moria index | watch | stats | config --set semanticSearchEnabled=true transcribeRecordings=true
moria mcp                              # Model Context Protocol server for AI agents (stdio)
```

`moria mcp` gives local AI agents (Claude, Cursor, …) read-only tools over the index: `search` (the query syntax, with names/contents modes and meaning), `regex_search` and `index_status`. Register it as a stdio server with the command `/Applications/Moria.app/Contents/Resources/moria` and the argument `mcp`.

Shortcuts has two actions: **Search in Moria** (opens a search) and **Find Files with Moria** (returns matching files to the next action). Links work too: `moria://search?q=invoice%20ext:pdf&scope=contents` (add `&mode=answer` or `&mode=ask`). Services › Search with Moria works on selected text and on Finder folders, and dropping a folder on a Moria window searches inside it.

## Privacy and footprint

Everything is indexed and searched on this Mac. Allow **Full Disk Access** (System Settings › Privacy & Security) so Moria can see Mail, Messages and other protected data.

The index lives in `~/Library/Application Support/Moria/index.sqlite`. Names cost roughly 250 bytes per file; extracted text about a quarter of its raw size (the text itself is not stored, except for PDFs, Office files, recognized text and transcripts). Settings › Contents controls which folders are read for text: by default `~/Library`, hidden folders and dependency/build folders are indexed by name only. Symbolic links are indexed by name; their targets are read where they are. Changing what is read keeps existing text searchable until each file is read again. Transcription of audio and video is off by default: it runs one recording at a time in the system language, after everything else is read.

## Building

Requires macOS 26 and Xcode 27 (Swift 6.4).

```
swift build && swift test
Scripts/package_app.sh      # build/Moria.app, signed with your Apple Development identity
open build/Moria.app
```

Releases are notarized disk images on [GitHub Releases](https://github.com/entro314-labs/moria/releases); installed copies update themselves through [Sparkle](https://sparkle-project.org) (Moria › Check for Updates…).

```
xcrun notarytool store-credentials moria --apple-id <apple id> --team-id <team id>   # once
DRY_RUN=1 Scripts/release.sh 0.2.0   # build the disk image and update feed; changes nothing
Scripts/release.sh 0.2.0             # notarize, commit, tag, push and publish v0.2.0
```

The release notes are the changelog's Unreleased section. Updates are signed with a key kept in the login keychain (account `moria`); back it up with `build/cache/sparkle-*/bin/generate_keys --account moria -x <file>` and keep the file private: without it no update can be published to existing installs.

See `AGENTS.md` for the architecture.
