/* Turns a keydown into a launcher action using config/keymap.json ("launcher" section).
   An entry matches either e.key or e.code, so both "Enter" and "NumpadEnter" style names work. */
window.TV = window.TV || {};

TV.keys = {
  map: {},
  load(keymap) {
    const m = {};
    const actions = (keymap && keymap.launcher) || {};
    Object.keys(actions).forEach(action => {
      (actions[action] || []).forEach(k => { if (!(k in m)) m[k] = action; });
    });
    this.map = m;
  },
  action(e) {
    return this.map[e.key] || this.map[e.code] || null;
  }
};

/* ---------- the pointer (the remote's touchpad) ----------
   TV.onHover(el, fn): fn runs only when the pointer really moves over el. Chromium also sends mouse events when
   the page changes under a resting pointer (a dialog opening, a list scrolling); those must not move the focus.
   The pointer is hidden as soon as a remote button is pressed, and after 3 seconds without moving. */
(function () {
  let lastX = null, lastY = null, moved = false, idleTimer = 0;
  const IDLE_MS = 3000;
  function hide() { document.body && document.body.classList.add('pointer-idle'); }
  function show() {
    if (document.body) document.body.classList.remove('pointer-idle');
    clearTimeout(idleTimer);
    idleTimer = setTimeout(hide, IDLE_MS);
  }
  window.addEventListener('mousemove', e => {
    moved = lastX !== null && (e.screenX !== lastX || e.screenY !== lastY);
    lastX = e.screenX; lastY = e.screenY;
    if (moved) show();
  }, true);
  window.addEventListener('keydown', () => { clearTimeout(idleTimer); hide(); }, true);
  document.addEventListener('DOMContentLoaded', () => { idleTimer = setTimeout(hide, IDLE_MS); });
  if (document.readyState !== 'loading') idleTimer = setTimeout(hide, IDLE_MS);

  TV.onHover = function (el, fn) {
    el.addEventListener('mousemove', e => { if (moved) fn(e); });
  };
})();
