# tauri-rails-kit — Agent Guide

This file is auto-loaded by Claude Code and other AI agents. Read it fully before making any changes.

---

## What this project is

A free, open-source macOS starter kit for building desktop apps with [Tauri 2](https://tauri.app) (Rust) and [Ruby on Rails 8](https://rubyonrails.org). It is a **kit**, not an application. Its job is to solve the hard bundling and process-management problems once, so developers can build their own apps on top without fighting the toolchain.

Ship the working foundation. Nothing more.

---

## Architecture

Three layers:

| Layer | Directory | Technology |
|-------|-----------|------------|
| Desktop shell | `desktop/` | Tauri 2 (Rust) — spawns and supervises Rails + Solid Queue |
| Rails app | `webapp/` | Rails 8.1, SQLite, Solid Stack (Queue, Cache, Cable) |
| Launcher | `launcher/` | Static HTML + plain CSS + VanillaJS splash screen |

The Tauri webview navigates to `http://localhost:<PORT>` once Rails is ready. All UI is rendered by Rails (Turbo + Hotwire). No separate frontend framework.

Dynamic port allocation starting from 8934. No hardcoded ports.

---

## Layer-specific guides

Each directory has its own `CLAUDE.md` with patterns and conventions specific to that layer. **Read the relevant one before working in that directory.**

| Directory | Guide | Covers |
|-----------|-------|--------|
| `desktop/` | `desktop/CLAUDE.md` | Rust/Tauri patterns, process management, Tauri 2 API, idiomatic Rust |
| `webapp/` | `webapp/CLAUDE.md` | Rails/Ruby patterns, service objects, RSpec, Hotwire |

> `desktop/CLAUDE.md` and `webapp/CLAUDE.md` are added when those directories land in the first milestone. Until then, consult `STYLE.md` for both layers.

---

## Key commands

```bash
# Build (production)
npm run tauri build

# Development
npm run tauri dev

# Bundle Ruby + deps for Intel Mac (run before every build)
./scripts/bundle-macos-x86_64.sh

# Bundle for ARM64
./scripts/bundle-macos-arm64.sh

# Rails console
cd webapp && RAILS_ENV=desktop bin/rails console

# Rename the kit to your app
./scripts/setup.sh --name "My App" --bundle-id "com.example.myapp"
```

---

## Key files

| File | Purpose |
|------|---------|
| `desktop/src/lib.rs` | Rust process manager — Rails server + worker lifecycle |
| `desktop/tauri.conf.json` | Tauri build config — window, resources, bundle ID |
| `scripts/bundle-macos-x86_64.sh` | 10-phase build-prep script for Intel |
| `scripts/bundle-macos-arm64.sh` | Build-prep script for ARM64 |
| `scripts/lib/bundle_common.sh` | Shared bundling logic |
| `webapp/Gemfile` | Rails dependencies |
| `webapp/config/environments/desktop.rb` | Desktop-specific Rails config |
| `launcher/index.html` | Splash screen |

---

## What to avoid

- No hardcoded ports — dynamic allocation is by design
- No frontend build step (Vite, webpack, esbuild) in the launcher — it is intentionally static
-No Windows-specific code paths
- No unbundled native gem extensions
- No complexity that belongs in the app, not the kit
- Use `npm run tauri build`, not `cargo tauri build` directly

---

## Working with AI agents

Agents assist — they do not ship.

**Never commit or push on behalf of the developer.** After making changes, prepare a short commit message suggestion following the style below. The developer reviews the diff, tests the result, and decides what gets committed.

---

## Commit style

Short imperative subject line. No emoji. No period. 50 characters or less.

```
Add libssl dylib bundling for ARM64
Fix port allocation race condition on startup
Update bundle script to handle Ruby 4.0.1
```

Reference the relevant issue: `Closes #12`

Body explains **why**, not what (optional):

```
Fix port allocation race condition on startup

Rails and Solid Queue were both calling find_available_port
concurrently. Added a mutex around the port scan so only one
process claims a port at a time.

Closes #12
```

---

## Further reading

- Full architecture detail: [`AGENTS.md`](./AGENTS.md)
- Code style, patterns, refactor triggers: [`STYLE.md`](./STYLE.md)
- Contribution guidelines: [`CONTRIBUTING.md`](./CONTRIBUTING.md)
- [Tauri 2 Documentation](https://v2.tauri.app)
- [Tauri 2 — Process & Command API](https://v2.tauri.app/reference/javascript/api/namespacecore/)
- [Rails 8 Guides](https://guides.rubyonrails.org)
