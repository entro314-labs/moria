# Rejected ideas

Reviewed and turned down, so they aren't proposed again without new reasons.

## swift-subprocess dependency

Swift 6.4 made `swift-subprocess` 1.0 stable, and it could replace `ProcessRunner` and the
`Process` handling in `RegexSearcher`. Rejected: it adds a dependency to replace about 90 lines
that work. The one real problem in that code (waiting for exit with `waitUntilExit()`, which could
hang) is fixed in place with termination handlers.

## Merging the ⌥⌘F and ⌘L menu items

"Search" (⌥⌘F) and "Go to Search Field" (⌘L) do the same thing. Rejected: both shortcuts are
deliberate (⌥⌘F as in Finder, ⌘L as in browsers and Spotlight-style apps), and a second menu item
is the way to offer two shortcuts for one action.

## Apple's Spotlight search tool for Foundation Models

A Core Spotlight–backed local search tool for the on-device model was mentioned in a WWDC26
session. Rejected: the only source is a session summary, not the documentation, and Moria doesn't
need it. Ask turns a request into filters over Moria's own index, which already searches what
Spotlight skips.
