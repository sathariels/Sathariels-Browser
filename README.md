# Sathariels Browser

Sathariels Browser is a small macOS browser: Swift, SwiftUI, and `WKWebView`. It is meant to stay usable as a daily driver while keeping fewer web processes alive than Chrome.

It builds to a normal `Sathariels Browser.app` (bundle id `com.sathariels.browser`). Drag that app to `/Applications` and launch it from the Dock or Spotlight. You do not have to keep Xcode running.

## Requirements

- macOS 14 or later
- Xcode 16 or later (the project format is the classic `objectVersion = 56` pbxproj, so a current Xcode can open it)
- No third-party packages. WebKit, AppKit, SwiftUI, AuthenticationServices, CryptoKit, and the Security framework are all system frameworks.

## Build and install

From the repo root, on a Mac:

```bash
./scripts/build-app.sh
```

That runs `xcodebuild` in Release, ad-hoc signs the app with `Lumen/SatharielsBrowser.entitlements`, and writes:

- `dist/Sathariels Browser.app`
- `dist/Sathariels Browser-macos.zip`
- `dist/Sathariels Browser.dmg`

Drag `Sathariels Browser.app` into `/Applications`.

The signature is ad-hoc (`codesign --sign -`). It is enough to run on the machine that built it. Gatekeeper does not treat it like a Developer ID app. The first time you open it outside Xcode:

1. Right-click `Sathariels Browser.app` and choose **Open**.
2. Confirm **Open** in the dialog.
3. If macOS only offers Move to Trash, open **System Settings → Privacy & Security** and choose **Open Anyway**, then try again.

You can also open `SatharielsBrowser.xcodeproj` and press Run. The target is already set to ad-hoc signing with an empty team, so a personal development team is optional for local use. To distribute beyond this Mac, switch the target to your Developer ID team in Signing & Capabilities.

Unit tests (address bar, frecency, Google block detection, session coding):

```bash
xcodebuild -project SatharielsBrowser.xcodeproj -scheme SatharielsBrowser -destination 'platform=macOS' test
```

This tree was written on Linux, where `xcodebuild` is not available, so the compile has not been executed in this environment. Open it in Xcode on a Mac, or run the script above, before you trust a binary.

## Layout

```
┌─────────────┬──────────────────────────────┬────────────┐
│ SATHARIELS       │  ← → ↻   omnibox    ★  ⓘ    │ GROK       │
│ Tabs Marks  │  find bar, when open         │            │
│ tab rows    │                              │            │
│             │  one pane, or two side by    │            │
│ CLIPBOARD   │  side with a draggable split │            │
│             │                              │            │
│ Grok Bot    │  downloads, when open        │            │
└─────────────┴──────────────────────────────┴────────────┘
```

The chrome is dark, square, and flat (0px corner radius, 1px borders). A short set of accents marks tabs, clipboard, history, and Grok. It does not follow a light system appearance.

## Why it uses less RAM

Chrome keeps a renderer process for each tab (and often for each extension) until you close the tab. Sathariels Browser's UI is one small SwiftUI process. Web content lives in WebKit, and only while a tab is actually awake.

- A new tab is a native start page. It does not create a `WKWebView` until you navigate.
- Restored tabs are created suspended. Only the focused pane is woken.
- After N minutes idle (10 by default), a background tab — including the split pane you are not using — drops its `WKWebView`. The tab keeps its URL, title, and favicon. Focusing it loads the page again.
- Closed tabs release the web view immediately. Nothing keeps a cache of old web views.
- Ordinary windows share one `WKProcessPool`. Apple deprecated that type because modern WebKit already shares a process pool; setting one instance keeps the intent obvious, including on older systems. Each private window gets its own pool and a non-persistent data store, and both are released when the window closes.
- The ad/tracker list blocks heavy third-party frames before they allocate their own DOM and scripts. It is a small list, not a full uBlock replacement.
- There is no extension process.
- The Grok panel, download list UI, settings sections, and clipboard thumbnails are created when you open them. Clipboard images are 48px JPEG thumbnails on disk, and only a few decoded images stay in an `NSCache`.
- A memory-pressure source (`DispatchSourceMemoryPressure`) suspends every tab except the focused pane, drops thumbnail cache, and trims the chat transcript.

