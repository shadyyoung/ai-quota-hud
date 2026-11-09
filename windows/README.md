# AI 额度悬浮窗 · Windows 版

macOS 版的功能移植版，使用 Electron 实现（macOS 版是原生 Swift/AppKit）。

## 功能对照

| 功能 | macOS 版 | Windows 版 |
|---|---|---|
| 透明无边框置顶 | Swift/AppKit | Electron |
| 平时收成细线 | 10pt | 10px |
| 点击穿透 | 原生 | 主进程轮询鼠标位置 |
| 鼠标靠近展开 | ✅ | ✅ |
| 全局快捷键 | ⌥⌘A | **Ctrl+Alt+A** |
| 开机自启 | LaunchAgent | `app.setLoginItemSettings` |
| Codex 额度 | ✅ 实时 | ✅ 实时（net 模块自动走系统代理） |
| Cursor 额度 | ✅ | ✅（需 SQLite 模块） |
| WorkBuddy 积分 | ✅ 锚点扣减 | ✅ 锚点扣减 |
| 自定义数据源 | JSON | JSON（`%APPDATA%\ai-quota-hud\providers.json`） |
| 托盘菜单 | — | ✅ |

## 开发运行

```bash
cd windows
npm install
npm start
```

## 打包

```bash
npm run build
```

产物在 `dist/`：NSIS 安装包 + 便携版 exe。

## 数据源路径（Windows）

| 服务 | 路径 |
|---|---|
| Codex | `%USERPROFILE%\.codex\auth.json`<br>`%USERPROFILE%\.codex\sessions\**\*.jsonl` |
| Cursor | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` |
| WorkBuddy | `%USERPROFILE%\.workbuddy\workbuddy.db` |
| 自定义配置 | `%APPDATA%\ai-quota-hud\providers.json` |

## 已知限制（诚实说明）

1. **Cursor / WorkBuddy 依赖 `better-sqlite3`**（原生模块）。安装时如果编译失败，这两个服务会显示「需要 SQLite 模块」，其余功能不受影响。
2. **透明窗口在 Windows 上依赖显卡驱动**。极少数机器可能出现黑底，可用托盘菜单关掉阴影（默认已关）。
3. **Codex 需要系统代理**。应用使用 Electron 的 `net` 模块，会自动走 Windows 系统代理设置。
4. **应用未签名**。首次运行时 Windows SmartScreen 会警告，点「更多信息 → 仍要运行」。

## 项目结构

```
windows/
  electron/
    main.js           主进程：窗口、穿透、托盘、快捷键
    preload.js        IPC 桥
    providers/
      index.js        数据源汇总
      codex.js        Codex（实时 + 快照兜底）
      cursor.js       Cursor（SQLite）
      workbuddy.js    WorkBuddy（锚点扣减）
      custom.js       自定义 JSON 数据源
  renderer/
    index.html
    style.css         Liquid Glass 视觉
    renderer.js       渲染
  build/              图标
  package.json
```
