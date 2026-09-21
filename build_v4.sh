#!/bin/bash
# Package diskmon v4 into dist/v4/ without touching dist/diskmon.app (0.9.18 baseline).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST_V4="$ROOT/dist/v4"
APP="$DIST_V4/diskmon.app"
BUILD_BUNDLE="$ROOT/.build/release/diskmon_diskmon.bundle"

cd "$ROOT"

echo "=== 1) Swift release build ==="
# Hide this machine's volume path from #filePath in the shipped binary.
swift build -c release \
    -Xswiftc -file-prefix-map -Xswiftc "${ROOT}=diskmon" \
    -Xswiftc -debug-prefix-map -Xswiftc "${ROOT}=diskmon" \
    2>&1 | tail -8

if [ ! -f ".build/release/diskmon" ]; then
    echo "ERROR: .build/release/diskmon not found"
    exit 1
fi

echo ""
echo "=== 2) Package $APP (baseline dist/diskmon.app is not touched) ==="
mkdir -p "$DIST_V4"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/diskmon "$APP/Contents/MacOS/diskmon"
chmod +x "$APP/Contents/MacOS/diskmon"
# Strip local symbols only — no visual/runtime change, smaller Mach-O.
strip -x -S "$APP/Contents/MacOS/diskmon" || true

cp Sources/diskmon/Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 4.0.1" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 4.0.1" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName DiskMon 4" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName diskmon-v4" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.homecenter.diskmon.v4" "$APP/Contents/Info.plist"

if [ -d "$BUILD_BUNDLE" ]; then
    cp -R "$BUILD_BUNDLE"/ "$APP/Contents/Resources/"
fi

mkdir -p "$APP/Contents/Resources/Fonts"
if [ -d "$BUILD_BUNDLE/Fonts" ]; then
    cp -R "$BUILD_BUNDLE/Fonts/" "$APP/Contents/Resources/Fonts/"
else
    find "$APP/Contents/Resources" -maxdepth 1 -name "*.ttf" -exec mv {} "$APP/Contents/Resources/Fonts/" \; || true
fi

ICONSET="$ROOT/.build/AppIcon.iconset"
ICONSRC="$ROOT/Sources/diskmon/Resources/Assets.xcassets/AppIcon.appiconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for f in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
         icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
         icon_512x512.png icon_512x512@2x.png; do
    cp "$ICONSRC/$f" "$ICONSET/$f"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Bundle NTFSKit formatter (GPL-2.0 mkntfs + .fs personality). Do not touch baseline app.
NTFS_FS="$ROOT/Sources/diskmon/Resources/ntfskit.fs"
if [ ! -d "$NTFS_FS" ]; then
    NTFS_FS="$ROOT/vendor/ntfskit/fsbundle/ntfskit.fs"
fi
if [ -d "$NTFS_FS" ]; then
    rm -rf "$APP/Contents/Resources/ntfskit.fs"
    cp -R "$NTFS_FS" "$APP/Contents/Resources/ntfskit.fs"
    chmod +x "$APP/Contents/Resources/ntfskit.fs/Contents/Resources/mkntfs" \
             "$APP/Contents/Resources/ntfskit.fs/Contents/Resources/newfs_ntfskit"
    echo "  bundled ntfskit.fs + mkntfs (GPL-2.0)"
fi
if [ -f "$ROOT/Sources/diskmon/Resources/NTFSKit-LICENSE.GPL2" ]; then
    cp "$ROOT/Sources/diskmon/Resources/NTFSKit-LICENSE.GPL2" "$APP/Contents/Resources/NTFSKit-LICENSE.GPL2"
elif [ -f "$ROOT/vendor/ntfskit/NTFSModule/LICENSE.GPL2" ]; then
    cp "$ROOT/vendor/ntfskit/NTFSModule/LICENSE.GPL2" "$APP/Contents/Resources/NTFSKit-LICENSE.GPL2"
fi

# Compile NTFSKit FSKit module (GPL-2.0 libntfs-3g) and embed in this app.
echo ""
echo "=== 2b) NTFSKit FSKit appex ==="
NTFS_PROJ="$ROOT/vendor/ntfskit/NTFSKitDiskMon.xcodeproj"
NTFS_DD="$ROOT/.build/ntfsmodule"
NTFS_APPEX=""
if [ -d "$NTFS_PROJ" ]; then
    set +e
    xcodebuild -project "$NTFS_PROJ" -scheme NTFSModule -configuration Release \
        -derivedDataPath "$NTFS_DD" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="-" \
        build 2>&1 | tail -40
    XC_STATUS=${PIPESTATUS[0]}
    set -e
    NTFS_APPEX=$(find "$NTFS_DD/Build/Products" -name "NTFSModule.appex" -type d | head -1 || true)
    if [ "$XC_STATUS" -eq 0 ] && [ -n "$NTFS_APPEX" ] && [ -d "$NTFS_APPEX" ]; then
        mkdir -p "$APP/Contents/PlugIns"
        rm -rf "$APP/Contents/PlugIns/NTFSModule.appex"
        cp -R "$NTFS_APPEX" "$APP/Contents/PlugIns/NTFSModule.appex"
        echo "  embedded NTFSModule.appex (GPL-2.0 NTFSKit / libntfs-3g)"
    else
        echo "  ⚠️ NTFSModule.appex did not build (format still uses bundled mkntfs)"
    fi
else
    echo "  ⚠️ NTFSKit xcodeproj missing"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ExFAT copies leave AppleDouble `._*` / Finder .DS_Store; codesign treats ._ as unsigned Mach-O.
find "$APP" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

echo ""
echo "=== 3) codesign (ad-hoc) ==="
if [ -d "$APP/Contents/PlugIns/NTFSModule.appex" ]; then
    codesign --force --sign - --entitlements "$ROOT/vendor/ntfskit/NTFSModule/NTFSModule.entitlements" \
        "$APP/Contents/PlugIns/NTFSModule.appex" || echo "  ⚠️ appex sign failed"
fi
if [ -x "$APP/Contents/Resources/ntfskit.fs/Contents/Resources/mkntfs" ]; then
    codesign --force --sign - "$APP/Contents/Resources/ntfskit.fs/Contents/Resources/mkntfs" || true
fi
codesign --force --sign - "$APP" || echo "  ⚠️ ad-hoc sign failed"

echo ""
echo "=== 4) DMG (stage on APFS so ExFAT AppleDouble is not packed) ==="
DMG_PATH="$DIST_V4/diskmon-4.0.1.dmg"
rm -f "$DMG_PATH"
STAGE="$(mktemp -d /tmp/diskmon-dmg.XXXXXX)"
ditto "$APP" "$STAGE/diskmon.app"
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete
codesign --force --sign - "$STAGE/diskmon.app" >/dev/null 2>&1 || true
hdiutil create -volname "DiskMon 4" -srcfolder "$STAGE/diskmon.app" -ov -format UDZO "$DMG_PATH" 2>&1 | tail -3
rm -rf "$STAGE"

echo ""
echo "=== 5) versions ==="
echo -n "baseline dist/diskmon.app: "
defaults read "$ROOT/dist/diskmon.app/Contents/Info" CFBundleShortVersionString
echo -n "v4 dist/v4/diskmon.app: "
defaults read "$APP/Contents/Info" CFBundleShortVersionString

echo ""
echo "DONE v4 -> $APP"
ls -la "$DIST_V4"
