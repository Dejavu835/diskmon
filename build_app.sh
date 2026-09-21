#!/bin/bash
# fire 5: 手工打 diskmon.app bundle + 验签 + 打 DMG
# SOP §6.2 + 主人 brief §4
set -euo pipefail

ROOT="/Volumes/applelog/diskmon"
APP="$ROOT/dist/diskmon.app"
DIST="$ROOT/dist"
BUILD_BUNDLE="$ROOT/.build/release/diskmon_diskmon.bundle"

cd "$ROOT"

echo "=== 1) Swift release build ==="
swift build -c release 2>&1 | tail -3

if [ ! -f ".build/release/diskmon" ]; then
    echo "ERROR: .build/release/diskmon not found"
    exit 1
fi

BIN_SIZE=$(du -h ".build/release/diskmon" | cut -f1)
echo "  binary size: $BIN_SIZE"
file .build/release/diskmon

echo ""
echo "=== 2) 打 .app bundle ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 拷二进制
cp .build/release/diskmon "$APP/Contents/MacOS/diskmon"
chmod +x "$APP/Contents/MacOS/diskmon"

# 拷 Info.plist
cp Sources/diskmon/Resources/Info.plist "$APP/Contents/Info.plist"

# 注:entitlements 不拷进 .app(只 codesign --entitlements 用)
# 否则 codesign 会把 entitlements 文件当 subcomponent 报 "In subcomponent" 错

# 拷 SPM 抽出的资源(bundle — 含 Assets.xcassets,Fonts,en.lproj,zh-Hans.lproj)
# v0.2.0: Package.swift 已声明 .process("Resources/en.lproj") 和 zh-Hans.lproj,
# SPM 自动把 .lproj 抽到 $BUILD_BUNDLE 根下,这里 cp -R 一并拷走
if [ -d "$BUILD_BUNDLE" ]; then
    cp -R "$BUILD_BUNDLE"/ "$APP/Contents/Resources/"
    echo "  copied SPM bundle: $BUILD_BUNDLE"
    ls "$APP/Contents/Resources/" | head -20
fi

# v0.6.1 polish-F: ATS 字体路径修复(grok 调研)
# Info.plist ATSApplicationFontsPath = Fonts,要求 TTF 在 Resources/Fonts/ 下
# 但 SPM .process("Resources/Fonts") 会把 TTFs 抽到 bundle root(扁平),
# 直接 cp -R 后 TTFs 落在 Resources/*.ttf,ATS 找不到 → SwiftUI 走 SF Pro fallback
# 修复:把 TTF 集中到 Resources/Fonts/ 子目录,ATS 才能注册成功
mkdir -p "$APP/Contents/Resources/Fonts"
FONT_MOVED=0
if [ -d "$BUILD_BUNDLE/Contents/Resources/Fonts" ]; then
    # 防御:万一以后 SPM 版本把 Fonts 子目录保留下来,直接拷
    cp -R "$BUILD_BUNDLE/Contents/Resources/Fonts/" "$APP/Contents/Resources/Fonts/"
    FONT_MOVED=$(find "$APP/Contents/Resources/Fonts" -name "*.ttf" | wc -l | tr -d ' ')
elif [ -d "$BUILD_BUNDLE/Fonts" ]; then
    # 防御:bundle 根下的 Fonts/ 子目录(SPM 早期版本行为)
    cp -R "$BUILD_BUNDLE/Fonts/" "$APP/Contents/Resources/Fonts/"
    FONT_MOVED=$(find "$APP/Contents/Resources/Fonts" -name "*.ttf" | wc -l | tr -d ' ')
else
    # 当前 SPM 行为:TTFs 被抽到 bundle 根,find + mv 集中
    find "$APP/Contents/Resources" -maxdepth 1 -name "*.ttf" -exec mv {} "$APP/Contents/Resources/Fonts/" \;
    FONT_MOVED=$(find "$APP/Contents/Resources/Fonts" -name "*.ttf" | wc -l | tr -d ' ')
fi
echo "  fonts moved to Resources/Fonts/: $FONT_MOVED ttf"
ls "$APP/Contents/Resources/Fonts/" 2>&1
# 验证:Fraunces-Variable.ttf + Fraunces-Italic.ttf 必须在
if [ ! -f "$APP/Contents/Resources/Fonts/Fraunces-Variable.ttf" ] || [ ! -f "$APP/Contents/Resources/Fonts/Fraunces-Italic.ttf" ]; then
    echo "  WARNING: Fraunces TTFs missing from Resources/Fonts/ — SwiftUI will fall back to SF Pro"
