/* Config loading and the helper client.

   Where config comes from, first hit wins:
     1. the helper  (GET http://127.0.0.1:<port>/config/<name>)  - the normal case on the TV PC
     2. ../config/<name>.json                                      - when the repo is served over http (dev)
     3. the last copy that loaded, cached in localStorage          - helper down, still shows the home screen
     4. js/defaults.js (generated from config/ by scripts/sync-defaults.ps1)

   js/helper-token.js is written at install time and sets TV_HELPER = {port, token}.
   It is optional: without it, the launcher runs as a plain web page. */
window.TV = window.TV || {};

(function () {
  const H = window.TV_HELPER || null;
  const base = H ? 'http://127.0.0.1:' + H.port : null;
  const CACHE = 'tv.config.';
  // Resolved from this script's own location, so pages in launcher/pages/ find the same folder.
  const configDir = new URL('../../config/', document.currentScript.src).href;

  function timeout(ms) {
    const c = new AbortController();
    setTimeout(() => c.abort(), ms);
    return c.signal;
  }

  function cacheGet(name) {
    try { return JSON.parse(localStorage.getItem(CACHE + name)); } catch (e) { return null; }
  }
  function cacheSet(name, value) {
    try { localStorage.setItem(CACHE + name, JSON.stringify(value)); } catch (e) { /* private mode etc. */ }
  }

  async function request(path, opts) {
    if (!base) throw new Error('no helper configured');
    opts = opts || {};
    const res = await fetch(base + path, {
      method: opts.method || 'GET',
      headers: Object.assign({ 'X-TV-Token': H.token }, opts.body ? { 'Content-Type': 'application/json' } : {}),
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      signal: timeout(opts.timeout || 3000)
    });
    if (!res.ok) {
      const err = new Error('helper ' + res.status + ' on ' + path);
      err.status = res.status;
      try { err.body = await res.json(); } catch (e) { /* not json */ }
      throw err;
    }
    if (res.status === 204) return null;
    const type = res.headers.get('Content-Type') || '';
    return type.includes('json') ? res.json() : res.text();
  }

  async function load(name) {
    const sources = [
      ['helper', () => request('/config/' + name, { timeout: 1500 })],
      ['file',   async () => {
        const r = await fetch(configDir + name + '.json', { cache: 'no-store', signal: timeout(1500) });
        if (!r.ok) throw new Error(r.status);
        return r.json();
      }]
    ];
    for (const [src, get] of sources) {
      try {
        const v = await get();
        if (v && typeof v === 'object') { cacheSet(name, v); return { value: v, source: src }; }
      } catch (e) { /* try the next source */ }
    }
    const cached = cacheGet(name);
    if (cached) return { value: cached, source: 'cache' };
    const d = (window.TV_DEFAULTS || {})[name];
    return { value: d ? JSON.parse(JSON.stringify(d)) : {}, source: 'defaults' };
  }

  TV.config = {
    sources: {},
    load,              // one config file by name, e.g. 'wec-schedule' -> {value, source}
    cacheGet, cacheSet,
    async loadAll() {
      const names = ['apps', 'keymap', 'settings'];
      const out = {};
      await Promise.all(names.map(async n => {
        const r = await load(n);
        out[n] = r.value;
        TV.config.sources[n] = r.source;
      }));
      // Settings: defaults first (so a new setting always has a value), then changes the helper has not saved yet.
      const pending = cacheGet('pending-settings');
      out.settings = Object.assign({}, (window.TV_DEFAULTS || {}).settings, out.settings, pending);
      TV.config.data = out;
      if (pending) TV.config.saveSettings({});   // retry the sync in the background
      return out;
    },
    /* Change some settings. Kept locally right away; written to config/settings.json via the helper when it
       is running. Changes the helper could not save stay "pending" and win over the file until they sync. */
    async saveSettings(patch) {
      const s = Object.assign(TV.config.data.settings, patch);
      cacheSet('settings', s);
      const pending = Object.assign(cacheGet('pending-settings') || {}, patch);
      cacheSet('pending-settings', pending);
      try {
        await request('/settings', { method: 'POST', body: pending });
        try { localStorage.removeItem(CACHE + 'pending-settings'); } catch (e) { /* ignore */ }
        return true;
      } catch (e) { return false; }
    }
  };

  TV.helper = {
    available: !!base,
    request,
    launch: (id, url) => request('/launch/' + encodeURIComponent(id), { method: 'POST', timeout: 8000, body: url ? { url } : undefined }),
    status: () => request('/status')
  };
})();
