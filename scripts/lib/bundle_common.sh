#!/usr/bin/env bash
# =============================================================================
# scripts/lib/bundle_common.sh
#
# Shared bundling logic sourced by both:
#   scripts/bundle-macos-x86_64.sh  (Intel)
#   scripts/bundle-macos-arm64.sh   (Apple Silicon — future)
#
# Expected variables from caller:
#   ARCH             — "x86_64" or "arm64"
#   HOMEBREW_PREFIX  — "/usr/local" (Intel) or "/opt/homebrew" (ARM64)
#   PROJECT_ROOT     — absolute path to repo root
#   DESKTOP_DIR      — "$PROJECT_ROOT/desktop"
#   WEBAPP_DIR       — "$PROJECT_ROOT/webapp"
#   RUBY_DEST        — destination for the compiled Ruby runtime
# =============================================================================

RUBY_VERSION="4.0.0"

# Homebrew dylibs required by the bundled Ruby runtime.
# Populated after HOMEBREW_PREFIX is confirmed set by the caller.
_init_homebrew_dylibs() {
  HOMEBREW_DYLIBS=(
    "$HOMEBREW_PREFIX/opt/gmp/lib/libgmp.10.dylib"
    "$HOMEBREW_PREFIX/opt/openssl@3/lib/libssl.3.dylib"
    "$HOMEBREW_PREFIX/opt/openssl@3/lib/libcrypto.3.dylib"
    "$HOMEBREW_PREFIX/opt/libyaml/lib/libyaml-0.2.dylib"
    "$HOMEBREW_PREFIX/opt/zlib/lib/libz.1.dylib"
  )
}

# ── Coloured output ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}  ▶ $*${NC}"; }
success() { echo -e "${GREEN}  ✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠️  $*${NC}"; }
error()   { echo -e "${RED}  ❌ $*${NC}"; exit 1; }
header()  { echo -e "\n${BLUE}═══ $* ═══${NC}"; }

# ── check_prerequisites ───────────────────────────────────────────────────────
# Verify arch match, required Homebrew packages, and required CLI tools.
# Caller must set ARCH and HOMEBREW_PREFIX before calling this.
check_prerequisites() {
  local current_arch
  current_arch="$(uname -m)"
  if [[ "$current_arch" != "$ARCH" ]]; then
    error "This script targets $ARCH but running on $current_arch. Use the correct script for this machine."
  fi

  for brew_pkg in gmp openssl@3 libyaml zlib; do
    if [[ ! -d "$HOMEBREW_PREFIX/opt/$brew_pkg" ]]; then
      error "Homebrew package '$brew_pkg' not found at $HOMEBREW_PREFIX/opt/$brew_pkg. Run: brew install $brew_pkg"
    fi
  done

  for tool in install_name_tool codesign otool curl tar; do
    if ! command -v "$tool" &>/dev/null; then
      error "Required tool '$tool' not found. Install Xcode command line tools."
    fi
  done

  success "All prerequisites satisfied"
}

# ── fix_dylib_refs ────────────────────────────────────────────────────────────
# Rewrite absolute Homebrew/libruby references in a single binary.
#
# Args:
#   $1  binary       — path to the binary/dylib to patch
#   $2  ref_prefix   — prefix for the new path (e.g. "@loader_path" or
#                      "@executable_path/../lib")
#
# Requires: HOMEBREW_DYLIBS and LIBRUBY_NAME set in caller scope.
fix_dylib_refs() {
  local binary="$1"
  local ref_prefix="$2"

  for dylib in "${HOMEBREW_DYLIBS[@]}"; do
    local name
    name=$(basename "$dylib")
    local old_path
    old_path=$(otool -L "$binary" 2>/dev/null \
      | grep "$name" | grep -v "@" | awk '{print $1}' || true)
    if [[ -n "$old_path" ]]; then
      install_name_tool -change "$old_path" "${ref_prefix}/${name}" "$binary"
    fi
  done

  local old_libruby
  old_libruby=$(otool -L "$binary" 2>/dev/null \
    | grep "libruby" | grep -v "@" | awk '{print $1}' || true)
  if [[ -n "$old_libruby" ]]; then
    install_name_tool -change "$old_libruby" "${ref_prefix}/${LIBRUBY_NAME}" "$binary"
  fi
}

