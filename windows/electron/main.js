'use strict';

/**
 * AI 额度悬浮窗 —— Windows 版主进程
 *
 * 与 macOS 版行为对齐：
 *  - 无边框透明窗口，始终置顶，不在任务栏显示
 *  - 平时收成一条细线并完全点击穿透
 *  - 鼠标靠近时展开并淡入，此时可以右键/拖动
 *  - 全局快捷键 Ctrl+Alt+A 展开 5 秒
 */

const { app, BrowserWindow, ipcMain, screen, Tray, Menu, globalShortcut, shell, dialog } = require('electron');
const path = require('path');
const fs = require('fs');

const WINDOW_WIDTH = 320;
const CARD_WIDTH = 278;
const CARD_HEIGHT = 252;
const CHARACTER_HEIGHT = 139;                       // 角色露出高度
const OVERLAP = 25;                                 // 角色与卡片的重叠
const FULL_HEIGHT = CHARACTER_HEIGHT + CARD_HEIGHT - OVERLAP;
const COLLAPSED_HEIGHT = CHARACTER_HEIGHT + 10;   // 收起时角色仍趴在细条上
const EXPAND_DELTA = FULL_HEIGHT - COLLAPSED_HEIGHT;
const IDLE_ALPHA = 0.18;
const HOVER_ALPHA = 1.0;

let win = null;
let tray = null;
let inside = false;
let expanded = false;
let tracking = false;      // 启动 3 秒后才允许收起
let flashTimer = null;
let pollTimer = null;
let lastItems = [];

// ---------------------------------------------------------------- 配置读写

const settingsPath = () => path.join(app.getPath('userData'), 'settings.json');

function loadSettings() {
  try {
    return JSON.parse(fs.readFileSync(settingsPath(), 'utf8'));
  } catch {
    return {};
  }
}

function saveSettings(patch) {
  const next = { ...loadSettings(), ...patch };
  try {
    fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
    fs.writeFileSync(settingsPath(), JSON.stringify(next, null, 2));
  } catch (e) {
    console.error('saveSettings failed', e);
  }
  return next;
}

// ---------------------------------------------------------------- 窗口

function createWindow() {
  const { width: sw, height: sh } = screen.getPrimaryDisplay().workAreaSize;
  const saved = loadSettings();

  win = new BrowserWindow({
    width: WINDOW_WIDTH,
    height: FULL_HEIGHT,
    x: saved.x ?? (sw - CARD_WIDTH - 24),
    y: saved.y ?? 24,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    resizable: false,
    movable: true,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hasShadow: false,
    alwaysOnTop: true,
    focusable: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false,
    },
  });

  // 覆盖全屏应用、虚拟桌面
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  win.loadFile(path.join(__dirname, '../renderer/index.html'));

  win.once('ready-to-show', () => {
    win.showInactive();
    setExpanded(true, true);     // 启动先完整展开
    win.webContents.send('alpha', HOVER_ALPHA);
    setTimeout(() => { tracking = true; }, 3000);
  });

  // 记住位置
  win.on('moved', () => {
    const [x, y] = win.getPosition();
    saveSettings({ x, y });
  });

  win.on('closed', () => { win = null; });
  startPointerTracking();
}

// ---------------------------------------------------------------- 展开 / 收起

function setExpanded(on, force = false) {
  if (!win) return;
  if (!force && on === expanded) return;
  expanded = on;

  const [x, y] = win.getPosition();

  // 底部固定：展开时向上长，收起时向下缩
  let newY = on ? y - EXPAND_DELTA : y + EXPAND_DELTA;
  const disp = screen.getDisplayNearestPoint({ x, y }).workArea;
  newY = Math.max(disp.y, Math.min(newY, disp.y + disp.height - (on ? FULL_HEIGHT : COLLAPSED_HEIGHT)));

  win.setBounds({
    x,
    y: newY,
    width: WINDOW_WIDTH,
    height: on ? FULL_HEIGHT : COLLAPSED_HEIGHT,
  }, false);
  win.webContents.send('expanded', on);
  win.webContents.send('alpha', on ? HOVER_ALPHA : IDLE_ALPHA);
}

function flashCard() {
  setExpanded(true);
  if (flashTimer) clearTimeout(flashTimer);
  flashTimer = setTimeout(() => {
    if (!inside && !expandedByMenu) setExpanded(false);
  }, 5000);
}

// ---------------------------------------------------------------- 鼠标穿透轮询

function startPointerTracking() {
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(() => {
    if (!win || !tracking) return;
    if (expandedByMenu) return;
    if (dragging) return;     // 正在拖动，别收起窗口

    const p = screen.getCursorScreenPoint();
    const b = win.getBounds();
    const pad = 12;
    const isInside =
      p.x >= b.x - pad && p.x <= b.x + b.width + pad &&
      p.y >= b.y - pad && p.y <= b.y + b.height + pad;

    if (isInside !== inside) {
      inside = isInside;
      win.setIgnoreMouseEvents(!isInside, { forward: false });
      setExpanded(isInside);
    }
  }, 80);
}