A single heavy page (Figma, a large docs tab, YouTube) will still use a lot of memory. That cost is the page. Sathariels Browser wins when many tabs are open and most of them are idle, which is the usual shape of a browsing session.

The per-tab figure is honest about its source:

- **asleep** means the web view is gone.
- If exactly one web view is alive, Sathariels Browser attributes the resident size of child `WebContent` processes (`proc_pidinfo`) to that tab.
- If several are alive, WebKit does not expose which process belongs to which tab. The label then shows a `~` estimate from resource transfer size and DOM node count. Private WebKit memory SPI is not used.

## Memory: compare with Chrome

1. Quit Chrome and Sathariels Browser. In Activity Monitor, choose **View → All Processes, Hierarchically** and show **Real Memory**.
2. Open the same set of pages in Chrome, one window, several tabs. Wait until they finish loading. Sum **Google Chrome** plus every **Google Chrome Helper**.
3. Open the same pages in Sathariels Browser. Sum **Sathariels Browser**, **com.apple.WebKit.WebContent**, **com.apple.WebKit.Networking**, and **com.apple.WebKit.GPU**.
4. Leave Sathariels Browser in the background, or set **Settings → Memory** to 1 minute, and wait. The WebContent rows for asleep tabs should disappear. Chrome's helpers for those same tabs usually stay.
5. Optional: open the same two pages side by side with **Cmd-\\**, click one pane, and wait. The idle pane should flip to **Asleep** and its web process should go away. Click **Wake** and it comes back.

The status bar shows the measured WebKit total when `proc_pidinfo` can see the child processes. Sandbox or OS changes can make that read fail; the UI then falls back to the estimate.

## Architecture

| Piece | Role |
| --- | --- |
| `BrowserSession` | One window: tabs, split, suspension, session snapshot |
| `BrowserTab` | URL, title, favicon, and at most one `WKWebView` |
| `WebKitFactory` | Configurations: shared or private data store, process pool, content rules, page scripts |
| `TabWebDelegate` | Navigation, downloads, popups, media permission, JS dialogs, password messages |
| `HistoryStore` / `BookmarkStore` | JSON in Application Support |
| `Omnibox` | Frecency index over short strings, capped suggestions |
| `ClipboardStore` | Pasteboard poll, thumbnail files, concealed/transient skip |
| `PasswordVault` | Internet passwords in the Keychain only |
| `PermissionStore` | Per-host allow / ask / deny |
| `DownloadController` | `WKDownload` metadata. File bytes stay on disk |
| `ContentBlocker` | `WKContentRuleList` compiled from `blocker-rules.json` |
| `XAIGrokProvider` | Streaming chat completions |
| `GrokBotProvider` | Stub. No network |

`SessionStore` writes `session.json` atomically about 300ms after a change, and again on quit. A crash keeps the last successful write. Tabs come back suspended; the focused pane loads. Private windows are not in the file.

## Omnibox

The address bar shows the best frecency match as grey ghost text after the caret, in the style of a code editor. The suggestion is not part of the field until you accept it. Typing `asu` can ghost `rascans.com` so the line reads `asurascans.com`.

- **Tab** or **Right arrow** accepts the ghost text.
- **Delete** dismisses the ghost and leaves what you typed.
- **Enter** goes to the text you see, including the ghost.
- **Enter** opens the field text, or the highlighted row.
- The menu lists history, bookmarks, and open tabs (capped), plus a search row for the current engine.
- Ranking is visit count times a recency weight (1 day, 7 days, 30 days, older). The lookup is a scan of a flat array capped at 1,500 history rows. It does not keep page bodies.
- Private windows do not record visits and do not suggest history. Bookmarks and that window's open tabs still appear.
- **AI ghost text** is off until you turn it on in Settings and save an xAI key. After you pause typing (about half a second), Grok may replace the history ghost with its own continuation. The request sends the prefix and up to eight host names, not page contents. Private windows never send it. If the key is missing or the reply does not continue the prefix, the history ghost stays.

Page fields have a separate opt-in. When it is on, ordinary text inputs and text areas show the same kind of grey suggestion after a short pause, and Tab inserts it. Password fields, hidden fields, and private windows are skipped. The script posts only the field label and the text you already typed. It is not installed until the setting is on, so idle tabs do not carry it.

