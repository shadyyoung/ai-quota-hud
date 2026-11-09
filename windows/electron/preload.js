'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('hud', {
  getItems: () => ipcRenderer.invoke('get-items'),
  refresh: () => ipcRenderer.invoke('refresh'),
  getSettings: () => ipcRenderer.invoke('get-settings'),
  saveSettings: (patch) => ipcRenderer.invoke('save-settings', patch),
  setMenuOpen: (open) => ipcRenderer.invoke('set-menu-open', open),
  openConfigDir: () => ipcRenderer.invoke('open-config-dir'),
  showMenu: () => ipcRenderer.invoke('show-menu'),
  getAvatar: () => ipcRenderer.invoke('get-avatar'),
  onAvatar: (cb) => ipcRenderer.on('avatar', (_e, v) => cb(v)),
  dragStart: () => ipcRenderer.send('drag-start'),
  dragEnd: () => ipcRenderer.send('drag-end'),
  onDragging: (cb) => ipcRenderer.on('dragging', (_e, v) => cb(v)),
  quit: () => ipcRenderer.invoke('quit'),

  onItems: (cb) => ipcRenderer.on('items', (_e, v) => cb(v)),
  onExpanded: (cb) => ipcRenderer.on('expanded', (_e, v) => cb(v)),
  onAlpha: (cb) => ipcRenderer.on('alpha', (_e, v) => cb(v)),
});
