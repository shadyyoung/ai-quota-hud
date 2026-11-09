'use strict';

/* AI 额度悬浮窗 —— 渲染进程 */

const ACCENT = {
  blue: '#4d8dff',
  purple: '#a874ff',
  teal: '#3fd1c3',
  indigo: '#8b9bff',
  orange: '#ff9f45',
  gray: 'rgba(255,255,255,.42)',
};

// 内联图标（不依赖网络）
const ICONS = {
  codex: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polyline points="8 7 4 12 8 17"/><polyline points="16 7 20 12 16 17"/></svg>',
  cursor: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l2.4 6.1L20.5 10l-6.1 2.4L12 18.5 9.6 12.4 3.5 10l6.1-1.9L12 2z"/></svg>',
  workbuddy: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l1.9 5.6L19.5 9.5l-5.6 1.9L12 17l-1.9-5.6L4.5 9.5l5.6-1.9L12 2z"/><circle cx="18.5" cy="18.5" r="2.2"/></svg>',
  default: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="6"/></svg>',
};

const rowsEl = document.getElementById('rows');
const timeEl = document.getElementById('time');
const cardEl = document.getElementById('card');
const dotsEl = document.getElementById('dots');

function iconFor(id) {
  return ICONS[id] || ICONS.default;
}

function fmtTime() {
  const d = new Date();
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

function splitValue(primary) {
  // "剩余 99%" → { prefix: '剩余', main: '99%' }
  if (typeof primary === 'string' && primary.startsWith('剩余 ')) {
    return { prefix: '剩余', main: primary.slice(3) };
  }
  return { prefix: '', main: primary };
}

function valueClass(item) {
  if (item.status === 'unavailable') return 'value dim';
  if (typeof item.remaining === 'number') {
    if (item.remaining <= 0.12) return 'value warn';
    if (item.remaining <= 0.30) return 'value low';
  }
  return 'value';
}

function buildRow(item) {
  const row = document.createElement('div');
  row.className = 'row';

  const color = ACCENT[item.accent] || ACCENT.gray;

  // 图标
  const icon = document.createElement('div');
  icon.className = 'icon';
  icon.style.color = item.status === 'unavailable' ? 'rgba(255,255,255,.35)' : color;
  icon.innerHTML = iconFor(item.id);
  row.appendChild(icon);

  // 名称
  const name = document.createElement('div');
  name.className = 'name' + (item.status === 'unavailable' ? ' dim' : '');
  name.textContent = item.name;
  row.appendChild(name);

  // 数值
  const { prefix, main } = splitValue(item.primary);
  const value = document.createElement('div');
  value.className = valueClass(item);
  if (prefix) {
    const p = document.createElement('span');
    p.className = 'prefix';
    p.textContent = prefix;
    value.appendChild(p);
  }
  value.appendChild(document.createTextNode(main));
  row.appendChild(value);

  // 副行：进度条 + 说明
  const sub = document.createElement('div');
  sub.className = 'sub';

  if (typeof item.remaining === 'number' && item.status !== 'unavailable') {
    const bar = document.createElement('div');
    bar.className = 'bar';
    const fill = document.createElement('i');
    const pct = Math.max(1, Math.min(100, item.remaining * 100));
    fill.style.width = pct + '%';
    fill.style.background =
      item.remaining <= 0.12 ? '#ff6b6b' : item.remaining <= 0.30 ? '#fbbf45' : color;
    bar.appendChild(fill);
    sub.appendChild(bar);
  }

  let secondary = item.secondary || '';
  if (item.badge) secondary = `${item.badge} · ${secondary}`;
  if (secondary) {
    const s = document.createElement('div');
    s.className = 'secondary';
    s.textContent = secondary;
    s.title = secondary;
    sub.appendChild(s);
  }

  if (sub.childNodes.length) row.appendChild(sub);
  return row;
}

function render(items) {
  rowsEl.innerHTML = '';
  if (!items || items.length === 0) {
    const d = document.createElement('div');
    d.className = 'empty';
    d.textContent = '正在读取…';
    rowsEl.appendChild(d);
    return;
  }
  // 最多显示 5 个，避免溢出
  for (const item of items.slice(0, 5)) {
    rowsEl.appendChild(buildRow(item));
  }

  // 收起态的圆点颜色跟随当前数据
  dotsEl.innerHTML = '';
  for (const item of items.slice(0, 5)) {
    const dot = document.createElement('span');
    dot.className = 'dot';
    dot.style.background =
      item.status === 'unavailable' ? 'rgba(255,255,255,.35)' : ACCENT[item.accent] || ACCENT.gray;
    dotsEl.appendChild(dot);
  }
}

function setExpanded(on) {
  document.body.classList.toggle('collapsed', !on);
}

function setAlpha(a) {
  cardEl.style.setProperty('--alpha', String(a));
}

// ---------------------------------------------------- 事件

window.hud.onItems(render);
window.hud.onExpanded(setExpanded);
window.hud.onAlpha(setAlpha);

// 右键：展开并弹出菜单
document.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  window.hud.setMenuOpen(true);
});

// 双击：立即刷新
document.addEventListener('dblclick', async () => {
  const items = await window.hud.refresh();
  render(items);
});

// ---------------------------------------------------- 拖动窗口
// 无边框窗口在 Windows 上不会自动可拖，这里手动把鼠标位移转成窗口位移
let pressing = false;

// ---------------------------------------------------- 形象（头像）
const avatarEl = document.getElementById('avatar');

function applyAvatar(payload) {
  if (!payload || !payload.dataUrl) {
    avatarEl.classList.remove('loaded');
    avatarEl.removeAttribute('src');
    return;
  }
  avatarEl.src = payload.dataUrl;
  avatarEl.classList.add('loaded');
}

window.hud.onAvatar(applyAvatar);


document.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;          // 只处理左键
  pressing = true;
  window.hud.dragStart();
});

document.addEventListener('mouseup', () => {
  if (!pressing) return;
  pressing = false;
  window.hud.dragEnd();
});

// 鼠标移出窗口后松手可能收不到 mouseup，失焦时兜底
window.addEventListener('blur', () => {
  if (pressing) {
    pressing = false;
    window.hud.dragEnd();
  }
});

// 拖动时给个抓取光标
window.hud.onDragging((on) => {
  document.body.style.cursor = on ? 'grabbing' : '';
});

// 时间
function tick() {
  timeEl.textContent = fmtTime();
}
tick();
setInterval(tick, 30000);

// 初始拉取
(async () => {
  try {
    const items = await window.hud.getItems();
    render(items);
  } catch (e) {
    console.error(e);
  }
  try {
    applyAvatar(await window.hud.getAvatar());
  } catch (e) {
    console.error(e);
  }
})();
