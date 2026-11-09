'use strict';

/**
 * 用户自定义数据源：<userData>/providers.json
 *
 * 支持三种类型：
 *   http    —— 请求接口，按点路径提取额度
 *   command —— 执行命令，stdout 为数字或 JSON
 *   manual  —— 纯手动（暂未实现，会显示不可用）
 */

const fs = require('fs');
const path = require('path');
const { app, net } = require('electron');
const { exec } = require('child_process');

const ACCENTS = ['blue', 'purple', 'teal', 'indigo', 'orange', 'gray'];

function configPath() {
  return path.join(app.getPath('userData'), 'providers.json');
}

function readConfig() {
  const p = configPath();
  if (!fs.existsSync(p)) {
    // 写一份空的示例
    try {
      const example = {
        version: 1,
        providers: [
          {
            id: 'kimi',
            name: 'Kimi',
            accent: 'orange',
            type: 'http',
            url: 'https://api.moonshot.cn/v1/users/me/balance',
            headers: { Authorization: 'Bearer ${key}' },
            apiKey: '',
            remainingPath: 'data.available_balance',
            totalPath: 'data.cash_balance',
            display: 'value',
            unit: '¥',
            enabled: false,
          },
        ],
      };
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, JSON.stringify(example, null, 2));
    } catch (_) {}
    return { providers: [] };
  }
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    console.error('[custom] providers.json 解析失败:', e.message);
    return { providers: [] };
  }
}

function jsonPath(obj, dotPath) {
  if (!dotPath) return undefined;
  let cur = obj;
  for (const part of dotPath.split('.')) {
    if (cur == null) return undefined;
    cur = cur[part];
  }
  return cur;
}

function httpGet(url, headers, timeoutMs = 12000) {
  return new Promise((resolve, reject) => {
    const req = net.request({ url, method: 'GET', redirect: 'follow' });
    for (const [k, v] of Object.entries(headers || {})) req.setHeader(k, v);
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

function execAsync(cmd, timeoutMs = 12000) {
  return new Promise((resolve, reject) => {
    exec(cmd, { timeout: timeoutMs, maxBuffer: 1024 * 1024 }, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

function pctText(r) {
  const p = r * 100;
  if (p >= 99.5) return '100%';
  if (p < 10) return p.toFixed(1) + '%';
  return Math.round(p) + '%';
}

function baseItem(cfg) {
  return {
    id: cfg.id,
    name: cfg.name || cfg.id,
    accent: ACCENTS.includes(cfg.accent) ? cfg.accent : 'blue',
    remaining: null,
    badge: null,
  };
}

async function fetchOne(cfg) {
  const base = baseItem(cfg);
  const type = (cfg.type || 'http').toLowerCase();

  if (type === 'http') {
    const key = cfg.apiKey || '';
    if (cfg.headers && Object.values(cfg.headers).some((v) => String(v).includes('${key}')) && !key) {
      return { ...base, primary: '--', secondary: '未填 API Key', status: 'unavailable' };
    }
    const headers = {};
    for (const [k, v] of Object.entries(cfg.headers || {})) {
      headers[k] = String(v).replace(/\$\{key\}/g, key);
    }
    const res = await httpGet(cfg.url, headers);
    if (res.status < 200 || res.status >= 300) {
      return { ...base, primary: '--', secondary: `请求失败 HTTP ${res.status}`, status: 'unavailable' };
    }
    const obj = JSON.parse(res.body);
    return buildFromJson(cfg, obj);
  }

  if (type === 'command') {
    const out = await execAsync(cfg.command);
    const trimmed = String(out).trim();
    const asNumber = Number(trimmed);
    if (!isNaN(asNumber) && trimmed !== '') {
      return { ...base, primary: `${asNumber}`, secondary: '来自命令', status: 'live' };
    }
    const obj = JSON.parse(trimmed);
    return buildFromJson(cfg, obj);
  }

  return { ...base, primary: '--', secondary: '手动类型暂未支持', status: 'unavailable' };
}

function buildFromJson(cfg, obj) {
  const base = baseItem(cfg);

  // 百分比模式
  if (cfg.percentPath) {
    const raw = Number(jsonPath(obj, cfg.percentPath));
    if (!isNaN(raw)) {
      const ratio = raw > 1 ? raw / 100 : raw;
      return {
        ...base,
        primary: '剩余 ' + pctText(ratio),
        secondary: '实时',
        remaining: Math.max(0, Math.min(1, ratio)),
        status: 'live',
      };
    }
  }

  // 绝对值模式
  const remainRaw = Number(jsonPath(obj, cfg.remainingPath));
  if (isNaN(remainRaw)) {
    return { ...base, primary: '--', secondary: '返回里找不到额度字段', status: 'unavailable' };
  }

  const unit = cfg.unit || '';
  const display = (cfg.display || 'value').toLowerCase();

  if (display === 'percent') {
    const total = Number(jsonPath(obj, cfg.totalPath));
    const ratio = total > 0 ? Math.max(0, Math.min(1, remainRaw / total)) : 0;
    return { ...base, primary: '剩余 ' + pctText(ratio), secondary: '实时', remaining: ratio, status: 'live' };
  }

  let text;
  if (unit === '¥' || unit === '$') text = `${unit} ${remainRaw.toFixed(2)}`;
  else if (unit) text = `${remainRaw.toFixed(1)} ${unit}`;
  else text = `${remainRaw.toFixed(1)}`;

  let ratio = null;
  const total = Number(jsonPath(obj, cfg.totalPath));
  if (total > 0) ratio = Math.max(0, Math.min(1, remainRaw / total));

  return { ...base, primary: text, secondary: '实时', remaining: ratio, status: 'live' };
}

async function loadAll() {
  const cfg = readConfig();
  const list = (cfg.providers || []).filter((p) => p.enabled !== false);
  const out = [];
  for (const p of list) {
    try {
      out.push(await fetchOne(p));
    } catch (e) {
      out.push({
        ...baseItem(p),
        primary: '--',
        secondary: '读取失败: ' + e.message.slice(0, 40),
        status: 'unavailable',
      });
    }
  }
  return out;
}

module.exports = { loadAll, configPath, readConfig };