// ---------------------------------------------------------------- 数据

async function refresh() {
  try {
    const { collect } = require('./providers');
    const items = await collect();
    lastItems = items;
    if (win && !win.isDestroyed()) {
      win.webContents.send('items', items);
    }
    if (tray) updateTray(items);
  } catch (e) {
    console.error('refresh failed', e);
  }
}

function updateTray(items) {
  // 托盘 tooltip 显示摘要
  const summary = (items || [])
    .map((i) => `${i.name}: ${i.primary}`)
    .join('\n');
  tray.setToolTip(summary || 'AI 额度');
}

// ---------------------------------------------------------------- 形象（头像）

function builtinAvatarDir() {
  return path.join(__dirname, '../assets/avatars');
}

function userAvatarDir() {
  return path.join(app.getPath('userData'), 'avatars');
}

function listAvatars() {
  const out = [];
  const scan = (dir, prefix) => {
    if (!fs.existsSync(dir)) return;
    let files = [];
    try { files = fs.readdirSync(dir); } catch (_) { return; }
    for (const f of files) {
      if (!/\.(png|jpe?g|gif|webp)$/i.test(f)) continue;
      out.push({
        id: prefix + ':' + f,
        name: path.parse(f).name,
        path: path.join(dir, f),
      });
    }
  };
  scan(builtinAvatarDir(), 'builtin');
  scan(userAvatarDir(), 'user');
  return out;
}

function currentAvatar() {
  const list = listAvatars();
  if (!list.length) return null;
  const want = loadSettings().avatar;
  return list.find((a) => a.id === want) || list[0];
}

function avatarPayload() {
  const a = currentAvatar();
  if (!a) return null;
  let dataUrl = null;
  try {
    const buf = fs.readFileSync(a.path);
    let ext = path.extname(a.path).slice(1).toLowerCase();
    if (ext === 'jpg') ext = 'jpeg';
    dataUrl = `data:image/${ext};base64,${buf.toString('base64')}`;
  } catch (e) {
    console.error('读取形象失败', e.message);
  }
  return {
    id: a.id,
    name: a.name,
    dataUrl,
    list: listAvatars().map((x) => ({ id: x.id, name: x.name })),
  };
}

// ---------------------------------------------------------------- 托盘 / 菜单

let expandedByMenu = false;
let dragging = null;      // { dx, dy } 拖动时光标相对窗口的偏移
let dragTimer = null;

function buildTray() {
  const iconPath = path.join(__dirname, '../build/tray.png');
  let icon = iconPath;
  if (!fs.existsSync(icon)) {
    icon = path.join(__dirname, '../build/icon.png');
  }
  tray = new Tray(icon);
  tray.setToolTip('AI 额度');
  tray.on('click', () => flashCard());
  refreshTrayMenu();
}

