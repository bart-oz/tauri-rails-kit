# tauri-rails-kit

> Build native macOS desktop apps with Ruby on Rails — bundled, signed, and ready to ship.

**Status: Building in public — follow the journey via [Issues](https://github.com/bart-oz/tauri-rails-kit/issues) and [Milestones](https://github.com/bart-oz/tauri-rails-kit/milestones).**

---

## What is this?

`tauri-rails-kit` is a free, open-source starter kit for developers who want to build macOS desktop applications using [Tauri 2](https://tauri.app) and [Ruby on Rails 8](https://rubyonrails.org).

It solves the hard parts so you can focus on your app:

- **Ruby bundled** — compiled from source with `--enable-load-relative`, all dylibs included and path-rewritten
- **Rails 8 ready** — full Solid Stack (Queue, Cache, Cable), SQLite, asset pipeline precompiled
- **Process management** — Rust backend spawns and supervises Rails server + Solid Queue worker; clean shutdown, no orphans
- **Dynamic ports** — no hardcoded ports, no conflicts
- **macOS Intel + ARM64** — separate bundle scripts, shared common library
- **Simple setup** — one script to rename the app to yours

---

## Roadmap

| Milestone | Status |
|-----------|--------|
| [v0.1.0 — Buildable Foundation](https://github.com/bart-oz/tauri-rails-kit/milestone/1) | 🚧 In Progress |
| [v0.2.0 — ARM64 Support](https://github.com/bart-oz/tauri-rails-kit/milestone/2) | Planned |
| [v0.3.0 — Setup & Documentation](https://github.com/bart-oz/tauri-rails-kit/milestone/3) | Planned |
| [v1.0.0 — Release Ready](https://github.com/bart-oz/tauri-rails-kit/milestone/4) | Planned |

---

## Stack

| Layer | Technology |
|-------|-----------|
| Desktop shell | [Tauri 2](https://tauri.app) (Rust) |
| Backend | [Ruby on Rails 8.1](https://rubyonrails.org) |
| Database | SQLite via [Solid Stack](https://github.com/rails/solid_queue) |
| Background jobs | [Solid Queue](https://github.com/rails/solid_queue) |
| Frontend | Vite + TypeScript |
| Platform | macOS (Intel x86_64 + ARM64) |

---

## Getting Started

> Full setup guide coming in v0.3.0. Follow along via [issues](https://github.com/bart-oz/tauri-rails-kit/issues).

```bash
git clone https://github.com/bart-oz/tauri-rails-kit.git
cd tauri-rails-kit

# Rename to your app
./scripts/setup.sh --name "My App" --bundle-id "com.example.myapp"

# Bundle Ruby
./scripts/bundle-macos-x86_64.sh

# Build the app
npm run tauri build
```

---

## Philosophy

This kit does one thing: gives Rails developers a solid, reproducible foundation for shipping macOS desktop apps. No magic, no black boxes — every phase of the build process is documented and auditable. Add what you need, nothing more.

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). All contributions welcome — bug reports, improvements to the bundle scripts, documentation, and new platform support.

---

## License

MIT — see [LICENSE](./LICENSE).
