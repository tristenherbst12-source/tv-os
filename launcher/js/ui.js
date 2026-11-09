/* Shared page plumbing and small remote-friendly widgets: key routing, going home, toast, confirm dialog, PIN pad. */
window.TV = window.TV || {};

(function () {
  const launcherRoot = new URL('../', document.currentScript.src).href;
  const modals = [];          // open dialogs, top one gets the keys
  let pageHandler = null;

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  TV.ui = {
    el,
    goHome() { location.href = new URL('index.html', launcherRoot).href; },

    /* Loads config, applies Lite mode and the wallpaper, and routes keys to handler(action, event).
       The handler returns true when it used the key. Back and Home go to the home screen otherwise. */
    async startPage(handler) {
      pageHandler = handler;
      const cfg = await TV.config.loadAll();
      TV.keys.load(cfg.keymap);
      document.body.classList.toggle('lite', !!cfg.settings.lite);
      TV.wallpaper.start(cfg.settings);
      const clock = document.getElementById('clock');
      if (clock) {
        const tick = () => { clock.textContent = new Date().toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }); };
        tick(); setInterval(tick, 1000);
      }
      document.addEventListener('keydown', onKey);
      return cfg;
    },

    toast(text, ms) {
      let t = document.getElementById('toast');
      if (!t) { t = el('div', 'toast'); t.id = 'toast'; document.body.appendChild(t); }
      t.textContent = text;
      t.classList.add('show');
      clearTimeout(t._h);
      t._h = setTimeout(() => t.classList.remove('show'), ms || 2600);
    },

    /* Dialog with buttons. Resolves with the chosen button's value, or null on Back.
       The first button has focus, so put the safe choice (Cancel) first. */
    confirm({ title, text, buttons }) {
      return new Promise(resolve => {
        const wrap = el('div', 'modal');
        const box = el('div', 'dialog');
        box.appendChild(el('div', 'dialog-title', title));
        if (text) box.appendChild(el('div', 'dialog-text', text));
        const row = el('div', 'dialog-buttons');
        const btns = buttons.map((b, i) => {
          const x = el('div', 'btn' + (b.danger ? ' danger' : ''), b.label);
          x.addEventListener('mouseenter', () => focus(i));
          x.addEventListener('click', () => done(b.value));
          row.appendChild(x);
          return x;
        });
        box.appendChild(row);
        wrap.appendChild(box);
        document.body.appendChild(wrap);
        let f = 0;
        function focus(i) { btns[f].classList.remove('focus'); f = i; btns[f].classList.add('focus'); }
        focus(0);
        requestAnimationFrame(() => wrap.classList.add('show'));
        const m = {
          handle(action) {
            if (action === 'left') focus(Math.max(0, f - 1));
            else if (action === 'right') focus(Math.min(btns.length - 1, f + 1));
            else if (action === 'ok') done(buttons[f].value);
            else if (action === 'back' || action === 'home') done(null);
            return true;
          }
        };
        function done(v) { close(wrap, m); resolve(v); }
        modals.push(m);
      });
    },

    /* 4-digit PIN entry: arrows + OK on the keypad, or the remote's number keys. Resolves with the PIN or null. */
    pinPad(title, hint) {
      return new Promise(resolve => {
        const wrap = el('div', 'modal');
        const box = el('div', 'dialog pin');
        box.appendChild(el('div', 'dialog-title', title));
        const msg = el('div', 'dialog-text', hint || '');
        box.appendChild(msg);
        const dots = el('div', 'pin-dots');
        for (let i = 0; i < 4; i++) dots.appendChild(el('span'));
        box.appendChild(dots);
        const grid = el('div', 'pin-grid');
        const labels = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'Clear', '0', 'Delete'];
        const keys = labels.map((l, i) => {
          const k = el('div', 'btn pin-key' + (l.length > 1 ? ' small' : ''), l);
          k.addEventListener('mouseenter', () => focus(i));
          k.addEventListener('click', () => press(l));
          grid.appendChild(k);
          return k;
        });
        box.appendChild(grid);
        wrap.appendChild(box);
        document.body.appendChild(wrap);
        let pin = '', f = 4;
        function focus(i) { keys[f].classList.remove('focus'); f = i; keys[f].classList.add('focus'); }
        function draw() { [...dots.children].forEach((d, i) => d.classList.toggle('on', i < pin.length)); }
        function press(l) {
          if (l === 'Clear') pin = '';
          else if (l === 'Delete') pin = pin.slice(0, -1);
          else if (pin.length < 4) pin += l;
          draw();
          if (pin.length === 4) setTimeout(() => done(pin), 180);
        }
        focus(4);
        requestAnimationFrame(() => wrap.classList.add('show'));
        const m = {
          handle(action, e) {
            if (/^[0-9]$/.test(e.key)) { press(e.key); return true; }
            if (action === 'left') focus(f % 3 ? f - 1 : f);
            else if (action === 'right') focus(f % 3 < 2 ? f + 1 : f);
            else if (action === 'up') focus(f >= 3 ? f - 3 : f);
            else if (action === 'down') focus(f < 9 ? f + 3 : f);
            else if (action === 'ok') press(labels[f]);
            else if (e.key === 'Backspace') press('Delete');
            else if (action === 'back' || action === 'home') done(null);
            return true;
          }
        };
        function done(v) { close(wrap, m); resolve(v); }
        modals.push(m);
      });
    }
  };

  function close(wrap, m) {
    const i = modals.indexOf(m);
    if (i >= 0) modals.splice(i, 1);
    wrap.classList.remove('show');
    setTimeout(() => wrap.remove(), 250);
  }

  function onKey(e) {
    const action = TV.keys.action(e);
    if (modals.length) {
      if (modals[modals.length - 1].handle(action, e)) e.preventDefault();
      return;
    }
    if (pageHandler && pageHandler(action, e)) { e.preventDefault(); return; }
    if (action === 'back' || action === 'home') { e.preventDefault(); TV.ui.goHome(); }
  }
})();
