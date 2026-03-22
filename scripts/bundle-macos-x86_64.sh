#!/usr/bin/env bash
# =============================================================================
# bundle-macos-x86_64.sh
#
# Prepares all bundled resources required to build a fully self-contained
# tauri-rails-kit.app for Intel macOS (x86_64).
#
# Run this ONCE before building the Tauri app:
#   ./scripts/bundle-macos-x86_64.sh
#   npm run tauri build
#
# What it does:
#   Phase 1  — Verify prerequisites (arch, Homebrew packages, tools)
#   Phase 2  — Compile Ruby 4.0.0 with --enable-load-relative --enable-shared
#   Phase 3  — Copy Ruby runtime to desktop/resources/ruby-x86_64/
#   Phase 4  — Copy required Homebrew dylibs (GMP, OpenSSL, libyaml, zlib)
#   Phase 5  — Rewrite all dylib paths with install_name_tool
#   Phase 6  — Vendor Rails gems (bundle install --deployment)
#   Phase 7  — Precompile assets (RAILS_ENV=desktop)
#   Phase 8  — Prepare databases (RAILS_ENV=desktop)
#   Phase 9  — Verify + ad-hoc codesign
#   Phase 10 — Report sizes and next steps
#
# Requirements:
#   brew install gmp openssl@3 libyaml zlib
#   Xcode command line tools (codesign, install_name_tool, otool)
#
# =============================================================================
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DESKTOP_DIR="$PROJECT_ROOT/desktop"
WEBAPP_DIR="$PROJECT_ROOT/webapp"
RESOURCES_DIR="$DESKTOP_DIR/resources"
RUBY_DEST="$RESOURCES_DIR/ruby"

# ── Architecture / Homebrew ───────────────────────────────────────────────────
ARCH="x86_64"
HOMEBREW_PREFIX="/usr/local"

# ── Source shared logic ───────────────────────────────────────────────────────
# shellcheck source=lib/bundle_common.sh
source "$SCRIPT_DIR/lib/bundle_common.sh"

# Populate HOMEBREW_DYLIBS now that HOMEBREW_PREFIX is set
_init_homebrew_dylibs

# ── Phase 1: Verify prerequisites ─────────────────────────────────────────────
header "Phase 1: Verify prerequisites"
check_prerequisites
success "Phase 1 complete"

# ── Phase 2: Compile Ruby from source ─────────────────────────────────────────
header "Phase 2: Compile Ruby $RUBY_VERSION with --enable-load-relative"

# Idempotency: skip compilation if runtime is already present.
if [[ -f "$RUBY_DEST/bin/ruby" ]] && [[ -d "$RUBY_DEST/lib/ruby/$RUBY_VERSION" ]]; then
  EXISTING_VER=$("$RUBY_DEST/bin/ruby" --version 2>/dev/null | awk '{print $2}' || echo "unknown")
  info "Bundled Ruby already present (version: $EXISTING_VER)"
  info "Delete $RUBY_DEST to force a rebuild."
  SKIP_RUBY_BUILD=true
else
  SKIP_RUBY_BUILD=false
fi