Default search is DuckDuckGo. Google and Bing are in Settings.

## Google sign-in

Embedded `WKWebView`s often fail Google sign-in because the default user agent omits Safari's `Version/x Safari/605` token, and because OAuth depends on `window.open` plus cookies.

Sathariels Browser does four things:

1. **Safari user agent.** It reads `Safari.app`'s marketing version when the sandbox allows it, and otherwise uses `Version/26.1`. The string is the normal desktop Safari shape. The app name is not appended. `applicationNameForUserAgent` is left unset.
2. **Real popups.** `WKUIDelegate.createWebViewWith` returns a new web view built with the configuration WebKit passes in, so `window.opener` stays wired. Sized windows open as auxiliary windows. Plain new tabs adopt that same configuration. `javaScriptCanOpenWindowsAutomatically` is on.
3. **Persistent cookies.** Normal windows use `WKWebsiteDataStore.default()`, so Google cookies survive relaunch and are shared across tabs. The content rules exclude `accounts.google.com`, `myaccount.google.com`, and `accounts.youtube.com`.
4. **Secure-session fallback.** If the accounts host hits a rejected URL, or the page text says the browser may not be secure, a banner offers **Secure session**. That calls `ASWebAuthenticationSession` (callback scheme `sathariels`).

The fallback is an escape hatch, not a cookie transplant. The system session uses Safari's cookie jar. There is no public API to copy those cookies into `WKWebView`. It completes only if the provider redirects to `sathariels://`. Signing in to Gmail or YouTube inside Sathariels Browser depends on the user agent, the popup, and the shared data store.

The password bridge (`window.webkit.messageHandlers`) is registered only on normal windows, because an empty WebKit JS bridge is one of the signals Google uses. Private windows do not install it.

### How to test Google sign-in

1. Open a page that prints the user agent (or `https://httpbin.org/user-agent`). It should contain `Version/` and `Safari/` and should not contain `Sathariels Browser`.
2. Go to `https://accounts.google.com` and sign in. You should get Google's real form, not "This browser or app may not be secure".
3. Quit, relaunch, open `https://mail.google.com`. The session should still be there.
4. On a site with **Sign in with Google**, the click should open a Sathariels Browser popup, not a dead click. Finish the flow. The popup should close and the site should be signed in.
5. If the rejection page appears anyway, use **Secure session** and read the limitation above. Turning the content blocker off is the other thing to try.

## Passwords

`WKWebView` does not offer Safari's iCloud Passwords fill for arbitrary sites. Associated domains are intentionally not used; that API only returns credentials for domains the app has claimed.

What Sathariels Browser does instead:

- If this OS still responds to WebKit's private `_setPasswordAutoFillEnabled:`, it turns that on. A missing selector is ignored. This is best-effort and not a promise that iCloud Passwords will appear in page fields.
- A page script watches main-frame login submits and asks **Save password for host?** The password is passed to `SecItemAdd` as an internet password (`kSecClassInternetPassword`) and then dropped. It is never written to JSON, UserDefaults, history, or the log.
- Items are saved synchronizable when the Keychain accepts that, so they can join iCloud Keychain. If sync is refused, Sathariels Browser retries as a local item.
- On a later visit, if one saved account matches a visible password field, Sathariels Browser fills it. Several accounts show a banner of usernames only. Settings lists host and username and can delete an item. The password is not shown.
- Private windows do not install the save script and do not fill.

## Downloads

Navigation responses WebKit cannot display, and navigations marked `shouldPerformDownload`, become a `WKDownload`. Files are written to `~/Downloads` (the downloads-folder entitlement). The panel (**Cmd-Shift-J**) shows progress, cancel, open, and reveal in Finder. The panel view is created only while it is open. Finished rows are metadata; the bytes stay in Downloads. **Clear finished** removes rows, not files. A tab with an active download is not suspended.

## Find

**Cmd-F** opens a bar on the focused pane. Matches are highlighted with the CSS Custom Highlight API (`::highlight`), capped at 400 ranges so a huge document cannot pin a giant range list. **Cmd-G** / **Enter** moves forward, **Cmd-Option-G** moves back. If CSS highlights are unavailable, it falls back to `window.find`. Closing the bar clears the highlights. Find state is not saved, and it dies with the web view when a tab sleeps.

