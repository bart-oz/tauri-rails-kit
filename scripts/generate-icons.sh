#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Generate Tauri app icons from a 1024x1024 source PNG
#
# Usage:
#   ./scripts/generate-icons.sh                  # generates placeholder
#   ./scripts/generate-icons.sh path/to/icon.png # uses your own icon
#
# Requirements: macOS (uses sips + iconutil, both built-in)
# ============================================================

ICONS_DIR="desktop/icons"
CUSTOM_SOURCE="${1:-}"

mkdir -p "$ICONS_DIR"

# ============================================================
# Phase 1: Source image
# ============================================================
echo "→ Preparing source image..."

if [ -n "$CUSTOM_SOURCE" ]; then
  if [ ! -f "$CUSTOM_SOURCE" ]; then
    echo "Error: source file not found at $CUSTOM_SOURCE"
    exit 1
  fi
  SOURCE="$CUSTOM_SOURCE"
  echo "  Using $SOURCE"
else
  SOURCE="$ICONS_DIR/source_1024.png"
  python3 - << 'EOF'
import struct, zlib

def make_png(width, height, color):
    def chunk(name, data):
        c = name + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    r, g, b = color
    raw = b''.join(b'\x00' + bytes([r, g, b] * width) for _ in range(height))
    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw))
        + chunk(b'IEND', b'')
    )

with open('desktop/icons/source_1024.png', 'wb') as f:
    f.write(make_png(1024, 1024, (71, 85, 105)))
EOF
  echo "  Generated placeholder 1024x1024 PNG"
fi

# ============================================================
# Phase 2: PNG sizes required by Tauri
# ============================================================
echo "→ Generating PNG sizes..."

sips -z 32 32     "$SOURCE" --out "$ICONS_DIR/32x32.png"       > /dev/null
sips -z 128 128   "$SOURCE" --out "$ICONS_DIR/128x128.png"     > /dev/null
sips -z 256 256   "$SOURCE" --out "$ICONS_DIR/128x128@2x.png"  > /dev/null
sips -z 1024 1024 "$SOURCE" --out "$ICONS_DIR/icon.png"        > /dev/null

echo "✓ PNG sizes generated"

# ============================================================
# Phase 3: icon.icns (macOS)
# ============================================================
echo "→ Generating icon.icns..."

ICONSET="$ICONS_DIR/icon.iconset"
mkdir -p "$ICONSET"

sips -z 16   16   "$SOURCE" --out "$ICONSET/icon_16x16.png"       > /dev/null
sips -z 32   32   "$SOURCE" --out "$ICONSET/icon_16x16@2x.png"    > /dev/null
sips -z 32   32   "$SOURCE" --out "$ICONSET/icon_32x32.png"       > /dev/null
sips -z 64   64   "$SOURCE" --out "$ICONSET/icon_32x32@2x.png"    > /dev/null
sips -z 128  128  "$SOURCE" --out "$ICONSET/icon_128x128.png"     > /dev/null
sips -z 256  256  "$SOURCE" --out "$ICONSET/icon_128x128@2x.png"  > /dev/null
sips -z 256  256  "$SOURCE" --out "$ICONSET/icon_256x256.png"     > /dev/null
sips -z 512  512  "$SOURCE" --out "$ICONSET/icon_256x256@2x.png"  > /dev/null
sips -z 512  512  "$SOURCE" --out "$ICONSET/icon_512x512.png"     > /dev/null
sips -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png"  > /dev/null

iconutil -c icns "$ICONSET" -o "$ICONS_DIR/icon.icns"
rm -rf "$ICONSET"

echo "✓ icon.icns generated"

# ============================================================
# Phase 4: icon.ico (Windows — included for Tauri config completeness)
# ============================================================
echo "→ Generating icon.ico..."

python3 - << 'EOF'
import struct, zlib

def make_png(w, h, color):
    def chunk(name, data):
        c = name + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    r, g, b = color
    raw = b''.join(b'\x00' + bytes([r, g, b] * w) for _ in range(h))
    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw))
        + chunk(b'IEND', b'')
    )

png = make_png(32, 32, (71, 85, 105))
offset = 6 + 16
header = struct.pack('<HHH', 0, 1, 1)
entry  = struct.pack('<BBBBHHII', 32, 32, 0, 0, 1, 32, len(png), offset)

with open('desktop/icons/icon.ico', 'wb') as f:
    f.write(header + entry + png)
EOF

echo "✓ icon.ico generated"

# ============================================================
# Cleanup placeholder source (not needed after generation)
# ============================================================
if [ -z "$CUSTOM_SOURCE" ]; then
  rm -f "$ICONS_DIR/source_1024.png"
fi

echo ""
echo "✓ All icons generated in $ICONS_DIR"
echo ""
ls -lh "$ICONS_DIR"
