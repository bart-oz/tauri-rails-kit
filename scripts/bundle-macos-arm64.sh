#!/usr/bin/env bash
# =============================================================================
# bundle-macos-arm64.sh
#
# Prepares all bundled resources required to build a fully self-contained
# tauri-rails-kit.app for Apple Silicon macOS (arm64).
#
# Run this ONCE before building the Tauri app:
#   ./scripts/bundle-macos-arm64.sh
#   npm run tauri build
#
# What it does:
#   Phase 1  — Verify prerequisites (arch, Homebrew packages, tools)
#   Phase 2  — Compile Ruby 4.0.0 with --enable-load-relative --enable-shared
#   Phase 3  — Copy Ruby runtime to desktop/resources/ruby-arm64/
#   Phase 4  — Copy required Homebrew dylibs (GMP, OpenSSL, libyaml, zlib)
#   Phase 5  — Rewrite all dylib paths with install_name_tool
#   Phase 6  — Vendor Rails gems (bundle install --deployment)
#   Phase 7  — Precompile assets (RAILS_ENV=desktop)
#   Phase 8  — Prepare databases (RAILS_ENV=desktop)
#   Phase 9  — Verify + ad-hoc codesign
#   Phase 10 — Report sizes and next steps
#
# Requirements:
#   brew install gmp openssl@3 libyaml
#   brew install ruby   (macOS system Ruby 2.6 is too old for bundler 4.x)
#   Xcode command line tools (codesign, install_name_tool, otool)
#
# =============================================================================
set -euo pipefail

# ── Prefer Homebrew Ruby over macOS system Ruby 2.6 ──────────────────────────
# If the developer has `brew install ruby`, make it take precedence so that
# `bundle`, `gem`, etc. resolve to a modern interpreter for Phases 6-8.
if [[ -d "/opt/homebrew/opt/ruby/bin" ]]; then
  export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DESKTOP_DIR="$PROJECT_ROOT/desktop"
WEBAPP_DIR="$PROJECT_ROOT/webapp"
RESOURCES_DIR="$DESKTOP_DIR/resources"
RUBY_DEST="$RESOURCES_DIR/ruby"

# ── Architecture / Homebrew ───────────────────────────────────────────────────
ARCH="arm64"
HOMEBREW_PREFIX="/opt/homebrew"

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

  # Only pass --with-zlib-dir if Homebrew zlib is installed; otherwise Ruby's
  # configure auto-detects system zlib (/usr/lib/libz.1.dylib).
  ZLIB_CONFIGURE_ARGS=()
  if [[ -f "$HOMEBREW_PREFIX/opt/zlib/lib/libz.1.dylib" ]]; then
    ZLIB_CONFIGURE_ARGS+=("--with-zlib-dir=$HOMEBREW_PREFIX/opt/zlib")
  fi

  info "Configuring Ruby (this takes ~5 minutes)..."
  cd "$BUILD_DIR/ruby-${RUBY_VERSION}"
  ./configure \
    --prefix="$RUBY_INSTALL_DIR" \
    --target=aarch64-apple-darwin \
    --enable-load-relative \
    --enable-shared \
    --disable-install-doc \
    --disable-install-rdoc \
    --with-openssl-dir="$HOMEBREW_PREFIX/opt/openssl@3" \
    --with-libyaml-dir="$HOMEBREW_PREFIX/opt/libyaml" \
    "${ZLIB_CONFIGURE_ARGS[@]}" \
    --with-gmp-dir="$HOMEBREW_PREFIX/opt/gmp" \
    CFLAGS="-arch arm64 -O2" \
    LDFLAGS="-arch arm64" \
    2>&1 | tail -5

  info "Compiling Ruby (using $(sysctl -n hw.ncpu) cores)..."
  make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -3
  make install 2>&1 | tail -3
  cd "$PROJECT_ROOT"
  success "Ruby $RUBY_VERSION compiled"

  # ── Phase 3: Copy Ruby runtime ───────────────────────────────────────────
  header "Phase 3: Copy Ruby runtime to resources/ruby-arm64/"

  rm -rf "$RUBY_DEST"
  mkdir -p "$RUBY_DEST/bin" "$RUBY_DEST/lib"

  info "Copying ruby binaries (ruby, bundle, gem, ...)..."
  cp "$RUBY_INSTALL_DIR/bin/"* "$RUBY_DEST/bin/"

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

  info "Copying Ruby headers (needed to compile C extension gems in Phase 6)..."
  cp -R "$RUBY_INSTALL_DIR/include" "$RUBY_DEST/include"

  # rbconfig.rb embeds the absolute temp prefix used during compilation.
  # Update it to point at $RUBY_DEST so that extconf.rb-based gem builds
  # (e.g. io-console, sqlite3) can find ruby.h at the correct location.
  info "Updating rbconfig.rb paths..."
  RBCONFIG_PATH=$(find "$RUBY_DEST/lib/ruby/$RUBY_VERSION" \
    -name "rbconfig.rb" 2>/dev/null | head -1)
  if [[ -n "$RBCONFIG_PATH" ]]; then
    sed -i '' "s|${RUBY_INSTALL_DIR}|${RUBY_DEST}|g" "$RBCONFIG_PATH"
  fi

  info "Trimming unused files..."
  find "$RUBY_DEST" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
  find "$RUBY_DEST" -name "*.ri"   -delete 2>/dev/null || true
  find "$RUBY_DEST" -name "*.rdoc" -delete 2>/dev/null || true
  rm -rf "$RUBY_DEST/lib/ruby/$RUBY_VERSION/rdoc"
  rm -rf "$RUBY_DEST/share" 2>/dev/null || true
  # NOTE: include/ is intentionally kept here; it is removed after Phase 6.

  success "Ruby runtime copied ($(du -sh "$RUBY_DEST" | cut -f1))"
