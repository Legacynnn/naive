# Agent browser control: plan

Spec: [`docs/specs/agent-browser.md`](../specs/agent-browser.md).

- [ ] 1. Tool surface in `crates/mcp`, backend trait and shared snapshot JS
- [ ] 2. Webview backend on macOS: snapshot, click, type and navigate through `web:eval` (demo-ready)
- [ ] 3. CDP fallback in the engine (headless Chromium, system Chrome)
- [ ] 4. zgx: web snapshot and native input; switch macOS clicks and typing to trusted input
- [ ] 5. Windows: WebView2's CDP for trusted input
- [ ] 6. `browser-tools` feature flag, off in Cloud
