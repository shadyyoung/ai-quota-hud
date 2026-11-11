#!/bin/bash
# 构建 AI 额度悬浮窗
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AIQuotaHUD"
APP="build/${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"

rm -rf build
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" build/.mc

echo "==> 编译 Swift 源码"
swiftc -swift-version 5 -O \
  -module-cache-path "$(pwd)/build/.mc" \
  Sources/Models.swift \
  Sources/SettingsWindow.swift \
  Sources/Updater.swift \
  Sources/Notifier.swift \
  Sources/JsonProvider.swift \
  Sources/AppSettings.swift \
  Sources/ProxyConfig.swift \
  Sources/Calibration.swift \
  Sources/Providers.swift \
  Sources/Collector.swift \
  Sources/LayoutConfig.swift \
  Sources/HUDView.swift \
  Sources/CharacterProcessor.swift \
  Sources/CodexTaskWatcher.swift \
  Sources/AIDetector.swift \
  Sources/Snapshot.swift \
  Sources/AppDelegate.swift \
  Sources/main.swift \
  -o "$BIN"

echo "==> 生成 App 图标"
swiftc -swift-version 5 -module-cache-path "$(pwd)/build/.mc" -O \
  Sources/IconGen.swift -o build/icongen
build/icongen build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "${APP}/Contents/Resources/"
echo "    ✓ AppIcon.icns"

echo "==> 打包形象资源"
mkdir -p "${APP}/Contents/Resources/avatars"
if [ -d "assets/avatars" ]; then
  cp assets/avatars/*.png "${APP}/Contents/Resources/avatars/" 2>/dev/null || true
  cp assets/avatars/*.jpg "${APP}/Contents/Resources/avatars/" 2>/dev/null || true
  ls "${APP}/Contents/Resources/avatars/" | head -5
fi

echo "==> 写入 Info.plist"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AI 额度</string>
    <key>CFBundleDisplayName</key><string>AI 额度</string>
    <key>CFBundleExecutable</key><string>AIQuotaHUD</string>
    <key>CFBundleIdentifier</key><string>com.kai.aiquota</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>本地额度监控 · 数据不离开本机</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (签名失败，直接运行仍可用)"

echo "==> 完成: $APP"
ls -lh "$BIN"
