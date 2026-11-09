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

const { app, BrowserWindow, ipcMain, screen, Tray, Menu, globalShortcut, shell } = require('electron');
const path = require('path');
const fs = require('fs');

const CARD_WIDTH = 278;
const CARD_HEIGHT = 210;
const COLLAPSED_HEIGHT = 10;
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
    width: CARD_WIDTH,
    height: CARD_HEIGHT,
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
  const height = on ? CARD_HEIGHT : COLLAPSED_HEIGHT;

  // 顶部固定：收起时保持 y 不动，只改高度
  win.setBounds({ x, y, width: CARD_WIDTH, height }, false);
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

// ---------------------------------------------------------------- 托盘 / 菜单

let expandedByMenu = false;

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