fi

# From here, RUBY_DEST is guaranteed to exist.
LIBRUBY_NAME=$(ls "$RUBY_DEST/lib/" \
  | grep "libruby.*\.dylib" | grep -v "^libruby\.dylib$" | head -1)
LIBRUBY_PATH="$RUBY_DEST/lib/$LIBRUBY_NAME"
[[ -z "$LIBRUBY_NAME" ]] && error "Could not find libruby dylib in $RUBY_DEST/lib/"
info "Using libruby: $LIBRUBY_NAME"

success "Phase 2 + 3 complete"

# Remove stdlib json from the bundled Ruby — it conflicts with the json gem in
# vendor/bundle. Ruby 4.0 ships json 2.18.0 whose json/common.rb unconditionally
# accesses JSON::Ext::Generator::GeneratorMethods (no const_defined? guard).
# json 2.19.1 in vendor/bundle guards that access correctly. When both are on
# $LOAD_PATH, the stdlib common.rb wins (RUBYLIB is prepended before Bundler
# activates gems), causing: NameError: uninitialized constant
# JSON::Ext::Generator::GeneratorMethods. Removing stdlib json forces Ruby to
# use the gem version exclusively. Bundler/bundle exec provide json 2.19.1 for
# Phases 6-8 and the final app.
info "Removing stdlib json (superseded by json 2.19.1 in vendor/bundle)..."
rm -rf \
  "$RUBY_DEST/lib/ruby/$RUBY_VERSION/json.rb" \
  "$RUBY_DEST/lib/ruby/$RUBY_VERSION/json" \
  "$RUBY_DEST/lib/ruby/$RUBY_VERSION/arm64-darwin/json"

# Use the bundled Ruby for all subsequent bundle/gem invocations so that the
# correct bundler version (matching Gemfile.lock) is used, not the system Ruby.
if [[ ! -f "$RUBY_DEST/bin/bundle" ]]; then
  error "Bundled Ruby is missing bin/bundle. Delete $RUBY_DEST and rerun to rebuild."
fi
export PATH="$RUBY_DEST/bin:$PATH"
info "Using bundled Ruby: $("$RUBY_DEST/bin/ruby" --version)"

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

# ── Phase 5b: Ad-hoc codesign before first execution ─────────────────────────
# Apple Silicon requires all executables to be signed before the kernel will
# run them. install_name_tool (Phase 5) invalidates any existing signature, so
# we must re-sign here — before Phases 6-8 execute the bundled ruby/bundle.
# Phase 9 will re-sign again with --force after gem extension path fixes.
header "Phase 5b: Ad-hoc codesign Ruby runtime (required on Apple Silicon)"

info "Codesigning dylibs..."
codesign_tree "$DYLIB_DEST"

info "Codesigning Ruby binaries..."
find "$RUBY_DEST/bin" -type f -exec chmod u+w {} \; 2>/dev/null || true
find "$RUBY_DEST/bin" -type f -exec codesign --force --sign - {} \; 2>/dev/null || true

