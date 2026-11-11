// AI 额度桌宠 —— 渲染层（角色 + 头顶气泡）

const avatarEl = document.getElementById('avatar');
const bName = document.getElementById('b-name');
const bPct = document.getElementById('b-pct');
const bFill = document.getElementById('b-fill');
const bSub = document.getElementById('b-sub');

// ---------------------------------------------------- 形象

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

// ---------------------------------------------------- 气泡内容

function pickItem(items) {
  if (!items || !items.length) return null;
  const withQuota = items.filter((i) => i.remaining != null);
  if (withQuota.length) {
    // Windows 没有前台识别，退化成「显示额度最少的那个」
    return withQuota.sort((a, b) => a.remaining - b.remaining)[0];
  }
  return items[0];
}

function render(items) {
  const item = pickItem(items);
  if (!item) {
    bName.textContent = '正在读取…';
    bPct.textContent = '--';
    bFill.style.width = '0%';
    bSub.textContent = '';
    return;
  }

  bName.textContent = item.name || 'AI 额度';

  if (item.remaining != null) {
    const pct = Math.max(0, Math.min(100, Math.round(item.remaining * 100)));
    bPct.textContent = pct + '%';
    const color = pct < 20 ? '#f87171' : pct < 50 ? '#fb923c' : '#4ade80';
    bPct.style.color = color;
    bFill.style.width = pct + '%';
    bFill.style.background = pct < 20 ? '#ef4444' : pct < 50 ? '#f97316' : '#3b82f6';
  } else {
    bPct.textContent = item.primary || '--';
    bPct.style.color = '#f2f4f8';
    bFill.style.width = '0%';
  }

  bSub.textContent = item.secondary || '';
}

// ---------------------------------------------------- 展开 / 透明度

function setExpanded(on) {
  document.body.classList.toggle('expanded', on);
}

function setAlpha(a) {
  document.body.style.opacity = String(a);
}

// ---------------------------------------------------- 拖动窗口

let pressing = false;

document.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  pressing = true;
  window.hud.dragStart();
});

document.addEventListener('mouseup', () => {
  if (!pressing) return;
  pressing = false;
  window.hud.dragEnd();
});

window.addEventListener('blur', () => {
  if (pressing) {
    pressing = false;
    window.hud.dragEnd();
  }
});

// ---------------------------------------------------- 事件订阅

window.hud.onItems(render);
window.hud.onExpanded(setExpanded);
window.hud.onAlpha(setAlpha);

// ---------------------------------------------------- 初始拉取

(async () => {
  try {
    render(await window.hud.getItems());
  } catch (e) {
    console.error(e);
  }
  try {
    applyAvatar(await window.hud.getAvatar());
  } catch (e) {
    console.error(e);
  }
  try {
    const s = await window.hud.getSettings();
    setAlpha(s.hoverAlpha != null ? 1 : 1);
  } catch (e) {}
})();
