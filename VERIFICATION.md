# October 28 refinements

Pulled `origin/main` to `7912c61` before editing, preserving the updated blue flower and the user's UI work. No bookmarks-bar feature was added.

## Interface

- Downloads now uses a toolbar-anchored native popover, with a close control, Escape dismissal, and click-away dismissal. Rounded file rows, blue progress, readable status, and Open / Finder actions replace the cramped overlay. Clear finished preserves paused and failed transfers, and incomplete files cannot be opened through the controller.
- The left rail and sidebar controls use the existing flower's blue accent. The AI icon is a native conversation symbol. X, Google, and Canvas use bundled SVG brand marks; attribution is in `design/sidebar-icons.md`.
- The account menu says Manage Google account and Switch or add Google account. It does not infer authentication state or inspect account cookies. Existing Google sessions are unchanged.
- Rounded tab outlines, reserved close-button space, a minimum readable width, a stable scrolling layout, and an always-visible new-tab button replace the abrupt compressed layout. Active tabs scroll into view without animated reflow.
- Find now requests focus on its initial appearance.

## Security hardening and review scope

- Saved-password selection requires an explicit browser action. It only accepts HTTPS on port 443, rechecks the exact approved URL and web view after device authentication, and checks the document URL again inside an isolated JavaScript world. HTTP and other ports do not receive these existing HTTPS vault entries.
- Password-save messages require a matching secure main-frame origin. Keychain read/delete/replacement queries are scoped to this browser's labeled HTTPS entries, avoiding deletion of another app's matching credentials.
- Popup permission is attributed to the initiating frame's origin, rather than the destination URL. Threat-list checks also run on POST/form navigations before any URL rewriting logic.
- The app retains App Sandbox, WebKit's default TLS validation, HTTPS upgrade and threat/blocker features. A real local test download had `com.apple.quarantine` metadata.

This is a targeted source review and regression check, not a penetration test or a guarantee against compromise. No real credentials were accessed. Live Touch ID/Keychain filling was not exercised with a user's account. Broader existing limitations remain: local threat lists cannot detect every malicious site; the AI agent's page-action approval heuristics and external content deserve a separate adversarial audit; release signing/notarization and update trust were not independently certified. Keep macOS/WebKit updated.

## Validation

- 36 tests passed, 0 failed, 0 skipped. The older tab-budget test now explicitly selects Aggressive mode and restores the previous preference, since Smart mode intentionally has a different policy.
- Debug and Release builds passed on Xcode 16.1 / macOS 26.2. Existing Swift concurrency warnings in AI code remain.
- Added a compiler guard for the upstream macOS 15.4 Web Extension APIs: this local older-SDK build omits extension loading; Xcode 16.3+ builds retain that path. The newer-SDK path was not compiled here.
- Visually inspected wide and narrow windows, blue rail, brand icons, crowded tabs, and active-tab visibility. Confirmed Downloads dismisses with Escape, an address-bar click, and physical clicks on both the native home and actual web content. A local file completed and displayed its Open file / Show in Finder controls. Pause/resume across app restarts was not exercised.
- Confirmed the account menu wording without signing into or changing any account.

The following section records the earlier October 27 redesign and is historical; newer behavior above and the pulled Smart tab-sleep policy supersede it.

---

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
