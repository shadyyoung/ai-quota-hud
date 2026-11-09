'use strict';

/**
 * WorkBuddy 额度（腾讯）
 *
 * 云端额度没有公开接口。和 macOS 版一致，采用「锚点 + 本地扣减」：
 *   在设置里填一次当前剩余积分 → 之后按 workbuddy.db 的新增消耗扣减。
 * 从未设置锚点时，退化为显示「近 30 天消耗」。
 *
 * 用纯 WASM 的 sql.js 读数据库，不需要原生编译。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { app } = require('electron');
const sqlite = require('./sqlite');

const DB_PATH = path.join(os.homedir(), '.workbuddy', 'workbuddy.db');

function settingsFile() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function loadSettings() {
  try {
    return JSON.parse(fs.readFileSync(settingsFile(), 'utf8'));
  } catch (_) {
    return {};
  }
}

function saveSettings(patch) {
  const next = { ...loadSettings(), ...patch };
  try {
    fs.mkdirSync(path.dirname(settingsFile()), { recursive: true });
    fs.writeFileSync(settingsFile(), JSON.stringify(next, null, 2));
  } catch (_) {}
  return next;
}

function sumCredits(row) {
  let sum = 0;
  try {
    const obj = row && row.credit_json ? JSON.parse(row.credit_json) : {};
    for (const v of Object.values(obj)) sum += Number(v) || 0;
  } catch (_) {}
  return sum;
}

async function creditBySession() {
  const rows = await sqlite.query(DB_PATH, 'select session_id, credit_json from session_usage');
  const out = {};
  for (const r of rows) out[r.session_id] = sumCredits(r);
  return out;
}

function fmt(v) {
  return (Math.round(v * 10) / 10).toFixed(1);
}

module.exports = {
  id: 'workbuddy',
  name: 'WorkBuddy',
  accent: 'teal',
  async fetch() {
    const base = {
      id: 'workbuddy',
      name: 'WorkBuddy',
      accent: 'teal',
      remaining: null,
      badge: null,
    };

    if (!fs.existsSync(DB_PATH)) {
      return { ...base, primary: '--', secondary: '未找到 WorkBuddy 数据', status: 'unavailable' };
    }

    try {
      const settings = loadSettings();
      const anchor = settings.workbuddyAnchor;

      if (anchor && anchor.credits != null) {
        const current = await creditBySession();
        let delta = 0;
        for (const [sid, cur] of Object.entries(current)) {
          const b = (anchor.baseline && anchor.baseline[sid]) || 0;
          delta += Math.max(0, cur - b);
        }
        const remainingCredits = Math.max(0, anchor.credits - delta);
        const days = Math.floor((Date.now() - (anchor.at || Date.now())) / 86400000);
        const parts = [`校准后消耗 ${fmt(delta)}`];
        if (days > 0) parts.push(`${days} 天前校准`);
        return {
          ...base,
          primary: `${fmt(remainingCredits)} 积分`,
          secondary: parts.join(' · '),
          status: 'live',
          badge: '本地扣减',
        };
      }

      const cutoff = Date.now() - 30 * 86400000;
      const rows = await sqlite.query(
        DB_PATH,
        'select session_id, credit_json from session_usage where updated_at > ?',
        [cutoff]
      );
      let total = 0;
      for (const r of rows) total += sumCredits(r);

      if (total <= 0 && rows.length === 0) {
        return {
          ...base,
          primary: '--',
          secondary: '右键托盘 → 设置 WorkBuddy 剩余积分',
          status: 'unavailable',
        };
      }
      return {
        ...base,
        primary: `${fmt(total)} 积分`,
        secondary: '近 30 天消耗 · 右键托盘设置剩余积分',
        status: 'local',
      };
    } catch (e) {
      console.error('[workbuddy]', e.message);
      return { ...base, primary: '--', secondary: '数据库读取失败', status: 'unavailable' };
    }
  },

  async captureBaseline() {
    if (!fs.existsSync(DB_PATH)) return null;
    try {
      return await creditBySession();
    } catch (_) {
      return null;
    }
  },

  async saveAnchor(credits) {
    const baseline = (await this.captureBaseline()) || {};
    saveSettings({
      workbuddyAnchor: { credits: Number(credits), baseline, at: Date.now() },
    });
  },
};