# ── fix_all_bundle_extensions ─────────────────────────────────────────────────
# Find all .bundle files under $1, compute the relative path to $RUBY_DEST/lib/
# using Ruby's Pathname, then rewrite all absolute dylib refs.
#
# Args:
#   $1  search_root  — directory to search for .bundle files (recursive)
#   $2  strategy     — "relative" (stdlib) or "local" (gem extensions)
#
# "relative"  → @loader_path/<rel_to_lib>/<name>   (stdlib bundles)
# "local"     → @loader_path/<name>  + copy dylib next to .bundle  (gem exts)
#
# Requires: HOMEBREW_DYLIBS, LIBRUBY_NAME, DYLIB_DEST set in caller scope.
fix_all_bundle_extensions() {
  local search_root="$1"
  local strategy="${2:-relative}"
  local count=0

  while IFS= read -r -d '' bundle; do
    local bundle_dir
    bundle_dir=$(dirname "$bundle")
    local fixed_any=false

    if [[ "$strategy" == "relative" ]]; then
      # Compute relative path from this .bundle's directory to lib/ using Ruby
      local rel_to_lib
      rel_to_lib=$("$RUBY_DEST/bin/ruby" -e "
require 'pathname'
puts Pathname.new('$DYLIB_DEST').relative_path_from(Pathname.new('$bundle_dir'))
" 2>/dev/null || python3 -c "
import os.path, sys
print(os.path.relpath('$DYLIB_DEST', '$bundle_dir'))
")

      local old_libruby
      old_libruby=$(otool -L "$bundle" 2>/dev/null \
        | grep "libruby" | grep -v "@" | awk '{print $1}' || true)
      if [[ -n "$old_libruby" ]]; then
        install_name_tool -change "$old_libruby" \
          "@loader_path/$rel_to_lib/$LIBRUBY_NAME" "$bundle"
        fixed_any=true
      fi

      for dylib in "${HOMEBREW_DYLIBS[@]}"; do
        local name
        name=$(basename "$dylib")
        local old_path
        old_path=$(otool -L "$bundle" 2>/dev/null \
          | grep "$name" | grep -v "@" | awk '{print $1}' || true)
        if [[ -n "$old_path" ]]; then
          install_name_tool -change "$old_path" \
            "@loader_path/$rel_to_lib/$name" "$bundle"
          fixed_any=true
        fi
      done

    elif [[ "$strategy" == "local" ]]; then
      # Copy dylibs next to the .bundle and use @loader_path directly.
      #
      # Check for any libruby reference (absolute OR already @loader_path).
      # We must copy libruby + ALL Homebrew dylibs whenever libruby is present,
      # because libruby was rewritten in Phase 5 to use @loader_path/libgmp etc.
      # — those dylibs must be co-located or the transitive dlopen chain breaks.
      # We separate "ensure deps are copied" from "rewrite reference" so this
      # stays idempotent across repeated script runs.
      local any_libruby_ref
      any_libruby_ref=$(otool -L "$bundle" 2>/dev/null \
        | grep "libruby" | awk '{print $1}' || true)
      if [[ -n "$any_libruby_ref" ]]; then
        cp "$DYLIB_DEST/$LIBRUBY_NAME" "$bundle_dir/" 2>/dev/null || true
        for _hb_dylib in "${HOMEBREW_DYLIBS[@]}"; do
          cp "$DYLIB_DEST/$(basename "$_hb_dylib")" "$bundle_dir/" 2>/dev/null || true
        done
        # Only rewrite if the reference is still an absolute path
        local old_libruby
        old_libruby=$(otool -L "$bundle" 2>/dev/null \
          | grep "libruby" | grep -v "@" | awk '{print $1}' || true)
        if [[ -n "$old_libruby" ]]; then
          install_name_tool -change "$old_libruby" \
            "@loader_path/$LIBRUBY_NAME" "$bundle"
        fi
        fixed_any=true
      fi

      for dylib in "${HOMEBREW_DYLIBS[@]}"; do
        local name
        name=$(basename "$dylib")
        local old_path
        old_path=$(otool -L "$bundle" 2>/dev/null \
          | grep "$name" | grep -v "@" | awk '{print $1}' || true)
        if [[ -n "$old_path" ]]; then
          cp "$DYLIB_DEST/$name" "$bundle_dir/" 2>/dev/null || true
          install_name_tool -change "$old_path" \
            "@loader_path/$name" "$bundle"
          fixed_any=true
        fi
      done
    fi

    [[ "$fixed_any" == "true" ]] && count=$((count + 1))
  done < <(find "$search_root" -name "*.bundle" -print0 2>/dev/null)

  echo "$count"
}

# ── codesign_tree ─────────────────────────────────────────────────────────────
# Ad-hoc sign all .dylib, .bundle, .so files and named binaries under $1.
# Also accepts additional explicit paths as extra arguments.
#
# Args:
#   $1  search_root  — directory to sweep for signable files
#   $@  extras       — additional explicit paths to sign (optional)
codesign_tree() {
  local search_root="$1"
  shift

  # Sign extras first (explicit binaries like bin/ruby)
  for extra in "$@"; do
    [[ -f "$extra" ]] || continue
    chmod u+w "$extra" 2>/dev/null || true
    codesign --force --sign - "$extra"
  done

  find "$search_root" \( -name "*.dylib" -o -name "*.bundle" -o -name "*.so" \) \
    -exec chmod u+w {} \; 2>/dev/null || true
  find "$search_root" \( -name "*.dylib" -o -name "*.bundle" -o -name "*.so" \) \
    -exec codesign --force --sign - {} \; 2>/dev/null || true
}

# ── verify_no_absolute_paths ──────────────────────────────────────────────────
# Run otool -L on a binary and warn if non-system absolute paths remain.
# Returns 0 if clean, 1 if warnings found.
#
# Args:
#   $1  binary  — path to check
#   $2  label   — display name for output
verify_no_absolute_paths() {
  local binary="$1"
  local label="$2"

  local bad
  bad=$(otool -L "$binary" 2>/dev/null \
    | grep -v ":" | grep -v "@" \
    | grep -v "/usr/lib/" | grep -v "/System/" \
    | awk '{print $1}' || true)

  if [[ -n "$bad" ]]; then
    warn "$label has absolute paths remaining: $bad"
    return 1
  else
    success "$label: all paths portable"
    return 0
  fi
}

# ── unlock_tauri_targets ──────────────────────────────────────────────────────
# chmod -R u+w on stale Tauri codesign artifacts.
# Tauri's own codesign pass can leave resources read-only; the next build's
# copy step will fail with EACCES unless we restore write permission first.
unlock_tauri_targets() {
  local target_release="$DESKTOP_DIR/target/release"
  local target_debug="$DESKTOP_DIR/target/debug"

  for target_dir in "$target_release" "$target_debug"; do
    if [[ -d "$target_dir/_up_" ]]; then
      chmod -R u+w "$target_dir/_up_/" 2>/dev/null || true
    fi
    if [[ -d "$target_dir/resources" ]]; then
      chmod -R u+w "$target_dir/resources/" 2>/dev/null || true
    fi
  done
}