fi

# PkgInfo(8 字节 "APPL????")
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "  bundle structure:"
find "$APP" -type f | head -20

echo ""
echo "=== 3) 验证 Mach-O ==="
file "$APP/Contents/MacOS/diskmon"

echo ""
echo "=== 4) Bundle 大小 ==="
APP_SIZE=$(du -sh "$APP" | cut -f1)
echo "  diskmon.app: $APP_SIZE"
du -sh "$APP/Contents/Resources/" "$APP/Contents/MacOS/" 2>&1

echo ""
echo "=== 5) codesign(见 brief §6) ==="
IDENTITY=$(security find-identity -p codesigning -v 2>&1 | grep "Developer ID Application" | head -1 | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/' || true)

if [ -n "$IDENTITY" ]; then
    echo "  Developer ID found: $IDENTITY"
    codesign --deep --force --options=runtime \
        --entitlements Sources/diskmon/Resources/diskmon.entitlements \
        --sign "$IDENTITY" "$APP" || echo "  ⚠️ codesign with Developer ID failed"
    echo "  signed with Developer ID"
else
    echo "  ⚠️ no Developer ID found, ad-hoc sign only"
    # ad-hoc sign 不加 entitlements + --options=runtime(那是 hardened runtime,需要 Developer ID)
    codesign --force --sign - "$APP" || echo "  ⚠️ ad-hoc sign failed"
    echo "  ad-hoc signed (no notarization possible without Developer ID)"
fi

echo ""
echo "=== 6) 验签 ==="
codesign -dvv "$APP" 2>&1 | head -10 || echo "  ⚠️ codesign verify failed"

echo ""
echo "=== 7) DMG ==="
# v0.2.0: 版本号从 CFBundleShortVersionString 取,但这里 hard-code 更稳
# 因为 build_app.sh 在编译时,plist 已经定下来;直接 hard-code 0.6.0
# v0.6.0: TopBar fix + hot-plug ExFAT/NTFS + Chart readability + HealthPredictor SMART + 字体
# v0.7.0: SMART 字段全 optional + HealthPredictor 3 bug 修 + Power State 真值解析
# v0.8.0: LinkHealthService + DiagnosticTestService + BenchmarkService + FSIntegrityService
# v0.9.0: DiskDetailView 模块化重做 (macOS CC widget 风格) + EditMode iOS Control Center 风格
# v0.9.1: MenuBarLabel.sparkline 修假 sin 波 → 真 SwiftData 24h 温度历史 +
#         DiskPickerView 整合到 Popover 顶栏 + TopBar leadingAccessory/trailingAccessory 顺序修
# v0.9.2: polish-Q 错误处理 — 3 Service 显式 error enum + 3 View alert + FDA 引导
# v0.9.3: polish-R 健康 UX 升级 + minimax-A Test/Benchmark 4 态 + minimax-B 健康 UX 升级
#       + minimax-C TipKit 5 步 onboarding + What's New sheet
# v0.9.4: minimax-fix-ux — widget layout Grid+GridRow / TemperatureModule 3 态 (no sensor/—/no data)
#         / selectedDisk 切盘联动 / WindowGroup .contentMinSize + .windowToolbarStyle
DMG_PATH="$DIST/diskmon-0.9.4.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "DiskMon" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH" 2>&1 | tail -3

if [ -f "$DMG_PATH" ]; then
    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo "  DMG: $DMG_PATH ($DMG_SIZE)"
fi

echo ""
echo "=== 8) 公证(见 brief §7) ==="
KEYCHAIN_PROFILE="diskmon-notary"
if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" 2>/dev/null | grep -q "submission"; then
    echo "  notary profile found, attempting submission..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    echo "  notarized + stapled"
else
    echo "  ⚠️ no notary profile, skipping notarize"
    echo "  to enable: xcrun notarytool store-credentials diskmon-notary --apple-id <id> --team-id <team> --password <app-pwd>"
fi

echo ""
echo "=== 9) 最终状态 ==="
ls -la "$DIST"
echo ""
echo "DONE"
