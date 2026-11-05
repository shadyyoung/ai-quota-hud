#!/bin/bash
# 双击即可启动 AI 额度悬浮窗
cd "$(dirname "$0")"

if [ ! -d "build/AIQuotaHUD.app" ]; then
  echo "还没编译，先构建…"
  ./build.sh || { echo "构建失败"; read -r -p "按回车退出"; exit 1; }
fi

# 已在运行就先退出旧的，保证是当前版本
pkill -f "AIQuotaHUD.app/Contents/MacOS" 2>/dev/null
sleep 0.5
open build/AIQuotaHUD.app
echo "已启动，看屏幕右上角。右键卡片可刷新 / 校准 / 退出。"
