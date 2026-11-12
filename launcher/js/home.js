/* Home screen: builds the tiles from config/apps.json, handles focus, keys, launching, clock and wallpaper. */
(function () {
  const $ = id => document.getElementById(id);
  const launcherRoot = new URL('../', document.currentScript.src).href;

  /* Pages that are not built yet. Remove an entry when its stage lands. */
  const NOT_YET = {};
  const FOCUS_KEY = 'tv.home.focus';   // tile to focus when coming back (e.g. from Settings)

  const VISIBLE_BIG = 6;                // big tiles on screen at once (the approved layout)
  let cfg, grid = [], rows = [], rowEls = [], firstShown = [], fr = 0, fc = 0, busy = false;
  let continueItems = [];               // Continue Watching (helper /continue), shown under the first row
  const CONTINUE_MAX = 4;

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
    grid = []; rows = []; rowEls = []; firstShown = [];
    const rowDefs = (cfg.apps.rows || []).slice();
    if (continueItems.length && rowDefs.length) rowDefs.splice(1, 0, { label: 'Continue Watching', continue: true });
    document.body.classList.toggle('has-continue', !!continueItems.length);
    rowDefs.forEach(row => {
      if (row.continue) { buildContinueRow(host, row); return; }
      const apps = (row.apps || []).map(id => Object.assign({ id }, cfg.apps.apps[id])).filter(a => a.name);
      if (!apps.length) return;
      const r = grid.length;
      const label = document.createElement('div');
      label.className = 'label' + (row.size === 'small' ? ' minor' : '');
      label.textContent = row.label || '';
      const el = document.createElement('div');
      el.className = 'row ' + (row.size === 'small' ? 'small' : 'big');
      // More big tiles than fit (6): the tiles keep the approved size and the row slides along with the focus.
      const slides = row.size !== 'small' && apps.length > VISIBLE_BIG;
      el.style.setProperty('--cols', slides ? VISIBLE_BIG : apps.length);
      if (slides) {
        el.classList.add('slide');
        const view = document.createElement('div');
        view.className = 'row-view';
        view.appendChild(el);
        host.append(label, view);
      } else host.append(label, el);
      rowEls.push(slides ? el : null);
      firstShown.push(0);

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
        TV.onHover(t, () => setFocus(r, c));
        t.addEventListener('click', () => { setFocus(r, c); launch(a); });
        el.appendChild(t);
        return t;
      }));
      rows.push(apps);
      // A sliding row starts showing its first tiles (the rest hidden until the focus moves along it).
      if (slides) grid[r].forEach((t, i) => t.classList.toggle('off', i >= VISIBLE_BIG));
    });
    fr = 0; fc = 0;
    if (!grid.length) return;
    let last = keepFocus;
    keepFocus = null;
    if (!last) try { last = sessionStorage.getItem(FOCUS_KEY); } catch (e) { /* storage blocked */ }
    for (let r = 0; r < rows.length; r++) {
      const c = rows[r].findIndex(a => a.id === last);
      if (c >= 0) { setFocus(r, c); return; }
    }
    setFocus(0, 0);
  }

  /* Continue Watching: the latest video in each app (picture, title, time left). OK opens the app right there. */
  function buildContinueRow(host, row) {
    const r = grid.length;
    const label = document.createElement('div');
    label.className = 'label minor';
    label.textContent = row.label;
    const el = document.createElement('div');
    el.className = 'row small cont';
    const items = continueItems.slice(0, CONTINUE_MAX);
    el.style.setProperty('--cols', items.length);
    host.append(label, el);
    rowEls.push(null); firstShown.push(0);
    const apps = items.map(it => {
      const app = cfg.apps.apps[it.app] || {};
      return { id: 'continue:' + it.app, name: it.title, accent: app.accent, _continue: it, _app: Object.assign({ id: it.app }, app) };
    });
    grid.push(apps.map((a, c) => {
      const it = a._continue;
      const t = document.createElement('div');
      t.className = 'tile';
      t.style.setProperty('--accent', a.accent || '#8a8fb3');
      const th = document.createElement('div');
      th.className = 'thumb';
      if (it.art) {
        const img = document.createElement('img');
        img.alt = ''; img.src = it.art;
        img.onerror = () => { img.remove(); th.classList.add('none'); };
        th.appendChild(img);
      } else th.classList.add('none');
      const badge = document.createElement('div');
      badge.className = 'icon';
      iconHTML(a._app, badge);
      th.appendChild(badge);
      if (!it.live && it.duration > 0) {
        const bar = document.createElement('div');
        bar.className = 'progress';
        bar.style.setProperty('--p', Math.min(100, Math.round(100 * it.position / it.duration)) + '%');
        th.appendChild(bar);
      }
      const text = document.createElement('div');
      text.className = 'text';
      text.innerHTML = '<div class="name"></div><div class="sub"></div>';
      text.firstChild.textContent = it.title;
      const left = it.live ? 'Live' : it.duration > 0 ? Math.max(1, Math.round((it.duration - it.position) / 60)) + ' Min Left' : '';
      text.lastChild.textContent = [left || a._app.name, it.sub].filter(Boolean).join(' · ');
      t.append(th, text);
      TV.onHover(t, () => setFocus(r, c));
      t.addEventListener('click', () => { setFocus(r, c); launch(a); });
      el.appendChild(t);
      return t;
    }));
    rows.push(apps);
  }

  // Asks the helper what can be continued; rebuilds the rows when that changed (keeping the focused tile).
  let keepFocus = null;
  async function refreshContinue() {
    if (!TV.helper.available) return;
    let items = [];
    try { items = ((await TV.helper.request('/continue')) || {}).items || []; } catch (e) { return; }
    items = items.filter(it => cfg.apps.apps[it.app]);
    if (JSON.stringify(items) === JSON.stringify(continueItems)) return;
    continueItems = items;
    if (grid.length) {
      keepFocus = rows[fr] && rows[fr][fc] && rows[fr][fc].id;
      build();
    }
  }

  function setFocus(r, c) {
    if (grid[fr] && grid[fr][fc]) grid[fr][fc].classList.remove('focus');
    fr = r; fc = c;
    grid[fr][fc].classList.add('focus');
    const el = rowEls[r];
    if (el) {
      let first = firstShown[r];
      if (c < first) first = c;
      else if (c > first + VISIBLE_BIG - 1) first = c - VISIBLE_BIG + 1;
      first = Math.max(0, Math.min(first, grid[r].length - VISIBLE_BIG));
      firstShown[r] = first;
      // Distance from the row's first tile (offsetLeft itself is measured from the screen's edge).
      el.style.transform = 'translateX(' + (grid[r][0].offsetLeft - grid[r][first].offsetLeft) + 'px)';
      grid[r].forEach((t, i) => t.classList.toggle('off', i < first || i >= first + VISIBLE_BIG));
    }
  }

  /* Moving between rows of different lengths keeps roughly the same horizontal position. */
  function mapCol(c, from, to) {
    // Work with what is on screen: a sliding row shows VISIBLE_BIG tiles starting at firstShown.
    const shownFrom = rowEls[from] ? VISIBLE_BIG : grid[from].length;
    const shownTo = rowEls[to] ? VISIBLE_BIG : grid[to].length;
    const pos = c - (rowEls[from] ? firstShown[from] : 0);
    const mapped = shownFrom <= 1 ? 0 : Math.round(pos * (shownTo - 1) / (shownFrom - 1));
    return Math.min((rowEls[to] ? firstShown[to] : 0) + mapped, grid[to].length - 1);
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
    try { sessionStorage.setItem(FOCUS_KEY, a.id); } catch (e) { /* storage blocked */ }
    if (a._continue) {
      // Continue Watching: the app, opened at the page that was playing.
      overlay(a._app, a._continue.title, 'Opening ' + a._app.name);
      if (!TV.helper.available) { setTimeout(hideOverlay, 1600); return; }
      try { await TV.helper.launch(a._app.id, a._continue.url); setTimeout(hideOverlay, 2500); }
      catch (e) { overlay(a._app, 'Could Not Open ' + a._app.name, e.status ? 'Something Went Wrong (' + e.status + ')' : 'Helper Not Responding', true); setTimeout(hideOverlay, 2200); }
      return;
    }
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
      case 'back':  hideOverlay(); setFocus(0, 0); break;
      // Home on the home screen: the screensaver, as on a TV (or, while an app is opening, back to the tiles).
      case 'home':
        if ($('launch').classList.contains('show')) { hideOverlay(); setFocus(0, 0); }
        else TV.screensaver.start();
        break;
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

  /* ---------- clock (the wallpaper itself is js/wallpaper.js) ---------- */
  // Only touch text that changed: rewriting the clock every second repainted its three-layer glass effect.
  const setText = (id, s) => { const el = $(id); if (el.textContent !== s) el.textContent = s; };
  function tick() {
    const d = new Date();
    setText('clock', d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }));
    setText('date', d.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' }));
    const part = TV.dayPart(d);
    setText('greet', (part === 'morning' ? 'Good Morning' : part === 'day' ? 'Good Afternoon' : 'Good Evening') + ', Jazz & Tris');
    setText('net', navigator.onLine ? 'Online' : 'Offline');
  }

  /* ---------- screen off when idle (Settings > Screen Off When Idle; home screen only) ---------- */
  let lastInput = Date.now(), screenOffSent = false;
  function noteInput() { lastInput = Date.now(); screenOffSent = false; }
  function checkIdle() {
    if (document.visibilityState !== 'visible' || !document.hasFocus()) { lastInput = Date.now(); return; }   // an app is in front
    const idle = Date.now() - lastInput;
    // Screensaver after settings.screensaverMinutes (default 5) untouched on the home screen. Never over an app:
    // while one is in front, the home screen has no focus and the idle time keeps restarting (above).
    const saver = cfg.settings.screensaverMinutes == null ? 5 : Number(cfg.settings.screensaverMinutes) || 0;
    if (saver && idle >= saver * 60000 && !TV.screensaver.active && !$('launch').classList.contains('show')) TV.screensaver.start();
    const mins = Number(cfg.settings.screenOffMinutes) || 0;
    if (!mins || screenOffSent || !TV.helper.available) return;
    if (idle < mins * 60000) return;
    screenOffSent = true;
    TV.helper.request('/screen-off', { method: 'POST' }).catch(() => { screenOffSent = false; });
  }

  /* ---------- "Next Session" chip: the next F1 or WEC session (data from js/races.js) ---------- */
  const CHIP_ACCENT = { F1: '#e10600', WEC: '#2f7bff' };
  let raceSessions = [];
  function drawChip() {
    const now = new Date();
    const live = s => s.timeKnown && s.start <= now && now < s.end;
    const s = raceSessions.find(live) || raceSessions.find(x => x.start > now || (!x.timeKnown && x.end > now));
    const chip = $('raceChip');
    if (!s) { chip.hidden = true; return; }
    let when;
    if (live(s)) when = 'Live Now';
    else {
      const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
      const days = Math.round((startOfDay(s.start) - startOfDay(now)) / 864e5);
      const mins = Math.ceil((s.start - now) / 6e4);
      const hm = ' ' + s.start.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
      const day = days === 0 ? 'Today' : days === 1 ? 'Tomorrow'
                : days < 7 ? s.start.toLocaleDateString('en-GB', { weekday: 'long' })
                : s.start.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
      when = !s.timeKnown ? day
           : mins < 60 ? 'In ' + mins + ' Min'
           : mins < 6 * 60 ? 'In ' + Math.floor(mins / 60) + 'h ' + (mins % 60) + 'm'
           : day + hm;
    }
    const event = s.event.replace(/ Grand Prix$/, ' GP');
    $('rcSeries').textContent = s.series;
    chip.style.setProperty('--accent', CHIP_ACCENT[s.series] || '#8a8fb3');
    chip.classList.toggle('live', when === 'Live Now');
    $('rcText').innerHTML = '';
    const name = document.createElement('span'); name.textContent = event + ' ' + s.session;
    const w = document.createElement('span'); w.className = 'when'; w.textContent = '· ' + when;
    $('rcText').append(name, ' ', w);
    chip.hidden = false;
  }
  function startChip() {
    const onData = d => { raceSessions = d.sessions; drawChip(); };
    TV.races.load(onData).catch(e => console.warn('[home] race chip', e));
    setInterval(drawChip, 30e3);
    setInterval(() => TV.races.load(onData).catch(() => {}), 6 * 3600e3);
  }

  /* ---------- Now playing on Spotify (the window keeps running after Home) ---------- */
  function drawNowPlaying() {
    if (!TV.helper.available) return;
    TV.helper.request('/now-playing').then(r => {
      const np = r && r.nowPlaying, chip = $('npChip');
      if (!np) { chip.hidden = true; return; }
      if ($('npArt').getAttribute('src') !== (np.art || '')) $('npArt').setAttribute('src', np.art || '');
      $('npText').innerHTML = '';
      const t = document.createElement('span'); t.textContent = np.title;
      const a = document.createElement('span'); a.className = 'artist'; a.textContent = np.artist ? ' · ' + np.artist : '';
      $('npText').append(t, a);
      chip.classList.toggle('paused', !np.playing);
      chip.hidden = false;
    }).catch(() => {});
  }

  /* ---------- start ---------- */
  async function start() {
    cfg = await TV.config.loadAll();
    console.info('[launcher] config sources', TV.config.sources);
    TV.keys.load(cfg.keymap);
    setLite(cfg.settings.lite, false);
    TV.wallpaper.start(cfg.settings, (part, p) => {
      $('modeTxt').textContent = p.name;
      $('modeIcon').innerHTML = TV.GLYPHS[part === 'morning' || part === 'day' ? 'sun' : 'moon'];
    });
    tick();
    setInterval(tick, 1000);
    ['keydown', 'mousemove', 'mousedown', 'wheel'].forEach(t => window.addEventListener(t, noteInput, { passive: true }));
    window.addEventListener('focus', noteInput);
    setInterval(checkIdle, 10000);
    TV.screensaver.onStop = noteInput;     // the button that ends it counts as use (it never reaches noteInput)
    await resolveIcons(cfg.apps.apps || {});
    await Promise.race([refreshContinue(), new Promise(r => setTimeout(r, 1500))]);
    build();
    window.addEventListener('focus', () => refreshContinue());   // back from an app: what was just watched
    setInterval(refreshContinue, 60000);
    document.addEventListener('keydown', onKey);
    window.addEventListener('focus', () => { if (busy && !$('launch').classList.contains('error')) hideOverlay(); });
    document.body.classList.add('ready');
    startChip();
    drawNowPlaying();
    setInterval(drawNowPlaying, 5000);
  }

  start();
})();
