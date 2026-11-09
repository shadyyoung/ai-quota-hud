'use strict';

/**
 * Codex / ChatGPT 额度
 *  实时：读 %USERPROFILE%\.codex\auth.json 的 token，请求官方额度接口
 *        走 Electron 的 net 模块（自动使用系统代理）
 *  兜底：从 sessions/**\*.jsonl 里读最近的 rate_limits 快照
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { net } = require('electron');

const CODEX_DIR = path.join(os.homedir(), '.codex');

function readAuth() {
  try {
    const j = JSON.parse(fs.readFileSync(path.join(CODEX_DIR, 'auth.json'), 'utf8'));
    const t = j.tokens || {};
    if (t.access_token && t.account_id) {
      return { token: t.access_token, account: t.account_id };
    }
  } catch (_) {}
  return null;
}

function httpGet(url, headers, timeoutMs = 8000) {
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

function windowLabel(minutes) {
  if (minutes === 300) return '5 小时额度';
  if (minutes === 10080) return '周额度';
  if (minutes === 43200) return '月额度';
  if (minutes < 60) return `${minutes} 分钟额度`;
  if (minutes < 1440) return `${Math.round(minutes / 60)} 小时额度`;
  return `${Math.round(minutes / 1440)} 天额度`;
}

function resetText(date) {
  if (!date) return '';
  const ms = date.getTime() - Date.now();
  if (ms <= 0) return '已重置';
  const mins = Math.floor(ms / 60000);
  const d = Math.floor(mins / 1440);
  const h = Math.floor((mins % 1440) / 60);
  const m = mins % 60;
  if (d > 0) return `${d} 天 ${h} 小时后重置`;
  if (h > 0) return `${h} 小时 ${m} 分后重置`;
  return `${m} 分钟后重置`;
}

function pctText(r) {
  const p = r * 100;
  if (p >= 99.5) return '100%';
  if (p < 10) return p.toFixed(1) + '%';
  return Math.round(p) + '%';
}

async function fetchLive() {
  const auth = readAuth();
  if (!auth) return null;
  try {
    const res = await httpGet('https://chatgpt.com/backend-api/wham/usage', {
      Authorization: 'Bearer ' + auth.token,
      'chatgpt-account-id': auth.account,
      'User-Agent': 'codex_cli_rs/0.100.0',
      Accept: 'application/json',
    });
    if (res.status < 200 || res.status >= 300) return null;
    const j = JSON.parse(res.body);
    const pw = j.rate_limit && j.rate_limit.primary_window;
    if (!pw) return null;

    const used = Number(pw.used_percent) || 0;
    const windowSec = Number(pw.limit_window_seconds) || 0;
    const resetAt = pw.reset_at ? new Date(pw.reset_at * 1000) : null;

    let remaining = Math.max(0, Math.min(1, 1 - used / 100));
    let rt = resetText(resetAt);
    if (resetAt && resetAt.getTime() <= Date.now()) {
      remaining = 1;
      rt = '已重置';
    }

    const parts = [];
    if (j.plan_type) parts.push(`${j.plan_type} 计划`);
    if (windowSec > 0) parts.push(windowLabel(windowSec / 60));
    if (rt) parts.push(rt);

    return {
      id: 'codex',
      name: 'Codex',
      accent: 'blue',
      primary: '剩余 ' + pctText(remaining),
      secondary: parts.join(' · '),
      remaining,
      status: 'live',
      badge: null,
    };
  } catch (_) {
    return null;
  }
}

function fetchCached() {
  const dir = path.join(CODEX_DIR, 'sessions');
  if (!fs.existsSync(dir)) return null;

  const files = [];
  (function walk(d) {
    let entries;
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch (_) {
      return;
    }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.jsonl')) {
        try {
          files.push({ p, m: fs.statSync(p).mtimeMs });
        } catch (_) {}
      }
    }
  })(dir);

  files.sort((a, b) => b.m - a.m);

  for (const f of files.slice(0, 40)) {
    let text;
    try {
      text = fs.readFileSync(f.p, 'utf8');
    } catch (_) {
      continue;
    }
    const lines = text.split('\n').filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes('"rate_limits"')) continue;
      try {
        const o = JSON.parse(lines[i]);
        const rl = o.payload && o.payload.rate_limits;
        const pw = rl && rl.primary;
        if (!pw) continue;

        const used = Number(pw.used_percent) || 0;
        const windowMinutes = Number(pw.window_minutes) || 0;
        const resetAt = pw.resets_at ? new Date(pw.resets_at * 1000) : null;

        let remaining = Math.max(0, Math.min(1, 1 - used / 100));
        let rt = resetText(resetAt);
        if (resetAt && resetAt.getTime() <= Date.now()) {
          remaining = 1;
          rt = '已重置';
        }

        const ageDays = Math.floor((Date.now() - f.m) / 86400000);
        const parts = [windowLabel(windowMinutes)];
        if (rt) parts.push(rt);

        return {
          id: 'codex',
          name: 'Codex',
          accent: 'blue',
          primary: '剩余 ' + pctText(remaining),
          secondary: parts.join(' · '),
          remaining,
          status: 'local',
          badge: ageDays > 0 ? `快照 ${ageDays} 天前` : null,
        };
      } catch (_) {}
    }
  }
  return null;
}

module.exports = {
  id: 'codex',
  name: 'Codex',
  accent: 'blue',
  async fetch() {
    const live = await fetchLive();
    if (live) return live;
    const cached = fetchCached();
    if (cached) return cached;
    return {
      id: 'codex',
      name: 'Codex',
      accent: 'blue',
      primary: '--',
      secondary: '未找到 Codex 登录记录',
      remaining: null,
      status: 'unavailable',
      badge: null,
    };
  },
};
