# Redesign verification

The final design follows the updated brief: a black native browser, a centered code-drawn flower with no home-page modules, a compact left rail, an on-demand left AI drawer, clipboard history, Google AI Mode search, Google account entry, and X / UW–Madison Canvas shortcuts. The devil-star app icon replaces all ten macOS asset sizes.

## Functional repairs

- Address text follows tab switches; keyboard commands remain available when web content has focus.
- Local development addresses default to HTTP. Search queries and keyword shortcuts preserve reserved characters.
- Clipboard text preserves whitespace; newly captured images retain full-resolution data on disk, capped at 20 MB per image. Existing thumbnail-only records still decode. Text remains capped at 16,000 characters and unpinned history at 60 items. Capture runs while this app is active and pauses in private windows; password-manager concealed/transient items are skipped.
- Clipboard Paste falls back to the address bar when the page has no editable target.
- The content-blocker cache miss now compiles its rules; all 50 rules use WebKit-compatible patterns.
- Side-panel widths respond to window size. The home flower scales to its pane. Empty bookmarks chrome is hidden.

## Memory behavior

New tabs render natively without WKWebView, the flower has no animation timer, and the AI store is created only on demand. The default idle timeout for new installations is two minutes; existing saved preferences are preserved. A 12-second cleanup cycle targets four live web tabs per window, prioritizing the oldest background tabs. Loading tabs, downloads, playing media, and detected main-frame edits are protected during routine cleanup, so this is a soft target. Memory-pressure cleanup can still discard background state.

A macOS `footprint --noCategories` snapshot measured the running debug app's main process at 57 MB (peak 148 MB). Chrome's main process was 402 MB at that instant, but its workload was different and both values exclude helper processes. **These figures are not a controlled total-browser benchmark and do not establish a general RAM advantage over Chrome.** WebKit helpers are launchd-owned on this machine, so descendant-only process accounting cannot attribute all helpers reliably. No stronger memory claim is made.

Regression coverage verifies native empty tabs, lazy AI allocation, release/wake/close behavior, and the background-tab budget with edit protection.

## Manual validation

Inspected the dark interface and flower, opened/closed the left AI drawer, exercised localhost navigation, Back/Forward, tab switching, address entry, and Cmd-T. Google AI Mode returned an actual response from an address-bar query. Google account entry opens the official sign-in URL. The content blocker reports 50 compiled rules.

Google login completion and long-term cookie persistence require user credentials and were not completed. Live xAI streaming/agent execution requires an API key and was not exercised. The Grok Bot integration remains the upstream external-app bridge/stub. Existing Swift concurrency warnings remain in upstream AI code.

The latest test run passed all 16 tests, and the Release build and packaged app signature verification succeeded. A final manual check found that Cmd-F opens Find but may not focus its text field automatically; that remains unresolved. Clipboard paste was covered by code review but not a completed end-to-end manual check.

Build/test output is generated in `/tmp/SatharielsBrowser-Verified` to avoid Finder metadata injected into the synced Documents directory. The release script now uses a temporary build directory by default for the same reason.