if [[ "$SKIP_RUBY_BUILD" == "false" ]]; then
  BUILD_DIR=$(mktemp -d)
  RUBY_INSTALL_DIR=$(mktemp -d)
  # Clean up source directory on exit (install dir is cheap to re-create)
  trap 'rm -rf "$BUILD_DIR"' EXIT

  info "Downloading Ruby $RUBY_VERSION source..."
  curl -fsSL "https://cache.ruby-lang.org/pub/ruby/4.0/ruby-${RUBY_VERSION}.tar.gz" \
    -o "$BUILD_DIR/ruby.tar.gz"
  tar xzf "$BUILD_DIR/ruby.tar.gz" -C "$BUILD_DIR"

  info "Configuring Ruby (this takes ~5 minutes)..."
  cd "$BUILD_DIR/ruby-${RUBY_VERSION}"
  ./configure \
    --prefix="$RUBY_INSTALL_DIR" \
    --target=x86_64-apple-darwin \
    --enable-load-relative \
    --enable-shared \
    --disable-install-doc \
    --disable-install-rdoc \
    --with-openssl-dir="$HOMEBREW_PREFIX/opt/openssl@3" \
    --with-libyaml-dir="$HOMEBREW_PREFIX/opt/libyaml" \
    --with-zlib-dir="$HOMEBREW_PREFIX/opt/zlib" \
    --with-gmp-dir="$HOMEBREW_PREFIX/opt/gmp" \
    CFLAGS="-arch x86_64 -O2" \
    LDFLAGS="-arch x86_64" \
    2>&1 | tail -5

  info "Compiling Ruby (using $(sysctl -n hw.ncpu) cores)..."
  make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3
  make install 2>&1 | tail -3
  cd "$PROJECT_ROOT"
  success "Ruby $RUBY_VERSION compiled"

  # ── Phase 3: Copy Ruby runtime ───────────────────────────────────────────
  header "Phase 3: Copy Ruby runtime to resources/ruby-x86_64/"

  rm -rf "$RUBY_DEST"
  mkdir -p "$RUBY_DEST/bin" "$RUBY_DEST/lib"

  info "Copying ruby binary..."
  cp "$RUBY_INSTALL_DIR/bin/ruby" "$RUBY_DEST/bin/"

  info "Copying libruby shared library..."
  # Ruby names its dylib libruby.<MAJOR>.<MINOR>.dylib (e.g. libruby.4.0.dylib),
  # not libruby.<MAJOR>.<MINOR>.<PATCH>.dylib. Copy whichever versioned dylib exists.
  LIBRUBY_SRC=$(ls "$RUBY_INSTALL_DIR/lib/libruby."*.dylib 2>/dev/null \
    | grep -v '/libruby\.dylib$' | head -1)
  [[ -z "$LIBRUBY_SRC" ]] && error "Could not find libruby dylib in $RUBY_INSTALL_DIR/lib/"
  cp "$LIBRUBY_SRC" "$RUBY_DEST/lib/"
  info "Copied: $(basename "$LIBRUBY_SRC")"

  info "Copying Ruby standard library..."
  mkdir -p "$RUBY_DEST/lib/ruby"
  cp -R "$RUBY_INSTALL_DIR/lib/ruby/$RUBY_VERSION" "$RUBY_DEST/lib/ruby/$RUBY_VERSION"

  info "Copying default gems (bundler, json, etc.)..."
  if [[ -d "$RUBY_INSTALL_DIR/lib/ruby/gems" ]]; then
    cp -R "$RUBY_INSTALL_DIR/lib/ruby/gems" "$RUBY_DEST/lib/ruby/gems"
  fi

  info "Trimming unused files..."
  find "$RUBY_DEST" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
  find "$RUBY_DEST" -name "*.ri"   -delete 2>/dev/null || true
  find "$RUBY_DEST" -name "*.rdoc" -delete 2>/dev/null || true
  rm -rf "$RUBY_DEST/lib/ruby/$RUBY_VERSION/rdoc"
  rm -rf "$RUBY_DEST/share"   2>/dev/null || true
  rm -rf "$RUBY_DEST/include" 2>/dev/null || true

  success "Ruby runtime copied ($(du -sh "$RUBY_DEST" | cut -f1))"
fi

# From here, RUBY_DEST is guaranteed to exist.
LIBRUBY_NAME=$(ls "$RUBY_DEST/lib/" \
  | grep "libruby.*\.dylib" | grep -v "^libruby\.dylib$" | head -1)
LIBRUBY_PATH="$RUBY_DEST/lib/$LIBRUBY_NAME"
[[ -z "$LIBRUBY_NAME" ]] && error "Could not find libruby dylib in $RUBY_DEST/lib/"
info "Using libruby: $LIBRUBY_NAME"

success "Phase 2 + 3 complete"

# ── Phase 4: Copy required Homebrew dylibs ────────────────────────────────────
header "Phase 4: Copy required Homebrew dylibs"

DYLIB_DEST="$RUBY_DEST/lib"

for dylib in "${HOMEBREW_DYLIBS[@]}"; do
  name=$(basename "$dylib")
  if [[ ! -f "$DYLIB_DEST/$name" ]]; then
    cp "$dylib" "$DYLIB_DEST/"
    info "Bundled: $name ($(du -sh "$DYLIB_DEST/$name" | cut -f1))"
  else
    info "Already present: $name"
  fi
done

success "Phase 4 complete — Homebrew dylibs bundled"

# ── Phase 5: Rewrite dylib paths ──────────────────────────────────────────────
header "Phase 5: Rewrite dylib paths with install_name_tool"