info "Codesigning stdlib .bundle extensions..."
codesign_tree "$RUBY_DEST/lib/ruby"

success "Phase 5b complete — Ruby runtime signed"

# ── Phase 6: Vendor Rails gems ────────────────────────────────────────────────
header "Phase 6: Vendor Rails gems (bundle install --deployment)"

cd "$WEBAPP_DIR"

# Restore Ruby headers if missing (removed at end of a previous Phase 6 run).
# Headers are required to compile native C extension gems (e.g. sqlite3).
# On the first run, Phase 3 copies them; on re-runs, we restore from system Ruby.
if [[ ! -d "$RUBY_DEST/include" ]]; then
  # Strip the bundled Ruby from PATH to find the original system Ruby
  SYSTEM_RUBY=$(PATH="${PATH#$RUBY_DEST/bin:}" which ruby 2>/dev/null || true)
  if [[ -n "$SYSTEM_RUBY" && -x "$SYSTEM_RUBY" ]]; then
    SYSTEM_HDR=$("$SYSTEM_RUBY" -e "puts RbConfig::CONFIG['rubyhdrdir']" 2>/dev/null || true)
    if [[ -n "$SYSTEM_HDR" && -d "$SYSTEM_HDR" ]]; then
      info "Restoring Ruby headers from system Ruby ($SYSTEM_RUBY)..."
      mkdir -p "$RUBY_DEST/include"
      cp -R "$SYSTEM_HDR" "$RUBY_DEST/include/"

      # The bundled Ruby was compiled with --target=aarch64-apple-darwin, so its
      # arch subdir is "arm64-darwin" (no macOS version suffix). The system Ruby
      # installed via ruby-install may have "arm64-darwin24" (or similar). Create
      # a symlink so extconf.rb/make can find the arch-specific config.h.
      BUNDLED_ARCH=$("$RUBY_DEST/bin/ruby" -e "puts RbConfig::CONFIG['arch']" 2>/dev/null || true)
      SYSTEM_ARCH=$("$SYSTEM_RUBY" -e "puts RbConfig::CONFIG['arch']" 2>/dev/null || true)
      HDR_SUBDIR="$RUBY_DEST/include/ruby-$RUBY_VERSION"
      if [[ -n "$BUNDLED_ARCH" && -n "$SYSTEM_ARCH" \
          && "$BUNDLED_ARCH" != "$SYSTEM_ARCH" \
          && -d "$HDR_SUBDIR/$SYSTEM_ARCH" \
          && ! -e "$HDR_SUBDIR/$BUNDLED_ARCH" ]]; then
        info "Creating arch header symlink: $BUNDLED_ARCH -> $SYSTEM_ARCH"
        ln -sf "$SYSTEM_ARCH" "$HDR_SUBDIR/$BUNDLED_ARCH"
      fi
    else
      error "Cannot locate Ruby headers. Delete $RUBY_DEST and rerun to rebuild Ruby from source."
    fi
  else
    error "Cannot find system Ruby to restore headers. Delete $RUBY_DEST and rerun."
  fi
fi

# Ensure arm64-darwin is in the lockfile before deployment-mode install.
bundle lock --add-platform arm64-darwin 2>/dev/null || true

bundle config set --local deployment true
bundle config set --local path         vendor/bundle
bundle config set --local without      "development test desktop"

info "Running bundle install (may take a minute on first run)..."
bundle install

# Gem tarballs unpack files with read-only bits (e.g. 444). Fix immediately
# so every subsequent step — install_name_tool, codesign, Tauri's copy — works.
chmod -R u+w "$WEBAPP_DIR/vendor/bundle" 2>/dev/null || true

# If a previous script run already rewrote native extension paths (Phase 9),
# detect and delete them so `bundle install` recompiles them with original
# absolute Homebrew paths — required for Phases 7+8 which run before Phase 9.
# Rewrites to detect:
#   - libruby: bare name, @loader_path, or @executable_path
#   - Homebrew dylibs (e.g. libyaml in psych): @loader_path
MODIFIED_BUNDLES=0
while IFS= read -r -d '' bundle; do
  _modified=false
  if otool -L "$bundle" 2>/dev/null \
      | grep "libruby" | grep -qE "@loader_path|@executable_path|^[[:space:]]*libruby[^/]"; then
    _modified=true
  fi
  for _hb_dylib in "${HOMEBREW_DYLIBS[@]}"; do
    _hb_name=$(basename "$_hb_dylib")
    if otool -L "$bundle" 2>/dev/null | grep -q "@loader_path/${_hb_name}"; then
      _modified=true
      break
    fi
  done
  if [[ "$_modified" == "true" ]]; then
    rm -f "$bundle"
    MODIFIED_BUNDLES=$((MODIFIED_BUNDLES + 1))
  fi