## Private windows

**Cmd-Shift-N** opens a private window:

- `WKWebsiteDataStore.nonPersistent()` shared by tabs in that window only
- Its own `WKProcessPool`, released on close
- No history writes, no session restore, no password save or fill
- Clipboard capture is skipped while a private window is key
- Permission choices stay in memory and die with the window
- Coral header so it is obvious
- Omnibox has no history suggestions

Downloads still work. Grok chat, if you open it, stays in memory and is not written to disk.

## Permissions

Camera, microphone, notifications, location, popups, and autoplay are stored per host.

- Camera and microphone use `WKUIDelegate` `requestMediaCapturePermissionFor`. The first request prompts; the choice is remembered.
- Popups are decided inside `createWebViewWith` before the window is returned.
- Notifications and location have no equivalent public delegate on current macOS. **Deny** installs a short script that rejects `Notification.requestPermission` or `navigator.geolocation`. **Allow** leaves WebKit's own behavior, and location still needs the system prompt (the app has a location usage string and the location entitlement).
- Autoplay defaults to blocked (`mediaTypesRequiringUserActionForPlayback = .all`), which also avoids background video buffers. There is no WebKit callback for the first autoplay attempt. Change it from the site button in the address bar; the tab reloads so the new configuration applies.

The address-bar info button edits the current host. **Settings → Sites** lists every remembered host. Private windows do not write that file.

## Clipboard

The sidebar keeps recent clipboard items while a normal window is key. A timer watches `NSPasteboard.changeCount`.

- Text and URLs, capped in length and count (60 unpinned)
- Images stored as 48px JPEG thumbnails, not the original
- Click copies the item back. **Paste** tries the focused page field, otherwise the address bar
- Pin, delete, and **Clear** (pinned items stay)
- Items that carry `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` are ignored, so password-manager copies are not stored
- **Settings → Clipboard** pauses capture
- Nothing is recorded at launch until the pasteboard changes again

## Grok and Grok Bot

**Cmd-Shift-G** opens the right-hand panel the first time you ask for it. The panel is not created at launch.

The provider protocol is `AIProvider`.

- **Grok (xAI)** is the working provider. It streams `POST https://api.x.ai/v1/chat/completions` (OpenAI-compatible SSE). The default model is `grok-4.7`. Change it in Settings. The API key is typed into Settings and stored in the Keychain (`com.sathariels.browser` / `xai-api-key`). It is not in the repo, UserDefaults, or logs. The field starts empty even when a key is already saved.
- **Act** (on by default outside private windows) runs a tool loop on that same endpoint: `read_page`, `click`, `type_text`, `scroll`, `navigate`, and `new_tab`. Summaries are the model writing after `read_page`, not a separate tool. Each step is a line in the transcript. **Stop** cancels the loop and any confirmation that is waiting.
- Before a click that submits, pays, sends, or signs in, and before typing into a password, card, or one-time-code field, the panel asks **Allow** or **Deny**. Password values are never read. Search buttons are not treated as purchases.
- The agent script is injected only when a tool runs, not at launch. Page text sent back to the model is capped, and the tool transcript is trimmed with the rest of the chat.
- Private windows leave **Act** off unless **Settings → Grok → Allow the agent in private windows** is on.
- **Page** (with Act off) attaches the focused page's title, URL, selection, and a truncated `innerText` to that one request. The transcript stores your question, not a second copy of the page. With Act on, the model reads the page through the tool instead.
- **Grok Bot** is a separate desktop assistant. It does not have a public HTTP API that this project can call. `GrokBotProvider` is a stub with a TODO. Selecting it in the panel explains that and does not send a request. The sidebar **Grok Bot** button opens a configurable URL, default `grokbot://`. **Send page to bot** copies the title, URL, and selection (or a short text excerpt) to the clipboard, then opens that URL. Whether Grok Bot reads the clipboard is up to Grok Bot. Sathariels Browser does not invent a protocol for it.

## Content blocker

