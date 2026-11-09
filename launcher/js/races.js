/* Race data: F1 from the Jolpica API (cached for offline use) and WEC from config/wec-schedule.json.
   Everything becomes one flat, time-sorted list of sessions:
     { id, series:'F1'|'WEC', season, round, event, place, session, start:Date, timeKnown, end:Date } */
window.TV = window.TV || {};

(function () {
  const API = 'https://api.jolpi.ca/ergast/f1/';
  const CACHE_NAME = 'f1-calendar';          // localStorage (tv.config.f1-calendar) and helper /cache/f1-calendar
  const MAX_AGE = 6 * 3600e3;                // refresh from the internet after 6 hours

  const F1_SESSIONS = [                      // Jolpica key -> name, length in minutes (for "Live Now")
    ['FirstPractice', 'Practice 1', 60], ['SecondPractice', 'Practice 2', 60], ['ThirdPractice', 'Practice 3', 60],
    ['SprintQualifying', 'Sprint Qualifying', 45], ['SprintShootout', 'Sprint Shootout', 45],
    ['Sprint', 'Sprint', 45], ['Qualifying', 'Qualifying', 60]
  ];

  /* A Jolpica {date, time} pair. Without a time the session is shown as "Time TBC". */
  function when(date, time) {
    if (!date) return null;
    if (time) return { start: new Date(date + 'T' + time.replace(/Z?$/, 'Z')), timeKnown: true };
    return { start: new Date(date + 'T12:00:00Z'), timeKnown: false };
  }

  function f1Sessions(races) {
    const out = [];
    (races || []).forEach(r => {
      const loc = (r.Circuit && r.Circuit.Location) || {};
      const base = { series: 'F1', season: +r.season, round: +r.round, event: r.raceName,
                     place: [loc.locality, loc.country].filter(Boolean).join(', ') };
      F1_SESSIONS.forEach(([key, name, mins]) => {
        const w = r[key] && when(r[key].date, r[key].time);
        if (w) out.push(Object.assign({ session: name, mins }, base, w));
      });
      const w = when(r.date, r.time);
      if (w) out.push(Object.assign({ session: 'Race', mins: 120 }, base, w));
    });
    return out;
  }

  function wecSessions(cfg) {
    const out = [];
    ((cfg && cfg.events) || []).forEach(ev => {
      const base = { series: 'WEC', season: +ev.season, round: +ev.round, event: ev.name,
                     place: [ev.circuit, ev.country].filter(Boolean).join(', ') };
      (ev.sessions || []).forEach(s => {
        const w = s.start ? { start: new Date(s.start), timeKnown: true } : when(s.date, null);
        if (!w || isNaN(w.start)) return;
        let mins = s.minutes;
        if (!mins && s.name === 'Race') {
          const h = /(\d+)\s*Hours/i.exec(ev.name);
          mins = h ? +h[1] * 60 : /1812/.test(ev.name) ? 600 : 360;
        }
        out.push(Object.assign({ session: s.name, mins: mins || 60 }, base, w));
      });
    });
    return out;
  }

  function finish(list) {
    list.forEach(s => {
      s.end = new Date(s.start.getTime() + s.mins * 60e3);
      s.id = [s.series, s.season, s.round, s.session].join('-');
    });
    return list.sort((a, b) => a.start - b.start || (a.series < b.series ? -1 : 1));
  }

  /* ---------- F1 cache: localStorage first (fast), the helper's copy as a backup ---------- */
  async function readCache() {
    let c = TV.config.cacheGet(CACHE_NAME);
    if (!c && TV.helper.available) {
      try { c = await TV.helper.request('/cache/' + CACHE_NAME, { timeout: 1500 }); } catch (e) { /* none */ }
    }
    return c && c.seasons ? c : null;
  }
  function writeCache(c) {
    TV.config.cacheSet(CACHE_NAME, c);
    if (TV.helper.available) TV.helper.request('/cache/' + CACHE_NAME, { method: 'POST', body: c, timeout: 4000 }).catch(() => {});
  }

  async function fetchSeason(year) {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), 8000);
    try {
      const r = await fetch(API + year + '.json?limit=100', { signal: c.signal, cache: 'no-store' });
      if (!r.ok) throw new Error('F1 API ' + r.status);
      const j = await r.json();
      return j.MRData.RaceTable.Races || [];
    } finally { clearTimeout(t); }
  }

  /* This season and next (the next one is empty until it is published). */
  async function fetchF1() {
    const y = new Date().getFullYear();
    const [now, next] = await Promise.all([fetchSeason(y), fetchSeason(y + 1).catch(() => [])]);
    return { fetched: new Date().toISOString(), seasons: { [y]: now, [y + 1]: next } };
  }

  TV.races = {
    /* Calls onData({sessions, f1:{state:'live'|'cached'|'offline'|'none', fetched}}) once with cached data (if any) and
       again when fresh data arrives. Returns once the internet attempt is over. */
    async load(onData, opts) {
      const [wecCfg, cached] = await Promise.all([TV.config.load('wec-schedule'), readCache()]);
      const wec = wecSessions(wecCfg.value);
      const emit = (cache, state) => {
        const f1 = cache ? Object.values(cache.seasons).flatMap(f1Sessions) : [];
        onData({ sessions: finish(f1.concat(wec.map(s => Object.assign({}, s)))),
                 f1: { state, fetched: cache && cache.fetched ? new Date(cache.fetched) : null } });
      };
      if (cached) emit(cached, 'cached');      // no saved copy yet: wait for the download instead of flashing "empty"
      const age = cached && cached.fetched ? Date.now() - new Date(cached.fetched) : Infinity;
      if (!(opts && opts.force) && age < MAX_AGE) return;
      try {
        const fresh = await fetchF1();
        writeCache(fresh);
        emit(fresh, 'live');
      } catch (e) {
        console.warn('[races] F1 download failed, using the saved copy', e);
        emit(cached, cached ? 'offline' : 'none');
      }
    },
    // exposed for tests
    _f1Sessions: f1Sessions, _wecSessions: wecSessions
  };
})();
