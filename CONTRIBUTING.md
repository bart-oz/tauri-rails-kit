# Contributing to tauri-rails-kit

Thank you for your interest in contributing. This is a focused, opinionated kit — contributions that keep it simple and well-documented are most welcome.

---

## What we welcome

- **Bug reports** — something doesn't build or behave as expected
- **Bundle script improvements** — better dylib handling, edge cases, new bank/distro support
- **Documentation** — clearer explanations, more bank-specific CSV guides, architecture diagrams
- **Platform support** — Linux bundling scripts (post-v1.0 roadmap item)
- **New importer formats** — CSV format detection improvements

## What to avoid proposing

- Features that belong in the app built on top of the kit, not the kit itself
-Windows support (deferred indefinitely — Ruby on Windows is a different world)
- Replacing Rails with another framework (by design choice)
- Frontend build tooling (Vite, webpack) for the launcher — it is intentionally static

---

## How to contribute

1. **Open an issue first** for any non-trivial change — let's discuss before you invest time coding
2. Fork the repo and create a branch: `git checkout -b fix/description-of-fix`
3. Make your changes with clear, atomic commits
4. Open a pull request referencing the issue

---

## Commit style

Short imperative subject line, no emoji:

```
Add libssl dylib bundling for ARM64
Fix duplicate detection in CSV importer
Update bundle script to handle new Ruby release
```

---

## Development setup

Requirements:
- macOS (Intel or ARM64)
- Rust + Cargo
- Node.js 20+
- Ruby 4.0.0 (for webapp development)
- Xcode Command Line Tools

```bash
git clone https://github.com/bart-oz/tauri-rails-kit.git
cd tauri-rails-kit
npm install
cd webapp && bundle install
```

---

## Code of conduct

Be respectful. Focus on the work. No personal attacks or unconstructive criticism.

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](./LICENSE).
