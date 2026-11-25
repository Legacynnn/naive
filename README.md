# Naive

Control your coding agents (Claude Code, Codex, Cursor, OpenCode, Devin, Grok, Hermes, Pi, Antigravity, Muse Code, fx) locally by default, with optional multi-device sync.

*English | [简体中文](README.zh-CN.md) | [한국어](README.ko.md) | [日本語](README.ja.md) | [Español](README.es.md)*

![Naive desktop app](docs/media/readme/app-screenshot.jpg)

## Desktop app

Download the latest release for your platform from [GitHub Releases](https://github.com/zeronsh/zeron/releases/latest):

- **macOS** (Apple silicon, macOS 13+) — `naive-<version>-macos-arm64.dmg`
- **Windows** — `naive-<version>-windows-x86_64-setup.exe`
- **Linux** — `naive-<version>-linux-<arch>.tar.gz`, then run its `install.sh`

No account or network connection is needed; sessions stay on your device. The desktop app is built on [zgx](https://zgx.naive.sh) (native Rust with a hot-reloading Luau UI supporting plugins, templates, and themes) and updates itself.

## Headless (CLI)

For servers and other machines without a display, such as a VPS that keeps agents running after you close your laptop. Linux only:

```bash
curl -fsSL https://naive.sh/install.sh | sh
naive status
```

The installer starts the engine as a background service that survives reboots.

```bash
naive status      # local/synced mode and engine status
naive update      # update to the latest release
naive daemon start|stop|restart|status
```

## Multi-device sync (optional)

Sign in to start an agent on one device and follow or drive it from another:

```bash
naive daemon stop
naive login        # or: naive logout to return to local-only
naive daemon start
```

Devices signed in to the same account can read and write each other's workspace files, so only sign in devices you trust. Existing local sessions are never uploaded.

## Sponsors

Thank you to [The Context Company](https://www.thecontextcompany.com/) for sponsoring Naive. You can help fund Naive's development too by [becoming a sponsor on GitHub](https://github.com/sponsors/zeronsh).

---

Developing or curious how it works? [Ask DeepWiki](https://deepwiki.com/zeronsh/zeron), read [ARCHITECTURE.md](ARCHITECTURE.md), or see [CONTRIBUTORS.md](CONTRIBUTORS.md) and [apps/zgx/README.md](apps/zgx/README.md).

Licensed under the [MIT License](LICENSE).
