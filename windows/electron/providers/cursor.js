'use strict';

/**
 * Cursor 额度
 *  读 %APPDATA%\Cursor\User\globalStorage\state.vscdb（SQLite）
 *  取 cursorAuth/accessToken，请求 api2.cursor.sh/auth/usage
 *
 *  better-sqlite3 是原生模块，加载失败时优雅降级为「不可用」。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { net } = require('electron');

let Database = null;
try {
  Database = require('better-sqlite3');
} catch (e) {
  console.error('[cursor] better-sqlite3 不可用:', e.message);
}

function dbPath() {
  const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(appData, 'Cursor', 'User', 'globalStorage', 'state.vscdb');
}

function readToken() {
  if (!Database) return null;
  const p = dbPath();
  if (!fs.existsSync(p)) return null;
  try {
    const db = new Database(p, { readonly: true, fileMustExist: true });
    const row = db
      .prepare("select value from ItemTable where key = 'cursorAuth/accessToken' limit 1")
      .get();
    db.close();
    if (!row || !row.value) return null;
    return Buffer.isBuffer(row.value) ? row.value.toString('utf8') : String(row.value);
  } catch (e) {
    console.error('[cursor] 读 token 失败:', e.message);
    return null;
  }
}

function httpGet(url, headers, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const req = net.request({ url, method: 'GET', redirect: 'follow' });
    for (const [k, v] of Object.entries(headers)) req.setHeader(k, v);
    const timer = setTimeout(() => {
      try { req.abort(); } catch (_) {}
      reject(new Error('timeout'));
    }, timeoutMs);
    req.on('response', (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        clearTimeout(timer);
        resolve({ status: res.statusCode, body: data });
      });
    });
    req.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
    req.end();
  });
}

function resetText(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  const ms = d.getTime() - Date.now();
  if (ms <= 0) return '';
  const days = Math.floor(ms / 86400000);
  const hours = Math.floor((ms % 86400000) / 3600000);
  if (days > 0) return `${days} 天 ${hours} 小时后重置`;
  return `${hours} 小时后重置`;
}

module.exports = {
  id: 'cursor',
  name: 'Cursor',
  accent: 'purple',
  async fetch() {
    const base = {
      id: 'cursor',
      name: 'Cursor',
      accent: 'purple',
      remaining: null,
      badge: null,
    };

    if (!Database) {
      return { ...base, primary: '--', secondary: 'Windows 版暂不支持读取（需 SQLite）', status: 'unavailable' };
    }

    const token = readToken();
    if (!token) {
      return { ...base, primary: '--', secondary: '未找到 Cursor 登录态', status: 'unavailable' };
    }

    const auth = { Authorization: 'Bearer ' + token };
    try {
      const res = await httpGet('https://api2.cursor.sh/auth/usage', auth);
      if (res.status < 200 || res.status >= 300) {
        return { ...base, primary: '--', secondary: '请求失败，可能需要重新登录', status: 'unavailable' };
      }
      const j = JSON.parse(res.body);
      const gpt4 = j['gpt-4'] || {};
      const used = Number(gpt4.numRequests) || 0;
      const maxReq = gpt4.maxRequestUsage != null ? Number(gpt4.maxRequestUsage) : null;
      const start = j.startOfMonth ? new Date(j.startOfMonth) : null;

      let reset = '';
      if (start && !isNaN(start.getTime())) {
        const next = new Date(start);
        next.setMonth(next.getMonth() + 1);
        const ms = next.getTime() - Date.now();
        const days = Math.floor(ms / 86400000);
        if (days > 0) reset = `${days} 天后重置`;
      }

      if (maxReq && maxReq > 0) {
        const remaining = Math.max(0, Math.min(1, (maxReq - used) / maxReq));
        const parts = [`${used}/${maxReq} 次`];
        if (reset) parts.push(reset);
        return {
          ...base,
          primary: '剩余 ' + Math.round(remaining * 100) + '%',
          secondary: parts.join(' · '),
          remaining,
          status: 'live',
        };
      }

      const parts = [`本月 ${used} 次请求`];
      if (reset) parts.push(reset);
      return {
        ...base,
        primary: `${used} 次`,
        secondary: 'free 计划 · ' + parts.join(' · '),
        status: 'live',
      };
    } catch (e) {
      return { ...base, primary: '--', secondary: '网络请求失败', status: 'unavailable' };
    }
  },
};
