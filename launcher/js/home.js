/* Home screen: builds the tiles from config/apps.json, handles focus, keys, launching, clock and wallpaper. */
(function () {
  const $ = id => document.getElementById(id);
  const launcherRoot = new URL('../', document.currentScript.src).href;

  /* Pages that are not built yet. Remove an entry when its stage lands. */
  const NOT_YET = {
    races:    'Arrives in Stage 4',
    settings: 'Arrives in Stage 3',
    power:    'Arrives in Stage 3'
  };

  let cfg, grid = [], rows = [], fr = 0, fc = 0, busy = false;

  /* ---------- icons: real file if it loads, otherwise the glyph ---------- */
  function probe(src, ms) {
    return new Promise(resolve => {
      const img = new Image();
      const t = setTimeout(() => resolve(null), ms);
      img.onload = () => { clearTimeout(t); resolve(img.naturalWidth ? src : null); };
      img.onerror = () => { clearTimeout(t); resolve(null); };
      img.src = src;
    });
  }

  async function resolveIcons(apps) {
    await Promise.all(Object.keys(apps).map(async id => {
      const a = apps[id];
      a._icon = a.icon ? await probe(new URL(a.icon, launcherRoot).href, 800) : null;
    }));
  }

  function iconHTML(a, el) {
    el.style.setProperty('--accent', a.accent || '#8a8fb3');
    if (a._icon) {
      el.classList.add('img');
      if (a.iconBg) el.style.setProperty('--icon-bg', a.iconBg);
      if (a.iconPad) el.classList.add('pad');
      el.innerHTML = '';
      const img = document.createElement('img');
      img.src = a._icon; img.alt = '';
      el.appendChild(img);
    } else {
      el.classList.remove('img', 'pad');
      el.style.removeProperty('--icon-bg');
      el.innerHTML = TV.svg(a.glyph);
    }
  }

  /* ---------- tiles ---------- */
  function build() {
    const host = $('rows');
    host.innerHTML = '';
    grid = []; rows = [];
    (cfg.apps.rows || []).forEach(row => {
      const apps = (row.apps || []).map(id => Object.assign({ id }, cfg.apps.apps[id])).filter(a => a.name);
      if (!apps.length) return;
      const r = grid.length;
      const label = document.createElement('div');
      label.className = 'label' + (row.size === 'small' ? ' minor' : '');
      label.textContent = row.label || '';
      const el = document.createElement('div');
      el.className = 'row ' + (row.size === 'small' ? 'small' : 'big');
      el.style.setProperty('--cols', apps.length);
      host.append(label, el);

      grid.push(apps.map((a, c) => {
        const t = document.createElement('div');
        t.className = 'tile';
        t.style.setProperty('--accent', a.accent || '#8a8fb3');
        const ic = document.createElement('div');
        ic.className = 'icon';
        iconHTML(a, ic);
        t.appendChild(ic);
        const text = document.createElement('div');
        if (row.size === 'small') {
          text.className = 'name'; text.textContent = a.name;
        } else {
          text.innerHTML = '<div class="name"></div><div class="sub"></div>';
          text.firstChild.textContent = a.name;
          text.lastChild.textContent = a.sub || '';
        }
        t.appendChild(text);
        t.addEventListener('mouseenter', () => setFocus(r, c));
        t.addEventListener('click', () => { setFocus(r, c); launch(a); });
        el.appendChild(t);
        return t;
      }));
      rows.push(apps);
    });
    fr = 0; fc = 0;
    if (grid.length) setFocus(0, 0);
  }

  function setFocus(r, c) {
    if (grid[fr] && grid[fr][fc]) grid[fr][fc].classList.remove('focus');
    fr = r; fc = c;
    grid[fr][fc].classList.add('focus');
  }

  /* Moving between rows of different lengths keeps roughly the same horizontal position. */
  function mapCol(c, from, to) {
    const a = grid[from].length, b = grid[to].length;
    return a <= 1 ? 0 : Math.min(Math.round(c * (b - 1) / (a - 1)), b - 1);
  }

  /* ---------- launching ---------- */
  function overlay(a, text, msg, error) {
    const L = $('launch');
    iconHTML(a, $('lIcon'));
    $('lTxt').textContent = text;
    $('lMsg').textContent = msg || '';
    L.classList.toggle('error', !!error);
    L.classList.add('show');
  }
  function hideOverlay() { $('launch').classList.remove('show'); busy = false; }

  async function launch(a) {
    if (busy) return;
    busy = true;
    const type = a.launch && a.launch.type;

    if (type === 'page') {
      if (NOT_YET[a.id]) {
        overlay(a, a.name, NOT_YET[a.id], true);
        setTimeout(hideOverlay, 1600);
      } else {
        location.href = new URL(a.launch.page, launcherRoot).href;
      }
      return;
    }

    overlay(a, 'Opening ' + a.name);
    if (!TV.helper.available) {
      // Plain browser (no helper installed): show the overlay like the prototype did, then return.
      setTimeout(() => { $('lMsg').textContent = 'Preview Only: Helper Not Installed'; }, 500);
      setTimeout(hideOverlay, 1800);
      return;
    }
    try {
      await TV.helper.launch(a.id);
      // The app window now covers the launcher. Clear the overlay so Home lands on a clean screen.
      setTimeout(hideOverlay, 2500);
    } catch (e) {
      console.warn('launch failed', a.id, e);
      const msg = e.status === 404 && e.body && e.body.error === 'not installed' ? 'App Not Installed'
                : e.status ? 'Something Went Wrong (' + e.status + ')' : 'Helper Not Responding';
      overlay(a, 'Could Not Open ' + a.name, msg, true);
      setTimeout(hideOverlay, 2200);
    }
  }

  /* ---------- keys ---------- */
  function onKey(e) {
    const act = TV.keys.action(e);
    if (!act || !grid.length) return;
    if ($('launch').classList.contains('show') && act !== 'back' && act !== 'home') { e.preventDefault(); return; }
    switch (act) {
      case 'right': setFocus(fr, Math.min(fc + 1, grid[fr].length - 1)); break;
      case 'left':  setFocus(fr, Math.max(fc - 1, 0)); break;
      case 'down':  if (fr < grid.length - 1) setFocus(fr + 1, mapCol(fc, fr, fr + 1)); break;
      case 'up':    if (fr > 0) setFocus(fr - 1, mapCol(fc, fr, fr - 1)); break;
      case 'ok':    launch(rows[fr][fc]); break;
      case 'back':
      case 'home':  hideOverlay(); setFocus(0, 0); break;
      case 'lite':  setLite(!cfg.settings.lite, true); break;
      default: return;
    }
    e.preventDefault();
  }

  function setLite(on, save) {
    cfg.settings.lite = !!on;
    document.body.classList.toggle('lite', !!on);
    if (save) TV.config.saveSettings({ lite: !!on });
  }

  /* ---------- clock + time-of-day wallpaper ---------- */
  let lastKey = '';
  function tick() {
    const d = new Date();
    $('clock').textContent = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    $('date').textContent = d.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' });
    const part = TV.dayPart(d);
    $('greet').textContent =
      (part === 'morning' ? 'Good Morning' : part === 'day' ? 'Good Afternoon' : 'Good Evening') + ', Jazz & Tris';
    const theme = TV.themeFor(cfg.settings.wallpaper, d);
    const key = theme + '/' + part;
    if (key !== lastKey) {
      lastKey = key;
      const p = TV.THEMES[theme][part], s = document.documentElement.style;
      s.setProperty('--bg', p.bg);
      ['--b1', '--b2', '--b3', '--b4'].forEach((v, i) => s.setProperty(v, p.b[i]));
      $('modeTxt').textContent = p.name;
      $('modeIcon').innerHTML = TV.GLYPHS[part === 'morning' || part === 'day' ? 'sun' : 'moon'];
    }
    $('net').textContent = navigator.onLine ? 'Online' : 'Offline';
  }

  /* ---------- start ---------- */
  async function start() {
    cfg = await TV.config.loadAll();
    console.info('[launcher] config sources', TV.config.sources);
    TV.keys.load(cfg.keymap);
    setLite(cfg.settings.lite, false);
    tick();
    setInterval(tick, 1000);
    await resolveIcons(cfg.apps.apps || {});
    build();
    document.addEventListener('keydown', onKey);
    window.addEventListener('focus', () => { if (busy && !$('launch').classList.contains('error')) hideOverlay(); });
    document.body.classList.add('ready');
  }

  start();
})();
