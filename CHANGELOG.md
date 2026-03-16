## [0.1.0] - 2026-03-15

### Added

#### Desktop Shell (Tauri 2 + Rust)
- Tauri 2 application shell targeting Intel macOS (x86_64)
- Dynamic port allocation for Rails server starting from 8934
- Rust process manager — spawns and supervises Rails server and Solid Queue worker
- Graceful shutdown — all child processes stopped on window close
- Health monitor — detects Rails crashes and logs process lifecycle events
- Bundle integrity check — fails fast at startup if required resources are missing
- Isolated child process environment — bundled Ruby and vendor gems only, no system Ruby leakage
- Launcher splash screen displayed while Rails boots

#### Launcher
- Static HTML + CSS + VanillaJS splash screen
- Polls `get_rails_port` Tauri command and navigates to Rails once ready

#### Rails 8 Webapp
- Rails 8.1 application with SQLite (primary, cache, queue, cable databases)
- Solid Stack: Solid Queue (background jobs), Solid Cache (caching), Solid Cable (WebSockets)
- Propshaft asset pipeline with Importmap, Turbo, and Stimulus
- `desktop` Rails environment for bundled production-like operation
- Posts scaffold — full CRUD with Turbo Drive and Hotwire for real-time UI updates
- Puma web server configured for single-worker desktop operation

#### Intel Bundle Script (`scripts/bundle-macos-x86_64.sh`)
- 10-phase build-prep script for Intel macOS (x86_64)
- Phase 1: prerequisite verification (arch, Homebrew packages, CLI tools)
- Phase 2+3: Ruby 4.0.0 compiled from source with `--enable-load-relative --enable-shared`; idempotent
- Phase 4: Homebrew dylibs bundled (GMP, OpenSSL 3, libyaml, zlib)
- Phase 5: all dylib paths rewritten with `install_name_tool` for portability
- Phase 6: gems vendored via `bundle install --deployment`; native extension path rewriting deferred to Phase 9
- Phase 7: `assets:precompile` (RAILS_ENV=desktop) using system Ruby with pristine gem extensions
- Phase 8: `db:prepare` (RAILS_ENV=desktop) — ships pre-initialized SQLite databases
- Phase 9: native gem extension dylib paths rewritten for bundled Ruby; ad-hoc codesign sweep
- Phase 10: size report and next-step instructions
- Idempotent re-runs — detects and recompiles modified native extensions automatically
- `chmod -R u+w vendor/bundle` applied immediately after `bundle install` to prevent Tauri copy errors

#### Shared Bundling Library (`scripts/lib/bundle_common.sh`)
- Shared functions sourced by both Intel and ARM64 bundle scripts
- `check_prerequisites`, `fix_dylib_refs`, `fix_all_bundle_extensions` (relative + local strategies)
- `codesign_tree`, `verify_no_absolute_paths`, `unlock_tauri_targets`
- Designed for reuse — ARM64 script sources the same library

#### Tooling
- Placeholder app icons (32×32, 128×128, 128×128@2x, icns, ico)
- `scripts/generate-icons.sh` — regenerates icons from `public/icon.png`
- GitHub Actions CI: rustfmt, clippy, cargo check, cargo test
- CI resource stubs — satisfy Tauri glob validation without a full bundle