`WKContentRuleListStore` compiles `Lumen/Resources/blocker-rules.json` (about 50 ad and tracker domains). The identifier includes a hash of the file, so edits recompile. Rules do not run on Google and YouTube account hosts. Toggle it in Settings; live tabs are rebuilt so the rule list is on the configuration.

## Session restore

Regular windows save tab order, URLs, titles, color tags, the active pane, the split partner, the divider fraction, and the sidebar width. After a crash or a normal quit, those windows come back. Suspended tabs do not load until focused. The inactive split pane stays asleep until you click it. Private windows are omitted. Turn restore off in Settings to delete the file and stop writing it.

## Inspector, JSON, localhost, responsive

**Inspect Element** is on for every web view (`isInspectable` on macOS 13.3+, and `developerExtrasEnabled`). Right-click a page and choose Inspect Element. **Cmd-Opt-I** asks WebKit to show the inspector when that private hook exists.

**JSON.** A main-frame response whose type contains `json`, or whose URL ends in `.json`, is not handed to the web view. Sathariels Browser fetches it (with the tab’s cookies) and shows a collapsible tree: amber keys, teal strings, sky numbers, violet booleans. Raw toggles back to the text. Path and Value copy that node. Documents over about 1.2 MB are refused instead of being parsed. A `text/plain` body that starts with `{` or `[` is sniffed after load and shown the same way. The tree view is created only for that response.

**Local.** The tab list has a Local section. It does not scan until you press Scan. The usual dev ports (3000, 5173, 8080, and a few neighbors) are probed a few at a time. Click a row to open it. **Reload** watches only the focused `localhost` or `127.0.0.1` tab, and only if you turn it on. A restart (the port was down, then answers) or a changed `ETag` / `Last-Modified` reloads that tab.

**Responsive.** The phone button in the address bar frames the current tab as iPhone (390×844), iPad (820×1180), or a custom size. Mobile UA swaps in an iPhone Safari string and reloads once. Full width uses the desktop Safari string again. Nothing about this is loaded until you open the bar.

## Address keywords

These run before search, and only when the first word matches:

| Type | Opens |
| --- | --- |
| `gh owner/repo` | `https://github.com/owner/repo` |
| `gh query` | GitHub search |
| `yt query` | YouTube search |
| `lc query` | LeetCode problem search |

Settings → Grok → Keywords can override any of those, or add new ones. Put `{query}` in the URL template. The rest of the line is percent-encoded.

## Copy as Markdown

**Cmd-Opt-M** (also the menu item Copy Page as Markdown) reads `article`, `main`, or the body, skips scripts and styles, and copies a short Markdown version. The pasteboard change shows up in the clipboard list, trimmed to 16,000 characters there. The copy itself is not kept in a web view.

## Keyboard

| Shortcut | Action |
| --- | --- |
| Cmd-T | New tab |
| Cmd-N | New window |
| Cmd-Shift-N | Private window |
| Cmd-W | Close tab |
| Cmd-L | Address bar |
| Cmd-R | Reload |
| Cmd-[ / Cmd-] | Back / forward |
| Cmd-F | Find |
| Cmd-G | Find next |
| Cmd-Option-G | Find previous |
| Cmd-Shift-G | Grok panel |
| Cmd-Shift-J | Downloads |
| Cmd-Shift-B | Sidebar |
| Cmd-\\ | Split / close split |
| Cmd-Option-\\ | Swap split panes |
| Cmd-Opt-I | Web inspector |
| Cmd-Opt-M | Copy page as Markdown |
| Cmd-1 … Cmd-9 | Select tab |

Tab context menus can also open a tab in the split, recolor it, or copy its URL.

## Roadmap

These are not implemented, on purpose:

- Reading Safari's saved passwords directly. There is no public API for that without associated domains, and associated domains cannot cover the whole web.
- An official Grok Bot chat API. The stub stays until one is published.
- Extensions, reader mode, and sync.

## Project map

```
SatharielsBrowser.xcodeproj
Lumen/                 app sources, Info.plist, entitlements, assets, blocker rules
LumenTests/            XCTest for the pure pieces
scripts/build-app.sh   Release .app, zip, and DMG
scripts/generate_project.py
```

`generate_project.py` rewrites the Xcode project, the app icon, and the rule list from the tree. Run it after adding a Swift file, then commit the regenerated `project.pbxproj`.