function refreshTrayMenu() {
  if (!tray) return;
  const menu = Menu.buildFromTemplate([
    { label: '立即刷新', click: () => refresh() },
    { type: 'separator' },
    {
      label: '平时透明度',
      submenu: [0.08, 0.12, 0.18, 0.25, 0.32].map((a) => ({
        label: `${Math.round(a * 100)}%`,
        type: 'radio',
        checked: Math.abs((loadSettings().idleAlpha ?? IDLE_ALPHA) - a) < 0.005,
        click: () => {
          saveSettings({ idleAlpha: a });
          if (!inside) win.webContents.send('alpha', a);
        },
      })),
    },
    { label: '刷新间隔', submenu: [30, 60, 120, 300].map((s) => ({
      label: `${s} 秒`,
      type: 'radio',
      checked: (loadSettings().refreshInterval ?? 60) === s,
      click: () => {
        saveSettings({ refreshInterval: s });
        scheduleRefresh();
      },
    })) },
    { type: 'separator' },
    {
      label: '开机自动启动',
      type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => {
        app.setLoginItemSettings({ openAtLogin: item.checked });
      },
    },
    {
      label: '形象',
      submenu: (() => {
        const list = listAvatars();
        const cur = currentAvatar();
        const items = list.map((a) => ({
          label: a.name,
          type: 'radio',
          checked: cur && cur.id === a.id,
          click: () => {
            saveSettings({ avatar: a.id });
            if (win && !win.isDestroyed()) {
              win.webContents.send('avatar', avatarPayload());
            }
          },
        }));
        items.push({ type: 'separator' });
        items.push({
          label: '更换形象照片…',
          click: async () => {
            const r = await dialog.showOpenDialog(win, {
              title: '选择形象图片（建议用透明背景 PNG）',
              filters: [{ name: '图片', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'] }],
              properties: ['openFile'],
            });
            if (r.canceled || !r.filePaths[0]) return;
            const src = r.filePaths[0];
            const dir = userAvatarDir();
            try { fs.mkdirSync(dir, { recursive: true }); } catch (_) {}
            const name = 'photo-' + Date.now() + (path.extname(src) || '.png');
            const dest = path.join(dir, name);
            try {
              fs.copyFileSync(src, dest);
            } catch (e) {
              console.error('复制图片失败', e.message);
              return;
            }
            saveSettings({ avatar: 'user:' + name });
            if (win && !win.isDestroyed()) {
              win.webContents.send('avatar', avatarPayload());
            }
          },
        });
        items.push({
          label: '把新图片放进形象文件夹…',
          click: () => {
            const dir = userAvatarDir();
            fs.mkdirSync(dir, { recursive: true });
            shell.openPath(dir);
          },
        });
        return items;
      })(),
    },
    {
      label: '编辑数据源配置',
      click: () => {
        const p = app.getPath('userData');
        const cfg = path.join(p, 'providers.json');
        if (!fs.existsSync(cfg)) {
          fs.writeFileSync(cfg, JSON.stringify({ version: 1, providers: [] }, null, 2));
        }
        shell.openPath(cfg);
      },
    },
    { type: 'separator' },
    { label: '退出', click: () => app.quit() },
  ]);
  tray.setContextMenu(menu);
}

// ---------------------------------------------------------------- 刷新节奏

let refreshTimer = null;

function scheduleRefresh() {
  if (refreshTimer) clearInterval(refreshTimer);
  const sec = loadSettings().refreshInterval ?? 60;
  refreshTimer = setInterval(refresh, sec * 1000);
}

// ---------------------------------------------------------------- 拖动

function startDrag() {
  if (!win || dragging) return;
  const c = screen.getCursorScreenPoint();
  const [wx, wy] = win.getPosition();
  dragging = { dx: c.x - wx, dy: c.y - wy };
  if (dragTimer) clearInterval(dragTimer);
  dragTimer = setInterval(() => {
    if (!dragging || !win || win.isDestroyed()) { endDrag(); return; }
    const p = screen.getCursorScreenPoint();
    win.setPosition(p.x - dragging.dx, p.y - dragging.dy);

    // 兜底：光标离窗口太远，多半是已经松手但没收到 mouseup
    const b = win.getBounds();
    if (p.x < b.x - 500 || p.x > b.x + b.width + 500 ||
        p.y < b.y - 500 || p.y > b.y + b.height + 500) {
      endDrag();
    }
  }, 16);
  win.webContents.send('dragging', true);
}

function endDrag() {
  if (!dragging) return;
  dragging = null;
  if (dragTimer) { clearInterval(dragTimer); dragTimer = null; }
  if (win && !win.isDestroyed()) {
    const [x, y] = win.getPosition();
    saveSettings({ x, y });
    win.webContents.send('dragging', false);
  }
}

// ---------------------------------------------------------------- 生命周期

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => flashCard());

  app.whenReady().then(() => {
    // 无边框透明窗口在 Windows 上要禁用 GPU 合成阴影
    app.commandLine.appendSwitch('enable-transparent-visuals');

    createWindow();
    buildTray();
    scheduleRefresh();
    refresh();

    // 窗口准备好后推头像
    if (win) {
      win.webContents.once('did-finish-load', () => {
        win.webContents.send('avatar', avatarPayload());
      });
    }

    globalShortcut.register('Control+Alt+A', () => flashCard());

    ipcMain.handle('get-items', () => lastItems);
    ipcMain.handle('refresh', async () => { await refresh(); return lastItems; });
    ipcMain.handle('get-settings', () => loadSettings());
    ipcMain.handle('save-settings', (_e, patch) => saveSettings(patch));
    ipcMain.handle('set-menu-open', (_e, open) => {
      expandedByMenu = open;
      if (open) setExpanded(true);
    });
    ipcMain.handle('show-menu', () => {
      expandedByMenu = true;
      setExpanded(true);
      refreshTrayMenu();
      if (tray) tray.popUpContextMenu();
      setTimeout(() => { expandedByMenu = false; }, 800);
    });
    ipcMain.handle('get-avatar', () => avatarPayload());
    ipcMain.on('drag-start', () => startDrag());
    ipcMain.on('drag-end', () => endDrag());
    ipcMain.handle('quit', () => app.quit());
    ipcMain.handle('open-config-dir', () => {
      shell.openPath(app.getPath('userData'));
    });
  });

  app.on('window-all-closed', () => { /* 托盘常驻，不退出 */ });
  app.on('will-quit', () => {
    globalShortcut.unregisterAll();
    if (pollTimer) clearInterval(pollTimer);
    if (refreshTimer) clearInterval(refreshTimer);
  });
}