# 5a: Set libruby's own install name, fix its Homebrew references
info "Fixing libruby install name..."
install_name_tool -id "@rpath/$LIBRUBY_NAME" "$LIBRUBY_PATH"
fix_dylib_refs "$LIBRUBY_PATH" "@loader_path"

# 5b: Fix ruby binary — libruby + Homebrew dylibs
info "Fixing ruby binary..."
old_libruby_in_ruby=$(otool -L "$RUBY_DEST/bin/ruby" 2>/dev/null \
  | grep "libruby" | grep -v "@" | awk '{print $1}' || true)
if [[ -n "$old_libruby_in_ruby" ]]; then
  install_name_tool -change "$old_libruby_in_ruby" \
    "@executable_path/../lib/$LIBRUBY_NAME" \
    "$RUBY_DEST/bin/ruby"
fi
for dylib in "${HOMEBREW_DYLIBS[@]}"; do
  name=$(basename "$dylib")
  old_path=$(otool -L "$RUBY_DEST/bin/ruby" 2>/dev/null \
    | grep "$name" | grep -v "@" | awk '{print $1}' || true)
  if [[ -n "$old_path" ]]; then
    install_name_tool -change "$old_path" \
      "@executable_path/../lib/$name" \
      "$RUBY_DEST/bin/ruby"
  fi
done

# 5c: Fix cross-references between bundled Homebrew dylibs
info "Fixing cross-references between bundled dylibs..."
for dylib_file in "$DYLIB_DEST"/lib*.dylib; do
  [[ -f "$dylib_file" ]] || continue
  dylib_name=$(basename "$dylib_file")
  install_name_tool -id "@rpath/$dylib_name" "$dylib_file" 2>/dev/null || true
  for other_dylib in "${HOMEBREW_DYLIBS[@]}"; do
    other_name=$(basename "$other_dylib")
    [[ "$other_name" == "$dylib_name" ]] && continue
    old_ref=$(otool -L "$dylib_file" 2>/dev/null \
      | grep "$other_name" | grep -v "@" | awk '{print $1}' || true)
    if [[ -n "$old_ref" ]]; then
      install_name_tool -change "$old_ref" "@loader_path/$other_name" "$dylib_file"
    fi
  done
done

# 5d: Fix all stdlib .bundle extension paths
info "Fixing stdlib .bundle extensions..."
BUNDLE_COUNT=$(fix_all_bundle_extensions "$RUBY_DEST/lib/ruby" "relative")
success "Fixed $BUNDLE_COUNT stdlib .bundle extensions"

success "Phase 5 complete — all dylib paths rewritten"

# ── Phase 6: Vendor Rails gems ────────────────────────────────────────────────
header "Phase 6: Vendor Rails gems (bundle install --deployment)"

cd "$WEBAPP_DIR"

bundle config set --local deployment        true
bundle config set --local path             vendor/bundle
bundle config set --local without          "development test desktop"
# Prevent precompiled platform gems (e.g. date-x86_64-darwin) — they embed
# `-bundle_loader ruby` which expects symbols from the ruby executable.
# Our Ruby is --enable-shared; symbols live in libruby.dylib, not the binary.
# force_ruby_platform ensures every gem is compiled from source using the
# bundled Ruby's LDSHARED (-dynamic -bundle -undefined dynamic_lookup).
bundle config set --local force_ruby_platform true

# Remove any already-installed precompiled platform gems so bundle install
# replaces them with freshly compiled source variants.
info "Checking for precompiled platform gems (from executable symbols)..."
PRECOMPILED_REMOVED=0
while IFS= read -r -d '' bundle_file; do
  if nm -m "$bundle_file" 2>/dev/null | grep -q "(from executable)"; then
    gem_dir=$(dirname "$(dirname "$bundle_file")")
    info "  removing precompiled gem: $(basename "$gem_dir")"
    rm -rf "$gem_dir"
    PRECOMPILED_REMOVED=$((PRECOMPILED_REMOVED + 1))
  fi
done < <(find "$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/gems" \
         -name "*.bundle" -print0 2>/dev/null)
if [[ $PRECOMPILED_REMOVED -gt 0 ]]; then
  info "Removed $PRECOMPILED_REMOVED precompiled gem(s) — will recompile from source"
  rm -rf "$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/extensions"
