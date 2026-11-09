'use strict';

/**
 * WorkBuddy 额度（腾讯）
 *
 * 云端额度没有公开接口。和 macOS 版一致，采用「锚点 + 本地扣减」：
 *   在设置里填一次当前剩余积分 → 之后按 workbuddy.db 的新增消耗扣减。
 * 从未设置锚点时，退化为显示「近 30 天消耗」。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { app } = require('electron');

let Database = null;
try {
  Database = require('better-sqlite3');
} catch (e) {
  console.error('[workbuddy] better-sqlite3 不可用:', e.message);
}

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

/** 每个会话当前累计消耗的积分 */
function creditBySession(db) {
  const rows = db.prepare('select session_id, credit_json from session_usage').all();
  const out = {};
  for (const r of rows) {
    let sum = 0;
    try {
      const obj = r.credit_json ? JSON.parse(r.credit_json) : {};
      for (const v of Object.values(obj)) sum += Number(v) || 0;
    } catch (_) {}
    out[r.session_id] = sum;
  }
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
    if (!Database) {
      return { ...base, primary: '--', secondary: 'Windows 版暂不支持读取（需 SQLite）', status: 'unavailable' };
    }

    let db;
    try {
      db = new Database(DB_PATH, { readonly: true, fileMustExist: true });
    } catch (e) {
      return { ...base, primary: '--', secondary: '数据库读取失败', status: 'unavailable' };
    }

    try {
      const settings = loadSettings();
      const anchor = settings.workbuddyAnchor;

      if (anchor && anchor.credits != null) {
        // 锚点 + 增量
        const current = creditBySession(db);
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
          // 供设置面板使用
          raw: { remainingCredits, delta, anchor },
        };
      }

      // 无锚点：近 30 天消耗
      const cutoff = Date.now() - 30 * 86400000;
      const rows = db
        .prepare('select session_id, credit_json, updated_at from session_usage where updated_at > ?')
        .all(cutoff);
      let total = 0;
      for (const r of rows) {
        try {
          const obj = r.credit_json ? JSON.parse(r.credit_json) : {};
          for (const v of Object.values(obj)) total += Number(v) || 0;
        } catch (_) {}
      }
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
        secondary: `近 30 天消耗 · 右键托盘设置剩余积分`,
        status: 'local',
      };
    } finally {
      try { db.close(); } catch (_) {}
    }
  },

  /** 供设置面板调用：抓一份当前基线 */
  captureBaseline() {
    if (!fs.existsSync(DB_PATH) || !Database) return null;
    let db;
    try {
      db = new Database(DB_PATH, { readonly: true, fileMustExist: true });
      const baseline = creditBySession(db);
      db.close();
      return baseline;
    } catch (_) {
      return null;
    }
  },

  saveAnchor(credits) {
    const baseline = this.captureBaseline() || {};
    saveSettings({
      workbuddyAnchor: { credits: Number(credits), baseline, at: Date.now() },
    });
  },
};
