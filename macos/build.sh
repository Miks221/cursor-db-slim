#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/macos/Sources"
BUILD="$ROOT/macos/build"
DIST="$ROOT/dist"
APPNAME="Cursor 数据库清理"
APP="$DIST/${APPNAME}.app"
MIN=13.0
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 图标
ICON_SRC="$ROOT/macos/AppIcon.png"
if [[ ! -f "$ICON_SRC" ]]; then
  ICON_SRC="$HOME/.cursor/projects/empty-window/assets/app-icon-1024.png"
fi
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

compile() {
  local arch="$1"
  local out="$2"
  xcrun swiftc -Osize -whole-module-optimization -parse-as-library \
    -target "${arch}-apple-macos${MIN}" \
    -sdk "$SDK" \
    -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
    -lsqlite3 \
    "$SRC"/*.swift \
    -o "$out"
}

echo "编译 arm64 …"
compile arm64 "$BUILD/CursorDBCleaner-arm64"
echo "编译 x86_64 …"
compile x86_64 "$BUILD/CursorDBCleaner-x86_64"
lipo -create -output "$APP/Contents/MacOS/CursorDBCleaner" \
  "$BUILD/CursorDBCleaner-arm64" "$BUILD/CursorDBCleaner-x86_64"
strip -x "$APP/Contents/MacOS/CursorDBCleaner"

cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string CursorDBCleaner "$APP/Contents/Info.plist"

# 去掉扩展属性，adhoc 签名便于拷到别的 Mac
xattr -cr "$APP" || true
codesign --force --deep --sign - "$APP"

echo
echo "完成：$APP"
du -sh "$APP"
lipo -info "$APP/Contents/MacOS/CursorDBCleaner"
