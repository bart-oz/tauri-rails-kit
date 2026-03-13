#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Generate Tauri app icons from a 1024x1024 source PNG
#
# Usage:
#   ./scripts/generate-icons.sh                  # generates placeholder
#   ./scripts/generate-icons.sh path/to/icon.png # uses your own icon
#
# Requirements: macOS, node_modules installed (npm install)
# ============================================================

SOURCE="${1:-}"

if [ -z "$SOURCE" ]; then
  echo "→ No source provided — generating placeholder..."
  SOURCE="$(mktemp /tmp/trk_icon_XXXXXX.png)"
  ruby - "$SOURCE" <<'EOF'
require 'zlib'

# .b forces binary (ASCII-8BIT) encoding — required when mixing string literals
# with pack() output, which is always binary in Ruby.
def png_chunk(name, data)
  body = name.b + data
  [data.bytesize].pack('N') + body + [Zlib.crc32(body)].pack('N')
end

path = ARGV[0]
ihdr = png_chunk('IHDR', [1024, 1024, 8, 6, 0, 0, 0].pack('N2C5'))
row  = "\x00".b + ([71, 85, 105, 255] * 1024).pack('C*')   # slate-grey RGBA
idat = png_chunk('IDAT', Zlib::Deflate.deflate(row * 1024, Zlib::BEST_COMPRESSION))
iend = png_chunk('IEND', ''.b)

File.binwrite(path, "\x89PNG\r\n\x1a\n".b + ihdr + idat + iend)
EOF
  CLEANUP=1
  echo "  Placeholder written"
else
  if [ ! -f "$SOURCE" ]; then
    echo "Error: source file not found: $SOURCE"
    exit 1
  fi
  CLEANUP=0
fi

echo "→ Generating icons via Tauri CLI..."
npx tauri icon "$SOURCE"

if [ "$CLEANUP" = "1" ]; then
  rm -f "$SOURCE"
fi

echo ""
echo "✓ Icons generated in desktop/icons"
ls -lh desktop/icons/
