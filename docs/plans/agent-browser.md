# Agent browser control: plan

Spec: [`docs/specs/agent-browser.md`](../specs/agent-browser.md).

- [x] 1. Tool surface in `crates/mcp`, backend trait and shared snapshot JS
- [x] 2. Webview backend on macOS: snapshot, click, type and navigate through `web:eval` (demo-ready)
- [ ] 3. CDP fallback in the engine (headless Chromium, system Chrome)
- [ ] 4. zgx: web snapshot (done) and native input; switch macOS clicks and typing to trusted input
- [ ] 5. Windows: WebView2's CDP for trusted input
- [x] 6. `browser-tools` feature flag, off in Cloud
- [x] 7. Safari user agent so Google sign-in works
- [x] 8. zgx fork: `ui.web_cookies(profile)` (WKHTTPCookieStore set/list)
- [x] 9. Import from Chromium-family browsers (Keychain + AES), then Firefox, then Safari (Full Disk Access)
- [x] 10. Per-site agent permission before imported sessions are reachable by agents
- [x] 11. zgx fork: popup windows with an opener (OAuth popups)
- [x] 12. Agent terminals: `terminal_*` tools open panel terminal tabs (full-access chats), preferred over the agent's own shell
