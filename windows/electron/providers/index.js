'use strict';

/**
 * 数据源汇总。每个 provider 导出 { id, name, accent, fetch() -> QuotaItem }
 * QuotaItem: { id, name, accent, primary, secondary, remaining|null, status, badge|null }
 */

const codex = require('./codex');
const cursor = require('./cursor');
const workbuddy = require('./workbuddy');
const custom = require('./custom');

const BUILTIN = [codex, cursor, workbuddy];

async function collect() {
  const items = [];

  for (const p of BUILTIN) {
    try {
      items.push(await p.fetch());
    } catch (e) {
      items.push({
        id: p.id,
        name: p.name,
        accent: p.accent,
        primary: '--',
        secondary: '读取失败',
        remaining: null,
        status: 'unavailable',
        badge: null,
      });
      console.error(`[${p.id}]`, e.message);
    }
  }

  try {
    items.push(...(await custom.loadAll()));
  } catch (e) {
    console.error('[custom]', e.message);
  }

  return items;
}

module.exports = { collect };
