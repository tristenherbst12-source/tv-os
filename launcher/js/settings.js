/* Settings page. Every row is reachable with Up/Down; Left/Right changes a choice, OK selects. */
(function () {
  const { el } = TV.ui;
  const list = document.getElementById('list');
  const H = TV.helper;
  let cfg, rows = [], f = 0;

  const ICON_VOL = '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/>';
  const ICON_MUTE = '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="m22 9-6 6M16 9l6 6"/>';
  const svg = p => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + p + '</svg>';

  function needHelper() {
    if (H.available) return true;
    TV.ui.toast('Needs the Helper, Which Is Not Running');
    return false;
  }

  /* ---------- building blocks ---------- */
  function group(label) { list.appendChild(el('div', 'group', label)); }

  function row(o) {
    const r = el('div', 'srow' + (o.info ? ' info' : ''));
    if (o.accent) r.style.setProperty('--accent', o.accent);
    const txt = el('div', 'txt');
    const name = el('div', 'name', o.name);
    const hint = el('div', 'hint', o.hint || '');
    if (!o.hint) hint.hidden = true;
    txt.append(name, hint);
    const ctl = el('div', 'ctl');
    if (o.ctl) ctl.append(o.ctl);
    r.append(txt, ctl);
    const item = Object.assign({ el: r, nameEl: name, hintEl: hint, ctlEl: ctl }, o);
    item.setHint = t => { hint.textContent = t || ''; hint.hidden = !t; };
    TV.onHover(r, () => focus(rows.indexOf(item)));
    r.addEventListener('click', () => { focus(rows.indexOf(item)); item.ok && item.ok(); });
    (o.before ? list.insertBefore(r, o.before) : list.appendChild(r));
    const at = o.index != null ? o.index : rows.length;
    rows.splice(at, 0, item);
    return item;
  }

  /* A segmented choice. values[i] is what onChange receives. */
  function segRow(o) {
    const seg = el('div', 'seg');
    const spans = o.labels.map(l => { const s = el('span', null, l); seg.appendChild(s); return s; });
    let i = Math.max(0, o.values.indexOf(o.value));
    const draw = () => spans.forEach((s, k) => s.classList.toggle('on', k === i));
    draw();
    const item = row(Object.assign({}, o, { ctl: seg }));
    const move = d => {
      const n = Math.max(0, Math.min(spans.length - 1, i + d));
      if (n === i) return;
      i = n; draw(); o.onChange(o.values[i], item);
    };
    item.left = () => move(-1);
    item.right = () => move(1);
    item.ok = () => move(i === spans.length - 1 ? -(spans.length - 1) : 1);   // OK cycles
    item.set = v => { i = Math.max(0, o.values.indexOf(v)); draw(); };
    return item;
  }

  function goRow(o) {
    return row(Object.assign({}, o, { ctl: o.ctl || el('span', 'go', 'Open ›') }));
  }

  /* ---------- focus ---------- */
  function focus(i) {
    if (i < 0 || i >= rows.length) return;
    if (rows[f]) rows[f].el.classList.remove('focus');
    f = i;
    rows[f].el.classList.add('focus');
    rows[f].el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }

  function onKey(action) {
    const r = rows[f];
    switch (action) {
      case 'up': focus(Math.max(0, f - 1)); return true;
      case 'down': focus(Math.min(rows.length - 1, f + 1)); return true;
      case 'left': if (r && r.left) r.left(); return true;
      case 'right': if (r && r.right) r.right(); return true;
      case 'ok': if (r && r.ok) r.ok(); return true;
      case 'lite': return true;
    }
    return false;
  }

  /* ---------- Sound ---------- */
  let vol = { level: 0, muted: false }, volItem;
  function buildVolume() {
    const wrap = el('div');
    wrap.style.display = 'flex'; wrap.style.alignItems = 'center'; wrap.style.gap = 'calc(var(--u)*1.2)';
    const icon = el('span'); const slider = el('div', 'slider'); const fill = el('div', 'fill'); slider.appendChild(fill);
    const num = el('span', 'vol-num');
    wrap.append(icon, slider, num);
    const draw = () => {
      icon.innerHTML = svg(vol.muted ? ICON_MUTE : ICON_VOL);
      fill.style.width = vol.level + '%';
      slider.classList.toggle('muted', vol.muted);
      num.textContent = vol.muted ? 'Muted' : vol.level;
    };
    const send = async body => {
      if (!needHelper()) return;
      try { vol = await H.request('/volume', { method: 'POST', body }); draw(); } catch (e) { TV.ui.toast('Could Not Change the Volume'); }
    };
    volItem = row({ name: 'Volume', hint: 'Left and Right to Change, OK to Mute', accent: '#1ed760', ctl: wrap });
    volItem.left = () => { vol.level = Math.max(0, vol.level - 5); vol.muted = false; draw(); send({ delta: -5 }); };
    volItem.right = () => { vol.level = Math.min(100, vol.level + 5); vol.muted = false; draw(); send({ delta: 5 }); };
    volItem.ok = () => { vol.muted = !vol.muted; draw(); send({ muted: vol.muted }); };
    draw();
    if (H.available) H.request('/volume').then(v => { vol = v; draw(); }).catch(() => {});
  }

  let outputItems = [], outputAnchor;
  function buildOutputs() {
    outputAnchor = el('div'); outputAnchor.hidden = true; list.appendChild(outputAnchor);
    if (!H.available) { row({ name: 'Sound Output', hint: 'Needs the Helper', info: true, before: outputAnchor }); return; }
    const loading = row({ name: 'Sound Output', hint: 'Loading Devices…', info: true, before: outputAnchor });
    outputItems = [loading];
    loadOutputs();
  }

  async function loadOutputs(keepFocusId) {
    let data;
    try { data = await H.request('/audio-output'); } catch (e) { outputItems[0] && outputItems[0].setHint('Could Not Read the Sound Devices'); return; }
    const first = rows.indexOf(outputItems[0]);
    const wasFocused = rows[f] && outputItems.includes(rows[f]);
    const focusedRow = rows[f];
    outputItems.forEach(it => { it.el.remove(); rows.splice(rows.indexOf(it), 1); });
    outputItems = [];
    const devices = data.devices || [];
    devices.forEach((d, k) => {
      const badge = el('span', 'badge' + (d.isDefault ? '' : ' dim'), d.isDefault ? 'In Use' : 'Use');
      const it = row({ name: d.name, accent: '#1ed760', ctl: badge, before: outputAnchor, index: first + k });
      it.deviceId = d.id;
      it.ok = async () => {
        if (d.isDefault) return;
        try { await H.request('/audio-output', { method: 'POST', body: { id: d.id } }); TV.ui.toast('Sound Now Plays on ' + d.name); loadOutputs(d.id); }
        catch (e) { TV.ui.toast('Could Not Switch the Sound Output'); }
      };
      outputItems.push(it);
    });
    if (!devices.length) outputItems.push(row({ name: 'No Sound Devices Found', info: true, before: outputAnchor, index: first }));
    if (wasFocused) {
      const k = Math.max(0, outputItems.findIndex(it => it.deviceId === keepFocusId));
      f = rows.indexOf(outputItems[k]); rows[f].el.classList.add('focus');
    } else if (focusedRow) {
      f = Math.max(0, rows.indexOf(focusedRow));   // same row as before, wherever it moved to
      rows.forEach(r => r.el.classList.remove('focus'));
      rows[f].el.classList.add('focus');
    }
  }

  /* ---------- Timers ---------- */
  let timer = { active: false }, timerItem, timerEndsAt = 0;
  const actionWord = a => a === 'shutdown' ? 'Shuts Down' : 'Goes to Standby';
  function timerHint() {
    if (!timer.active) return 'Off';
    const left = Math.max(0, Math.round((timerEndsAt - Date.now()) / 60000));
    const at = new Date(timerEndsAt).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    return actionWord(timer.action) + ' at ' + at + ' (in ' + left + ' Min)';
  }
  function applyTimer(t) {
    timer = t;
    timerEndsAt = t.active ? Date.now() + t.remainingSec * 1000 : 0;
    timerItem.set(t.active ? t.minutes : 0);
    timerItem.setHint(timerHint());
  }
  async function setTimer(minutes) {
    if (!needHelper()) { timerItem.set(0); return; }
    try { applyTimer(await H.request('/sleep-timer', { method: 'POST', body: { minutes, action: cfg.settings.sleepAction } })); }
    catch (e) { TV.ui.toast('Could Not Set the Sleep Timer'); }
  }

  /* ---------- System ---------- */
  function fmtUptime(s) {
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return d + (d === 1 ? ' Day, ' : ' Days, ') + h + (h === 1 ? ' Hour' : ' Hours');
    if (h) return h + (h === 1 ? ' Hour, ' : ' Hours, ') + m + ' Min';
    return m + ' Min';
  }

  async function openDesktop() {
    if (!needHelper()) return;
    let pin = '';
    const st = await H.request('/desktop');
    if (st.pinRequired) {
      pin = await TV.ui.pinPad('Enter PIN', 'To Open the Windows Desktop');
      if (pin == null) return;
    } else {
      const ok = await TV.ui.confirm({ title: 'Open the Windows Desktop?', text: 'Restart the launcher or the PC to get back to the TV home screen.',
        buttons: [{ label: 'Cancel', value: false }, { label: 'Open Desktop', value: true }] });
      if (!ok) return;
    }
    try {
      const r = await H.request('/desktop', { method: 'POST', body: { pin } });
      TV.ui.toast(r.testMode ? 'Test Mode: The Desktop Is Already Running' : 'Opening the Windows Desktop');
    } catch (e) { TV.ui.toast(e.status === 403 ? 'Wrong PIN' : 'Could Not Open the Desktop'); }
  }

  /* ---------- network speed test (js/speedtest.js) ---------- */
  async function runSpeedTest() {
    if (!navigator.onLine) { TV.ui.toast('No Internet Connection'); return; }
    const d = TV.ui.live({ title: 'Network Speed Test' });
    const grid = el('div', 'speed');
    const cells = {};
    [['ping', 'Ping', 'ms'], ['down', 'Download', 'Mbit/s'], ['up', 'Upload', 'Mbit/s']].forEach(([k, label, unit]) => {
      const c = el('div', 'speed-cell');
      const v = el('div', 'speed-val', '–');
      c.append(v, el('div', 'speed-label', label), el('div', 'speed-unit', unit));
      grid.appendChild(c);
      cells[k] = { c, v };
    });
    const status = el('div', 'dialog-text', '');
    d.body.append(grid, status);
    const ctrl = new AbortController();
    d.closed.then(() => ctrl.abort());
    const fmt = n => n >= 100 ? String(Math.round(n)) : n.toFixed(1);
    const show = (k, text, active) => { cells[k].v.textContent = text; cells[k].c.classList.toggle('active', !!active); };
    const verdict = mbps => mbps >= 25 ? 'Fast Enough for 4K Streaming' : mbps >= 10 ? 'Fine for HD Streaming'
      : mbps >= 5 ? 'Enough for Standard Quality' : 'Streams May Buffer at This Speed';

    for (;;) {
      ['ping', 'down', 'up'].forEach(k => show(k, '–', false));
      status.textContent = 'Measuring… Press Back to Stop';
      try {
        const r = await TV.speedTest.run(p => {
          if (p.phase === 'ping') { show('ping', '…', true); status.textContent = 'Checking the Response Time…'; }
          if (p.pingMs != null) show('ping', String(Math.round(p.pingMs)), false);
          if (p.phase === 'download') { show('down', fmt(p.mbps), true); status.textContent = 'Testing the Download Speed…'; }
          if (p.phase === 'upload') {
            show('down', fmt(p.downMbps), false); show('up', fmt(p.mbps), true);
            status.textContent = 'Testing the Upload Speed…';
          }
        }, ctrl.signal);
        show('ping', String(Math.round(r.pingMs)), false); show('down', fmt(r.downMbps), false); show('up', fmt(r.upMbps), false);
        status.textContent = verdict(r.downMbps);
      } catch (e) {
        if (ctrl.signal.aborted) return;
        console.warn('speed test failed', e);
        ['ping', 'down', 'up'].forEach(k => cells[k].c.classList.remove('active'));
        status.textContent = 'The Test Could Not Finish. Check the Internet Connection.';
      }
      const again = await d.setButtons([{ label: 'Done', value: false }, { label: 'Run Again', value: true }]);
      if (!again) { d.close(); return; }
      d.setButtons([]);
    }
  }

  let pinItem;
  async function changePin() {
    if (!needHelper()) return;
    const st = await H.request('/desktop');
    let current = '';
    if (st.pinRequired) {
      current = await TV.ui.pinPad('Enter Current PIN');
      if (current == null) return;
      const choice = await TV.ui.confirm({ title: 'Desktop PIN', buttons: [
        { label: 'Cancel', value: null }, { label: 'Change PIN', value: 'change' }, { label: 'Remove PIN', value: 'remove', danger: true }] });
      if (!choice) return;
      if (choice === 'remove') return savePin(current, '');
    }
    const a = await TV.ui.pinPad('New PIN', 'Choose 4 Digits');
    if (a == null) return;
    const b = await TV.ui.pinPad('Confirm PIN', 'Enter the Same 4 Digits Again');
    if (b == null) return;
    if (a !== b) { TV.ui.toast('The PINs Did Not Match'); return; }
    savePin(current, a);
  }
  async function savePin(current, next) {
    try {
      const r = await H.request('/desktop-pin', { method: 'POST', body: { current, new: next } });
      drawPin(r.pinRequired);
      TV.ui.toast(r.pinRequired ? 'PIN Saved' : 'PIN Removed');
    } catch (e) { TV.ui.toast(e.status === 403 ? 'Wrong PIN' : 'Could Not Save the PIN'); }
  }
  function drawPin(on) {
    pinItem.ctlEl.innerHTML = '';
    pinItem.ctlEl.append(el('span', 'badge' + (on ? ' ok' : ' dim'), on ? 'On' : 'Off'));
  }

  /* ---------- build ---------- */
  async function start() {
    cfg = await TV.ui.startPage(onKey);
    const s = cfg.settings;

    group('Sound');
    buildVolume();
    group('Sound Output');
    buildOutputs();

    group('Timers');
    timerItem = segRow({ name: 'Sleep Timer', hint: 'Off', accent: '#8a6cff',
      labels: ['Off', '30 Min', '60 Min', '90 Min'], values: [0, 30, 60, 90], value: 0, onChange: v => setTimer(v) });
    segRow({ name: 'When the Timer Ends', accent: '#8a6cff', labels: ['Standby', 'Shut Down'], values: ['sleep', 'shutdown'], value: s.sleepAction || 'sleep',
      onChange: async v => {
        await TV.config.saveSettings({ sleepAction: v });
        if (timer.active) setTimer(Math.max(1, Math.ceil((timerEndsAt - Date.now()) / 60000)));
      } });
    segRow({ name: 'Screensaver', hint: 'Photos, Time and Music on the Home Screen (Home Starts It Too)', accent: '#8a6cff',
      labels: ['Off', '2 Min', '5 Min', '10 Min', '15 Min'], values: [0, 2, 5, 10, 15], value: s.screensaverMinutes == null ? 5 : s.screensaverMinutes,
      onChange: v => TV.config.saveSettings({ screensaverMinutes: v }) });
    segRow({ name: 'Screen Off When Idle', hint: 'Only on the Home Screen', accent: '#8a6cff',
      labels: ['Off', '5 Min', '10 Min', '15 Min', '30 Min'], values: [0, 5, 10, 15, 30], value: s.screenOffMinutes || 0,
      onChange: v => TV.config.saveSettings({ screenOffMinutes: v }) });

    group('Look');
    segRow({ name: 'Wallpaper', hint: 'Changes With the Time of Day', accent: '#1aa3ff',
      labels: ['Dark Blue', 'Sage', 'Rotate'], values: ['blue', 'sage', 'rotate'], value: s.wallpaper || 'blue',
      onChange: v => { TV.config.saveSettings({ wallpaper: v }); TV.wallpaper.refresh(); } });
    segRow({ name: 'Lite Mode', hint: 'Turns Off Blur and Motion for a Smoother Picture', accent: '#1aa3ff',
      labels: ['Off', 'On'], values: [false, true], value: !!s.lite,
      onChange: v => { TV.config.saveSettings({ lite: v }); document.body.classList.toggle('lite', v); } });

    group('Connections');
    const wifi = goRow({ name: 'Wi-Fi', hint: 'Checking…', accent: '#14c3b4',
      ok: () => needHelper() && H.request('/open-settings/wifi', { method: 'POST' }).catch(() => TV.ui.toast('Could Not Open Wi-Fi Settings')) });
    const bt = goRow({ name: 'Bluetooth', hint: 'Pair Headphones or a Soundbar', accent: '#14c3b4',
      ok: () => needHelper() && H.request('/open-settings/bluetooth', { method: 'POST' }).catch(() => TV.ui.toast('Could Not Open Bluetooth Settings')) });

    goRow({ name: 'Network Speed Test', hint: 'Checks the Download and Upload Speed', accent: '#14c3b4',
      ctl: el('span', 'go', 'Start ›'), ok: runSpeedTest });

    group('System');
    goRow({ name: 'Restart Launcher', hint: 'Reloads This Home Screen', accent: '#8a8fb3', ctl: el('span', 'go', 'Restart ›'),
      ok: async () => {
        if (!needHelper()) return;
        const ok = await TV.ui.confirm({ title: 'Restart the Launcher?', buttons: [{ label: 'Cancel', value: false }, { label: 'Restart', value: true }] });
        if (ok) H.request('/restart-launcher', { method: 'POST' }).catch(() => {});
      } });
    goRow({ name: 'Remote Button Test', hint: 'Shows What Each Button Sends (Hold Back to Leave)', accent: '#8a8fb3',
      ok: () => { location.href = new URL('keytest.html', location.href).href; } });
    goRow({ name: 'Windows Desktop', hint: 'For Maintenance', accent: '#8a8fb3', ok: openDesktop });
    pinItem = row({ name: 'Desktop PIN', hint: 'Asked Before Opening the Windows Desktop', accent: '#8a8fb3', ok: changePin });
    drawPin(!!s.desktopPin);
    const storage = row({ name: 'Free Storage', info: true, ctl: el('span', null, '…') });
    const uptime = row({ name: 'Running For', info: true, ctl: el('span', null, '…') });
    const version = row({ name: 'Launcher Version', info: true, ctl: el('span', null, '…') });

    focus(0);

    if (H.available) {
      H.request('/ping').then(p => { document.getElementById('testPill').hidden = !p.testMode; }).catch(() => {});
      H.request('/sleep-timer').then(applyTimer).catch(() => {});
      setInterval(() => timerItem.setHint(timerHint()), 15000);
      H.request('/status', { timeout: 10000 }).then(st => {
        const n = st.network || {};
        wifi.setHint(n.wifi && /^connected$/i.test(n.wifi.state) ? 'Connected to ' + n.wifi.ssid + (n.wifi.signal ? ' (' + n.wifi.signal + ')' : '')
          : n.ethernet ? 'Using a Wired Connection' : n.wifi ? 'Not Connected' : 'No Wi-Fi Adapter Found');
        if (!(st.bluetooth && st.bluetooth.available)) bt.setHint('No Bluetooth Adapter Found');
        storage.ctlEl.firstChild.textContent = Math.round(st.storage.freeGB) + ' GB Free of ' + Math.round(st.storage.totalGB) + ' GB';
        uptime.ctlEl.firstChild.textContent = fmtUptime(st.uptimeSec);
        version.ctlEl.firstChild.textContent = st.version;
      }).catch(() => wifi.setHint('Could Not Check'));
    } else {
      [wifi, bt].forEach(r => r.setHint('Needs the Helper'));
      [storage, uptime, version].forEach(r => { r.ctlEl.firstChild.textContent = '—'; });
    }
  }

  start();
})();
