#!/bin/bash
# 安装 AI 额度悬浮窗：复制到 ~/Applications + 设置开机自启
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AIQuotaHUD"
SRC="build/${APP_NAME}.app"
DEST="$HOME/Applications/${APP_NAME}.app"
PLIST="$HOME/Library/LaunchAgents/com.kai.aiquota.plist"

if [ ! -d "$SRC" ]; then
  echo "还没编译，先构建…"
  ./build.sh
fi

mkdir -p "$HOME/Applications" "$(dirname "$PLIST")"

# 停掉旧实例
pkill -f "${APP_NAME}.app/Contents/MacOS" 2>/dev/null || true
sleep 0.5

rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "✅ 已复制到 $DEST"

# 开机自启
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.kai.aiquota</string>
    <key>ProgramArguments</key>
    <array><string>${DEST}/Contents/MacOS/${APP_NAME}</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
echo "✅ 已设置开机自启：$PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST" 2>/dev/null || true

sleep 1
open "$DEST" 2>/dev/null || true

echo ""
echo "全局快捷键：⌥⌘A（Option + Command + A）唤起卡片 5 秒"
