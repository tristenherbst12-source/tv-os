/* "New update available" on the home screen. The helper checks GitHub (config/updates.json) every few hours; when it
   has found a newer version, this asks once: Update Now (the helper downloads it, copies it over the launcher and
   restarts it) or Later (asked again after 12 hours). After an update, a short note says it worked, and whether
   setup has to run once more. Settings > Updates checks and installs by hand. */
window.TV = window.TV || {};

TV.update = (function () {
  'use strict';
  const LATER = 'update-later';
  let box = null, btns = [], f = 0, busy = false;

  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  function open(title, text, buttons) {
    close();
    box = el('div', 'upd');
    const card = el('div', 'upd-card');
    const icon = el('div', 'upd-icon');
    icon.innerHTML = '<svg viewBox="0 0 24 24"><path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 21h14"/></svg>';
    card.append(icon, el('div', 'upd-title', title), el('div', 'upd-text', text));
    const row = el('div', 'upd-btns');
    btns = buttons.map((b, i) => {
      const x = el('div', 'upd-btn', b.label);
      x.addEventListener('click', () => { f = i; b.act(); });
      row.appendChild(x);
      return Object.assign(x, { _act: b.act });
    });
    if (btns.length) card.appendChild(row);
    box.appendChild(card);
    document.body.appendChild(box);
    requestAnimationFrame(() => box && box.classList.add('show'));
    focus(0);
  }
  function focus(i) { btns.forEach((b, k) => b.classList.toggle('focus', k === i)); f = i; }
  function close() { if (box) { box.remove(); box = null; btns = []; } }

  // While the prompt shows it has the remote's keys (the tiles behind it do not move).
  window.addEventListener('keydown', e => {
    if (!box) return;
    const act = TV.keys && TV.keys.action(e);
    if (!act) return;
    e.preventDefault(); e.stopImmediatePropagation();
    if (busy) return;
    if (act === 'left') focus(Math.max(0, f - 1));
    else if (act === 'right') focus(Math.min(btns.length - 1, f + 1));
    else if (act === 'ok' && btns[f]) btns[f]._act();
    else if (act === 'back' || act === 'home') later();
  }, true);

  let latest = null;
  function later() {
    try { localStorage.setItem(LATER, JSON.stringify({ v: latest, t: Date.now() })); } catch (e) { /* storage blocked */ }
    close();
  }
  async function install() {
    busy = true;
    open('Updating…', 'Downloading version ' + latest + '. The TV restarts the home screen by itself in a moment.', []);
    try {
      const r = await TV.helper.request('/update/install', { method: 'POST' });
      if (!r.ok) throw new Error(r.error || 'failed');
      if (r.testMode) { busy = false; open('Test Mode', 'The update would be installed now.', [{ label: 'OK', act: close }]); }
    } catch (e) {
      busy = false;
      const why = e && e.message && e.message !== 'failed' ? e.message.charAt(0).toUpperCase() + e.message.slice(1) + '. ' : '';
      open('Could Not Update', why + 'Try again later, or from Settings > Updates.', [{ label: 'OK', act: close }]);
    }
  }

  function prompt(s) {
    latest = s.latest;
    open('New Update Available', 'Version ' + s.latest + (s.message ? ': ' + s.message : '') + '. You are on ' + s.current + '.',
      [{ label: 'Update Now', act: install }, { label: 'Later', act: later }]);
  }

  // After an update: once, what it was (and whether setup must run again).
  function afterUpdate(last) {
    TV.helper.request('/update/seen', { method: 'POST' }).catch(() => {});
    open('Updated to ' + last.version, last.setupChanged
      ? 'This version changed the setup: run setup once more (README step 5) when you have a keyboard.'
      : 'Everything is up to date.', [{ label: 'OK', act: close }]);
  }

  async function check() {
    if (!TV.helper || !TV.helper.available || box) return;
    if (!document.hasFocus() || (TV.screensaver && TV.screensaver.active)) return;    // only on the home screen in front
    let s;
    try { s = await TV.helper.request('/update'); } catch (e) { return; }
    if (s.lastUpdate) { afterUpdate(s.lastUpdate); return; }
    if (!s.available || s.installing) return;
    try {
      const l = JSON.parse(localStorage.getItem(LATER) || 'null');
      if (l && l.v === s.latest && Date.now() - l.t < 12 * 3600e3) return;
    } catch (e) { /* storage blocked */ }
    prompt(s);
  }

  return { check, get open() { return !!box; } };
})();
