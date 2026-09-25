#!/bin/sh
# Builds dist/Rookie.app and dist/Rookie.zip: the app, its own Python, python-chess
# and Stockfish, so someone downloading it needs nothing but Ollama.
#
#   ./build-app.sh
#
# Needs, on the machine doing the building: Xcode's command line tools, uv, and
# Homebrew's stockfish. Apple Silicon only.
set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
DIST="$REPO/dist"
APP="$DIST/Rookie.app"
RES="$APP/Contents/Resources"
VERSION="${ROOKIE_VERSION:-0.1.0}"

say() { printf '\n==> %s\n' "$1"; }

say "Swift, release build"
cd "$REPO"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BIN/ChessCoach" "$APP/Contents/MacOS/Rookie"
# SwiftPM's resources (the avatar, piece sets, persona). Bundle.module looks in
# Contents/Resources first.
cp -R "$BIN/ChessCoach_ChessCoach.bundle" "$RES/"
# The GPL travels with the binary, and so do the notices for everything bundled.
cp "$REPO/LICENSE" "$REPO/NOTICE.md" "$RES/"

# The icon: drop a 1024x1024 AppIcon.png at the repo root and it is turned into
# every size macOS asks for. Without one, macOS draws its generic app icon.
if [ -f "$REPO/AppIcon.png" ]; then
    ICONSET="$DIST/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$REPO/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$REPO/AppIcon.png" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
    rm -rf "$ICONSET"
fi

say "The Python half"
mkdir -p "$RES/coachd"
cp "$REPO"/coachd/*.py "$RES/coachd/"

# A relocatable Python. Homebrew's cannot be used: it is welded to /opt/homebrew.
# This is python-build-standalone, the build uv manages.
uv python install 3.14 >/dev/null
PBS="$(uv python find 3.14)"
PYROOT="$(cd "$(dirname "$PBS")/.." && pwd -P)"
cp -R "$PYROOT" "$RES/python"
# Tests, IDLE and tkinter are dead weight for a daemon with no windows.
rm -rf "$RES/python/lib/python3.14/test" "$RES/python/lib/python3.14/idlelib" \
       "$RES/python/lib/python3.14/tkinter" "$RES/python/lib/tcl"* "$RES/python/lib/tk"*

# python-chess goes next to the code rather than into that Python, which is marked
# as managed by uv and refuses installs. Scripts run from coachd/, so Python finds
# it there without any path set.
"$RES/python/bin/python3.14" -m pip install --quiet --disable-pip-version-check \
    --break-system-packages --target "$RES/coachd" chess
find "$RES" -name __pycache__ -type d -prune -exec rm -rf {} +

say "Stockfish"
SF="$(readlink -f "$(command -v stockfish)")"
cp "$SF" "$RES/stockfish"
chmod +x "$RES/stockfish"

say "Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Rookie</string>
    <key>CFBundleDisplayName</key>          <string>Rookie</string>
    <key>CFBundleIdentifier</key>           <string>com.jordanpainter.rookie</string>
    <key>CFBundleExecutable</key>           <string>Rookie</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSArchitecturePriority</key>       <array><string>arm64</string></array>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.board-games</string>
    <key>NSHighResolutionCapable</key>      <true/>
</dict>
</plist>
PLIST

say "Signing (ad hoc)"
# Not a real signature, which needs a paid Apple account. But an app with no
# signature at all, or a broken one, is called "damaged" by macOS and cannot be
# opened; an ad hoc signature gets the ordinary "Open Anyway" instead.
codesign --force --deep --sign - "$APP"

say "Zipping"
rm -f "$DIST/Rookie.zip"
ditto -c -k --keepParent "$APP" "$DIST/Rookie.zip"

say "Done"
du -sh "$APP" "$DIST/Rookie.zip"