done < <(find "$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/gems" \
         -name "*.bundle" -print0 2>/dev/null)

# Also clear the extensions cache dir so bundler picks up the deletions
if [[ $MODIFIED_BUNDLES -gt 0 ]]; then
  info "Removed $MODIFIED_BUNDLES modified extension(s); recompiling..."
  rm -rf "$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/extensions"
  bundle install
fi

# Fix native extension platform path mismatch.
# WHY: `bundle install` runs with the system Ruby (e.g. arm64-darwin-24),
# so native gem extensions land in:
#   vendor/bundle/ruby/4.0.0/extensions/arm64-darwin-24/4.0.0/
# Our compiled Ruby reports platform `arm64-darwin` (no darwin version suffix),
# so Bundler looks in:
#   vendor/bundle/ruby/4.0.0/extensions/arm64-darwin/4.0.0/
# A symlink bridges the gap without recompiling anything.
EXT_BASE="$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/extensions"
SYSTEM_PLATFORM=$(ruby -e "puts Gem::Platform.local.to_s" 2>/dev/null || true)
BUNDLED_PLATFORM="arm64-darwin"

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
info "Removing stale bundled dylibs from gem and extension directories..."
GEMS_DIR="$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/gems"
EXT_DIR="$WEBAPP_DIR/vendor/bundle/ruby/$RUBY_VERSION/extensions"
for search_dir in "$GEMS_DIR" "$EXT_DIR"; do
  [[ -d "$search_dir" ]] || continue
  # libruby must NOT be co-located with extensions (causes dual Ruby VM).
  find "$search_dir" -name "libruby*.dylib" -delete 2>/dev/null || true
  for _hb_dylib in "${HOMEBREW_DYLIBS[@]}"; do
    find "$search_dir" -name "$(basename "$_hb_dylib")" -delete 2>/dev/null || true
  done
done

# Headers were needed only to compile C extension gems above.
# Strip them now so they don't end up in the app bundle.
info "Removing Ruby headers (not needed in final bundle)..."
rm -rf "$RUBY_DEST/include"

cd "$PROJECT_ROOT"
success "Phase 6 complete — gems vendored"

# A stable key for Phases 7+8. Rails boots to precompile assets / prepare DBs
# and needs secret_key_base even though no sessions are involved at this step.
BUNDLE_SECRET_KEY_BASE=$(openssl rand -hex 64)

# ── Phase 7: Precompile assets ────────────────────────────────────────────────
header "Phase 7: Precompile assets (RAILS_ENV=desktop)"

cd "$WEBAPP_DIR"
info "Running assets:precompile..."
SECRET_KEY_BASE="$BUNDLE_SECRET_KEY_BASE" \
  RAILS_ENV=desktop DESKTOP_MODE=true bundle exec bin/rails assets:precompile
cd "$PROJECT_ROOT"
success "Phase 7 complete — assets precompiled"

# ── Phase 8: Prepare databases ────────────────────────────────────────────────
header "Phase 8: Prepare databases (RAILS_ENV=desktop)"

cd "$WEBAPP_DIR"
info "Running db:prepare (creates primary, cache, queue, cable)..."
SECRET_KEY_BASE="$BUNDLE_SECRET_KEY_BASE" \
  RAILS_ENV=desktop DESKTOP_MODE=true bundle exec bin/rails db:prepare
cd "$PROJECT_ROOT"
success "Phase 8 complete — databases prepared"

# ── Phase 9: Verify + ad-hoc codesign ────────────────────────────────────────
header "Phase 9: Verification and ad-hoc codesign"

ERRORS=0

# Unlock any stale Tauri codesign artifacts from a previous build run
unlock_tauri_targets

# Fix native gem extension dylib paths NOW — after Phases 7+8 have finished
# using the system ruby. Phases 7+8 run with the system ruby and must load gems
# against the system libruby. Rewriting those references beforehand causes
# "linked to incompatible libruby" errors because our compiled libruby and
# the system libruby have different UUIDs even though both report Ruby 4.0.0.
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