fi

bundle lock --add-platform ruby 2>/dev/null || true

info "Running bundle install (may take a minute on first run)..."
bundle install 2>&1 | tail -5

# Gem tarballs unpack files with read-only bits (e.g. 444). Fix immediately
# so every subsequent step — install_name_tool, codesign, Tauri's copy — works.
chmod -R u+w "$WEBAPP_DIR/vendor/bundle" 2>/dev/null || true

# If a previous script run already rewrote native extension paths (Phase 9),
# those .bundle files are now incompatible with the system Ruby used here.
# Detect and delete them so `bundle install` recompiles them fresh against
# the system Ruby — Phases 7+8 need unmodified extensions.
MODIFIED_BUNDLES=0
while IFS= read -r -d '' bundle; do
  if otool -L "$bundle" 2>/dev/null \
      | grep "libruby" | grep -q "@loader_path\|@executable_path"; then
    rm -f "$bundle"
    MODIFIED_BUNDLES=$((MODIFIED_BUNDLES + 1))
  fi
done < <(find "$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/gems" \
         -name "*.bundle" -print0 2>/dev/null)

# Also clear the extensions cache dir so bundler picks up the deletions
if [[ $MODIFIED_BUNDLES -gt 0 ]]; then
  info "Removed $MODIFIED_BUNDLES modified extension(s); recompiling..."
  rm -rf "$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/extensions"
  bundle install 2>&1 | tail -5
fi

# Fix native extension platform path mismatch.
# WHY: `bundle install` runs with the system Ruby (e.g. x86_64-darwin-24),
# so native gem extensions land in:
#   vendor/bundle/ruby/4.0.0/extensions/x86_64-darwin-24/4.0.0/
# Our compiled Ruby reports platform `x86_64-darwin` (no darwin version suffix),
# so Bundler looks in:
#   vendor/bundle/ruby/4.0.0/extensions/x86_64-darwin/4.0.0/
# A symlink bridges the gap without recompiling anything.
EXT_BASE="$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/extensions"
SYSTEM_PLATFORM=$(ruby -e "puts Gem::Platform.local.to_s" 2>/dev/null || true)
BUNDLED_PLATFORM="x86_64-darwin"

if [[ -n "$SYSTEM_PLATFORM" \
    && "$SYSTEM_PLATFORM" != "$BUNDLED_PLATFORM" \
    && -d "$EXT_BASE/$SYSTEM_PLATFORM" ]]; then
  info "Creating extensions symlink: $BUNDLED_PLATFORM -> $SYSTEM_PLATFORM"
  # Remove any existing symlink/directory first; without this, ln -sfn puts
  # the new symlink INSIDE an existing directory, creating a self-referential loop.
  rm -rf "$EXT_BASE/$BUNDLED_PLATFORM"
  ln -sf "$SYSTEM_PLATFORM" "$EXT_BASE/$BUNDLED_PLATFORM"
  success "Extensions symlink created (fixes platform mismatch for bundled Ruby)"
else
  info "No extension platform mismatch detected (system: $SYSTEM_PLATFORM)"
fi

# Remove any of our dylibs that a previous script run may have copied into gem
# directories. Those copies corrupt gem extensions for the system ruby (different
# libruby UUID). The path-rewrite step runs in Phase 9, after system-ruby phases.
info "Removing stale bundled dylibs from gem directories..."
GEMS_DIR="$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/gems"
if [[ -d "$GEMS_DIR" ]]; then
  find "$GEMS_DIR" -name "libruby*.dylib" -delete 2>/dev/null || true
  for _hb_dylib in "${HOMEBREW_DYLIBS[@]}"; do
    find "$GEMS_DIR" -name "$(basename "$_hb_dylib")" -delete 2>/dev/null || true
  done
fi

cd "$PROJECT_ROOT"
success "Phase 6 complete — gems vendored"

# ── Phase 7: Precompile assets ────────────────────────────────────────────────
header "Phase 7: Precompile assets (RAILS_ENV=desktop)"

cd "$WEBAPP_DIR"
info "Running assets:precompile..."
RAILS_ENV=desktop DESKTOP_MODE=true bundle exec bin/rails assets:precompile
cd "$PROJECT_ROOT"
success "Phase 7 complete — assets precompiled"

