# Agent browser control

Agents in Naive drive a browser the way the Claude in Chrome extension does: they read the page as a structured snapshot, act on elements by ref, take screenshots and read console output. The main path is the browser already in the companion panel, so the user watches the agent work and shares its tabs and logins.

Plan: [`docs/plans/agent-browser.md`](../plans/agent-browser.md).

## Webview first, CDP as a fallback

One tool surface, two backends. Agents never know which backend answered.

| Case | Backend |
|---|---|
| App open on the agent's device | In-app webview (`ui.web` → `web:eval`, native input later) |
| App closed, or agent on a remote engine with no UI | Engine starts headless Chromium over CDP, lazily, on first browser call |
| Windows | Webview, using WebView2's built-in CDP (`CallDevToolsProtocolMethod`) for trusted input |
| Cloud | Off |

Behind a `browser-tools` feature flag, disabled for Cloud builds.

## What exists

- Browser panel = native webview: WKWebView (macOS), WebView2 (Windows), WebKitGTK (Linux). See `ARCHITECTURE.md` §Terminals & embedded browser.
- `web:eval(js, cb)` works today: `apps/zgx/ui/screens/panel/browser.luau` (find, icons).
- The engine's MCP server already gives agents Naive tools, and plugin tools already route engine → app (`crates/mcp/src/tools/plugins.rs`, `CallPluginTool`). Browser tools take the same path.
- No screenshot of a webview yet: `apps/zgx/zgx-asks/web-snapshot/ASK.md`.

## Tools (`crates/mcp`)

- `browser_tabs`: list, open, select, close
- `browser_navigate`: url, back, forward, reload
- `browser_snapshot`: accessibility-style tree with refs
- `browser_click(ref)`, `browser_type(ref, text)`, `browser_key(keys)`, `browser_scroll`
- `browser_screenshot`
- `browser_console`: recent console messages and errors
- `browser_wait`: for a selector, text or navigation

## Snapshot

Reliability depends on the snapshot. Shared injected JS walks the DOM, builds a role, name and state tree of interactive and landmark elements, and tags each with `data-naive-ref`. The same script runs in both backends (`web:eval` and CDP `Runtime.evaluate`), so refs and output match.

## Backend selection

The engine chooses per call. If a UI is connected on this device with the tab live, it uses the webview. Otherwise it uses CDP. CDP sessions are not moved into the panel when the window reopens.

The CDP backend lives in the engine (for example the `chromiumoxide` crate) and uses system Chrome or Chromium, with no download bundled. If no Chrome is found, it returns a clear error.

## Webview limits

WKWebView and WebKitGTK have no CDP. JS-dispatched events are untrusted (`isTrusted=false`), so drag-and-drop, some `isTrusted` checks, file inputs and cross-origin iframes break. Native input injection in zgx fixes this: synthesized `NSEvent` into WKWebView on macOS, and CDP `Input.dispatch*` on WebView2.

## zgx asks

- `Web:snapshot` plus image bytes to disk (existing `web-snapshot` ask)
- Native (trusted) mouse and keyboard input into a web view
- Console and navigation events from a web view (WKScriptMessageHandler or similar)

## Safety

- Visible "agent is driving" state in the panel, with a stop button.
- Per-site permission like the extension's, on top of the existing `api.allowed(url)` rules.
- No credentials or payment entry without confirmation from the user.
