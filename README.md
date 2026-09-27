# Moria

Deep search for macOS: every file name, the text inside documents, PDFs, code and images, regular expressions, and (optionally) meaning — from its own index, so it finds what Spotlight skips.

- **Everything by name** — every file and folder under your locations, including hidden files, app data and cloud folders. Cloud-only files are indexed by name and never downloaded.
- **Contents** — plain text and code, PDFs (scanned pages via text recognition), Word, RTF, OpenDocument, PowerPoint, Excel, EPUB, HTML, email files, and text in screenshots and photos. Accent- and case-insensitive in every script, with English stemming.
- **Regex** over names, contents and extracted document text (bundled ripgrep).
- **Live** — follows filesystem events and catches up on changes made while it wasn't running.
- **Ask** (optional) — plain-language requests turned into editable filters by Apple's on-device model.
- **Meaning** (optional) — finds documents related to your words, with the closest passage, using on-device embeddings.

## Using it

- The search field is at the top. Results show why they matched (Name, Contents · N, Text in image, Meaning) with a highlighted excerpt.
- The bar under it holds the search **mode** (Everything, Names, Contents, Regex, Ask — ⌘1…⌘5), **+ Filter** menus, the active filters as chips, and one-click kind facets with counts.
- The sidebar has **Home** (recently changed files), **Collections** (Recent Documents, Downloads, Screenshots, PDFs, Images, Recent Code, Large Files), **Saved Searches** (⌘S) and **Locations**.
- The inspector shows the Quick Look preview, the info, or both, with every matching line (⌘G / ⇧⌘G to step through).
- **⌃⌥Space** opens quick search from anywhere; **⌘K** lists actions for the selection; Space is Quick Look, ⌘R shows in Finder.
- Query syntax (also under the **?** button and Help › Moria Help):

```
invoice "rent receipt" -draft          words, phrase, exclusion
name:report  content:lease             only names / only contents
ext:pdf,docx  kind:image  -kind:folder file types
size:>10mb  size:1mb..5mb              size
modified:<7d  modified:2026-03..2026-05  created:2025
in:~/Documents  -in:~/Library          folders
hidden:no  cloud:no
```

## Command line

`Moria.app/Contents/Resources/moria` shares the app's index:

```
moria search "lease agreement" --json
moria search --regex 'INV-\d{4}-\d+'
moria search --ask "pdf invoices from last spring"
moria search "budget" --show          # open the results in the app
moria index | watch | stats | config --set semanticSearchEnabled=true
```

Links work too: `moria://search?q=invoice%20ext:pdf&scope=contents`. Services › Search with Moria works on selected text and on Finder folders.

## Privacy and footprint

Everything is indexed and searched on this Mac. Allow **Full Disk Access** (System Settings › Privacy & Security) so Moria can see Mail, Messages and other protected data.

The index lives in `~/Library/Application Support/Moria/index.sqlite`. Names cost roughly 250 bytes per file; extracted text about a quarter of its raw size (the text itself is not stored, except for PDFs, Office files and recognized text). Settings › Contents controls which folders are read for text: by default `~/Library`, hidden folders and dependency/build folders are indexed by name only.

## Building

Requires macOS 26 and Xcode 27 (Swift 6.4).

```
swift build && swift test
Scripts/package_app.sh      # build/Moria.app, signed with your Apple Development identity
open build/Moria.app
```

See `AGENTS.md` for the architecture.