# ── Phase 8: Prepare databases ────────────────────────────────────────────────
header "Phase 8: Prepare databases (RAILS_ENV=desktop)"

cd "$WEBAPP_DIR"
info "Running db:prepare (creates primary, cache, queue, cable)..."
RAILS_ENV=desktop DESKTOP_MODE=true bundle exec bin/rails db:prepare
cd "$PROJECT_ROOT"
success "Phase 8 complete — databases prepared"

# ── Phase 9: Verify + ad-hoc codesign ────────────────────────────────────────
header "Phase 9: Verification and ad-hoc codesign"

ERRORS=0

# Unlock any stale Tauri codesign artifacts from a previous build run
unlock_tauri_targets

# Fix native gem extension dylib paths NOW — after Phases 7+8 have finished
# using the system ruby. Phases 7+8 run with RVM's ruby and must load gems
# against RVM's libruby. Rewriting those references beforehand causes
# "linked to incompatible libruby" errors because our compiled libruby and
# RVM's libruby have different UUIDs even though both report Ruby 4.0.0.
info "Fixing native gem extension dylib paths..."
GEM_BUNDLE_COUNT=$(fix_all_bundle_extensions \
  "$WEBAPP_DIR/vendor/bundle" "local")
success "Fixed $GEM_BUNDLE_COUNT native gem extension(s)"

# Verify ruby binary and libruby have no absolute non-system paths
info "Checking ruby binary..."
verify_no_absolute_paths "$RUBY_DEST/bin/ruby" "ruby binary" || ERRORS=$((ERRORS + 1))

info "Checking $LIBRUBY_NAME..."
verify_no_absolute_paths "$LIBRUBY_PATH" "$LIBRUBY_NAME" || ERRORS=$((ERRORS + 1))

# Smoke tests using the bundled ruby
info "Smoke-testing ruby binary..."
if "$RUBY_DEST/bin/ruby" -e "puts RUBY_VERSION" 2>/dev/null | grep -q "$RUBY_VERSION"; then
  success "ruby --version: $("$RUBY_DEST/bin/ruby" --version 2>/dev/null)"
else
  warn "Ruby smoke test failed (may be OK if dylibs need the final bundle layout)"
  ERRORS=$((ERRORS + 1))
fi

info "Smoke-testing OpenSSL..."
if "$RUBY_DEST/bin/ruby" -e "require 'openssl'; puts OpenSSL::VERSION" 2>/dev/null \
    | grep -q "\."; then
  OPENSSL_VER=$("$RUBY_DEST/bin/ruby" \
    -e "require 'openssl'; puts OpenSSL::VERSION" 2>/dev/null)
  success "OpenSSL: $OPENSSL_VER"
else
  warn "OpenSSL load test failed — check libssl/libcrypto paths"
fi

# Ad-hoc codesign everything
info "Codesigning Ruby runtime..."
codesign_tree "$DYLIB_DEST" "$RUBY_DEST/bin/ruby"

info "Codesigning stdlib .bundle extensions..."
codesign_tree "$RUBY_DEST/lib/ruby"

info "Codesigning vendored gem extensions..."
codesign_tree "$WEBAPP_DIR/vendor/bundle"

success "Phase 9 complete"

# ── Phase 10: Report ──────────────────────────────────────────────────────────
header "Phase 10: Report"

echo ""
echo "═══════════════════════════════════════════════════════"
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GREEN}  Bundle preparation complete — no errors!${NC}"
else
  echo -e "${YELLOW}  Bundle preparation finished with $ERRORS warning(s). Review output above.${NC}"
fi
echo ""
echo "Approximate sizes:"
du -sh "$RUBY_DEST" 2>/dev/null \
  | awk '{print "  Ruby runtime:  " $1}'
du -sh "$WEBAPP_DIR/vendor/bundle" 2>/dev/null \
  | awk '{print "  Gem bundle:    " $1}' || true
du -sh "$WEBAPP_DIR/public/assets" 2>/dev/null \
  | awk '{print "  Assets:        " $1}' || true
du -sh "$WEBAPP_DIR/storage" 2>/dev/null \
  | awk '{print "  Databases:     " $1}' || true
echo ""
echo "Next steps:"
echo "  npm run tauri build"
echo "  open desktop/target/release/bundle/macos/*.app"
echo "═══════════════════════════════════════════════════════"
