'use strict';

/**
 * SQLite 读取工具（纯 WASM，无原生编译）
 *
 * 用 sql.js 在内存里打开数据库文件执行只读查询。
 * 这样 Cursor / WorkBuddy 的数据在 Windows 上也能读，
 * 而且不需要 node-gyp / Visual Studio。
 */

const fs = require('fs');
const path = require('path');
const { app } = require('electron');

let SQLPromise = null;

function wasmPath() {
  // 优先用模块解析（打包进 asar 后也能用）
  try {
    return require.resolve('sql.js/dist/sql-wasm.wasm');
  } catch (_) {
    // 兜底：相对 node_modules
    const candidates = [
      path.join(app.getAppPath(), 'node_modules/sql.js/dist/sql-wasm.wasm'),
      path.join(__dirname, '../../node_modules/sql.js/dist/sql-wasm.wasm'),
    ];
    for (const p of candidates) {
      if (fs.existsSync(p)) return p;
    }
    return candidates[0];
  }
}

async function getSQL() {
  if (!SQLPromise) {
    SQLPromise = (async () => {
      const initSqlJs = require('sql.js');
      const wasm = wasmPath();
      if (!fs.existsSync(wasm)) {
        throw new Error('sql-wasm.wasm 未找到: ' + wasm);
      }
      return await initSqlJs({ locateFile: () => wasm });
    })();
  }
  return SQLPromise;
}

/**
 * 对指定 SQLite 文件执行一条查询，返回行对象数组。
 * @param {string} dbPath
 * @param {string} sql
 * @param {any[]} params
 */
async function query(dbPath, sql, params = []) {
  const SQL = await getSQL();
  const buf = fs.readFileSync(dbPath);
  const db = new SQL.Database(new Uint8Array(buf));
  try {
    const stmt = db.prepare(sql);
    if (params.length) stmt.bind(params);
    const rows = [];
    while (stmt.step()) rows.push(stmt.getAsObject());
    stmt.free();
    return rows;
  } finally {
    try { db.close(); } catch (_) {}
  }
}

module.exports = { query, getSQL, wasmPath };
