# tauri-rails-kit — Agent & Contributor Guidance

## Overview

`tauri-rails-kit` is a macOS desktop app starter kit built with Tauri 2 (Rust) and Ruby on Rails 8. It is a **kit**, not an application — its job is to solve the hard bundling and process-management problems once, so developers can build their own apps on top of it without fighting the toolchain.

The kit ships a working, buildable foundation. Nothing more.

---

## Key Commands

**Build the app (production):**
```bash
npm run tauri build
```

**Development mode:**
```bash
npm run tauri dev
```

**Bundle Ruby + dependencies for Intel Mac (run before every build):**
```bash
./scripts/bundle-macos-x86_64.sh
```

**Bundle for ARM64:**
```bash
./scripts/bundle-macos-arm64.sh
```

**Rails console (for webapp development):**
```bash
cd webapp && RAILS_ENV=desktop bin/rails console
```

**Run Rails migrations:**
```bash
cd webapp && RAILS_ENV=desktop bin/rails db:migrate
```

**Rename the kit to your app:**
```bash
./scripts/setup.sh --name "My App" --bundle-id "com.example.myapp"
```

---

## Architecture

The app has three layers:

### 1. Tauri / Rust (`desktop/`)
The native shell. Manages the app lifecycle and spawns two child processes:
- Rails server (HTTP on a dynamically allocated port starting from 8934)
- Solid Queue worker (background jobs)

Key file: `desktop/src/lib.rs` — process manager, port allocation, lifecycle.

### 2. Rails app (`webapp/`)
A standard Rails 8 app running in `RAILS_ENV=desktop`. Uses the full Solid Stack:
- **Solid Queue** — background jobs (SQLite-backed, no Redis)
- **Solid Cache** — caching (SQLite-backed)
- **Solid Cable** — WebSockets via ActionCable (in-process, no separate server)

The Tauri webview navigates to `http://localhost:<PORT>` once Rails is ready. All UI is rendered by Rails (Turbo + Hotwire). No separate frontend framework.

### 3. Launcher (`launcher/`)
A static HTML splash screen shown in the Tauri webview while Rails boots. Plain HTML + CSS + VanillaJS. No build step, no framework. Communicates with Rust via `window.__TAURI__.core.invoke`.

---

## Key Files

| File | Purpose |
|------|---------|
| `desktop/src/lib.rs` | Rust process manager — Rails server + worker lifecycle |
| `desktop/tauri.conf.json` | Tauri build config — window, resources, bundle ID |
| `desktop/Cargo.toml` | Rust dependencies |
| `scripts/bundle-macos-x86_64.sh` | 10-phase build-prep script for Intel |
| `scripts/bundle-macos-arm64.sh` | Build-prep script for ARM64 |
| `scripts/lib/bundle_common.sh` | Shared bundling logic (sourced by arch scripts) |
| `scripts/setup.sh` | Rename the kit to your app |
| `webapp/Gemfile` | Rails dependencies |
| `webapp/config/environments/desktop.rb` | Desktop-specific Rails config |
| `launcher/index.html` | Splash screen |

---

## Bundled Resources

Ruby is bundled inside the `.app`:

| Resource | Path in bundle |
|----------|---------------|
| Ruby binary | `Contents/Resources/resources/ruby-x86_64/bin/ruby` |
| Ruby gems | `Contents/Resources/_up_/webapp/vendor/bundle/` |
| Rails app | `Contents/Resources/_up_/webapp/` |

`resource_dir` in Rust resolves to `Contents/Resources/`.

---

## Platform Constraints

- **macOS only** — Intel (x86_64) and ARM64. No Linux or Windows support in this kit.
- **Intel Homebrew** at `/usr/local/opt/`. ARM64 uses `/opt/homebrew/`.
- Ruby must be compiled from source with `--enable-load-relative --enable-shared`. RVM/rbenv rubies are not portable.
- All dylibs must have paths rewritten with `install_name_tool` before bundling.

---

## What to Avoid

- Do not add a frontend build step (Vite, webpack, esbuild) to the launcher. It is intentionally static.
- Do not hardcode ports. Dynamic allocation is by design.
- Do not add gems to `Gemfile` that require native extensions unless the extension's `.so` is bundled.
- Do not use `cargo tauri build` directly — always use `npm run tauri build` (ensures JS context is correct).
- Do not add complexity to the kit that belongs in the app built on top of it.
- Do not introduce Windows-specific code paths.

---

## Testing

There is no automated test suite for the kit itself. Verification is done by building and running the app end-to-end:

1. Run the bundle script
2. Run `npm run tauri build`
3. Launch the `.app` and verify Rails boots + app is usable
4. Quit and verify no orphaned processes

---

## Working with AI Agents

Agents assist — they do not ship.

**Only the developer commits and pushes.** After an AI agent makes changes, the developer reviews the diff, tests the result, and decides what gets committed. Agents never run `git push` or `git commit`.

**Agents prepare commit message suggestions.** When work is complete, the agent should offer a short, ready-to-use commit message that follows the style below. Keep it honest and minimal — describe what changed, not the journey to get there.

**Do not ask agents to push** unless you have explicitly set up automation that you own and understand. Authorization to write code is not authorization to publish it.

---

## Commit Style

Short imperative subject line. No emoji. No period at the end.

```
Add libssl dylib to Intel bundle script
Fix port allocation race condition on startup
Update bundle script to handle new Ruby release
```

Reference the relevant issue where applicable: `Closes #12`
