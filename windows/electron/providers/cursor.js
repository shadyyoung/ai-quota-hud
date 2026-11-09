'use strict';

/**
 * Cursor 额度
 *  读 %APPDATA%\Cursor\User\globalStorage\state.vscdb（SQLite）
 *  取 cursorAuth/accessToken，请求 api2.cursor.sh/auth/usage
 *
 *  用纯 WASM 的 sql.js 读数据库，不需要原生编译。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { net } = require('electron');
const sqlite = require('./sqlite');

function dbPath() {
  const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(appData, 'Cursor', 'User', 'globalStorage', 'state.vscdb');
}

async function readToken() {
  const p = dbPath();
  if (!fs.existsSync(p)) return null;
  try {
    const rows = await sqlite.query(
      p,
      "select value from ItemTable where key = 'cursorAuth/accessToken' limit 1"
    );
    if (!rows.length) return null;
    const v = rows[0].value;
    if (v == null) return null;
    if (v instanceof Uint8Array) return Buffer.from(v).toString('utf8');
    return String(v);
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

function monthResetText(iso) {
  if (!iso) return '';
  const start = new Date(iso);
  if (isNaN(start.getTime())) return '';
  const next = new Date(start);
  next.setMonth(next.getMonth() + 1);
  const ms = next.getTime() - Date.now();
  const days = Math.floor(ms / 86400000);
  return days > 0 ? `${days} 天后重置` : '';
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

    if (!fs.existsSync(dbPath())) {
      return { ...base, primary: '--', secondary: '未找到 Cursor 数据', status: 'unavailable' };
    }

    const token = await readToken();
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
      const reset = monthResetText(j.startOfMonth);

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
