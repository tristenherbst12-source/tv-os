/* Screensaver for the home screen, as on an Android TV: nature photos that slowly drift and crossfade, with the
   time, the date and what Spotify is playing. Starts when Home is pressed on the home screen, or after
   settings.screensaverMinutes without a button press there (js/home.js decides when). Any button or touchpad
   movement ends it; that button does nothing else.

   Photos: featured pictures from Wikimedia Commons (free licences; the photographer is credited on screen). The
   list is fetched at most once a day and kept, so the screensaver also works when the internet is down (with
   the photos the browser still has, else the home screen's own wallpaper). */
window.TV = window.TV || {};

TV.screensaver = (function () {
  'use strict';
  const CATEGORIES = ['mountains', 'lakes', 'waterfalls', 'beaches', 'forests', 'sunsets', 'landscapes'];
  const API = 'https://commons.wikimedia.org/w/api.php?action=query&format=json&origin=*&generator=categorymembers' +
    '&gcmtype=file&gcmlimit=60&prop=imageinfo&iiprop=url|size|extmetadata&iiextmetadatafilter=Artist|LicenseShortName' +
    '&iiurlwidth=1920&gcmtitle=Category:Featured_pictures_of_';
  const CACHE = 'screensaver-photos';
  const SHOW_MS = 25000;            // each photo
  const $ = id => document.getElementById(id);

  let photos = [], order = [], at = 0, timer = null, clockTimer = null, npTimer = null, active = false, front = 0;
  let startedAt = 0, lastX = null, lastY = null;

  const plain = html => { const d = document.createElement('div'); d.innerHTML = html || ''; return d.textContent.replace(/\s+/g, ' ').trim(); };

  async function fetchCategory(cat) {
    const r = await fetch(API + cat, { signal: AbortSignal.timeout(10000) });
    const j = await r.json();
    return Object.values((j.query && j.query.pages) || {}).map(p => {
      const i = p.imageinfo && p.imageinfo[0];
      if (!i || !i.thumburl || i.width < i.height * 1.3) return null;      // wide photos only (they fill a TV)
      const m = i.extmetadata || {};
      return { url: i.thumburl, by: plain(m.Artist && m.Artist.value).slice(0, 60), lic: plain(m.LicenseShortName && m.LicenseShortName.value) };
    }).filter(Boolean);
  }

  async function loadPhotos() {
    let cached = null;
    try { cached = JSON.parse(localStorage.getItem(CACHE) || 'null'); } catch (e) { /* storage blocked */ }
    if (cached && cached.photos && cached.photos.length) photos = cached.photos;
    if (cached && Date.now() - cached.at < 86400e3) return;
    try {
      const lists = await Promise.all(CATEGORIES.map(c => fetchCategory(c).catch(() => [])));
      const all = [].concat(...lists);
      const seen = new Set();
      const fresh = all.filter(p => !seen.has(p.url) && seen.add(p.url));
      if (fresh.length) {
        photos = fresh;
        try { localStorage.setItem(CACHE, JSON.stringify({ at: Date.now(), photos })); } catch (e) { /* full */ }
      }
    } catch (e) { console.warn('[screensaver] photos', e); }
  }

  function shuffle() {
    order = photos.map((_, i) => i);
    for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [order[i], order[j]] = [order[j], order[i]]; }
    at = 0;
  }

  // Next photo: loaded in the hidden layer first, then faded in over the shown one.
  function next(tries = 0) {
    if (!active || !photos.length || tries > 5) return;
    if (at >= order.length) shuffle();
    const p = photos[order[at++]];
    const img = new Image();
    img.onload = () => {
      if (!active) return;
      const layers = document.querySelectorAll('#saver .ss-photo');
      const show = layers[1 - front], hide = layers[front];
      show.style.backgroundImage = 'url("' + p.url + '")';
      show.classList.remove('drift'); void show.offsetWidth; show.classList.add('drift');   // restart the slow zoom
      show.classList.add('on'); hide.classList.remove('on');
      front = 1 - front;
      $('ssCredit').textContent = p.by ? 'Photo: ' + p.by + (p.lic ? ' · ' + p.lic : '') + ' · Wikimedia Commons' : '';
    };
    img.onerror = () => next(tries + 1);
    img.src = p.url;
  }

  function drawClock() {
    const d = new Date();
    $('ssTime').textContent = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    $('ssDate').textContent = d.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' });
  }

  function drawMusic() {
    if (!TV.helper || !TV.helper.available) return;
    TV.helper.request('/now-playing').then(r => {
      const np = r && r.nowPlaying, box = $('ssMusic');
      if (!np) { box.hidden = true; return; }
      if ($('ssArt').getAttribute('src') !== (np.art || '')) $('ssArt').setAttribute('src', np.art || '');
      $('ssSong').textContent = np.title;
      $('ssArtist').textContent = np.artist || '';
      box.classList.toggle('paused', !np.playing);
      box.hidden = false;
    }).catch(() => {});
  }

  function start() {
    if (active) return;
    active = true; startedAt = performance.now(); lastX = lastY = null;
    document.body.classList.add('saver-on');
    $('saver').classList.add('show');
    drawClock(); drawMusic();
    clockTimer = setInterval(drawClock, 1000);
    npTimer = setInterval(drawMusic, 5000);
    if (!order.length) shuffle();
    next();
    timer = setInterval(next, SHOW_MS);
  }

  function stop() {
    if (!active) return;
    active = false;
    clearInterval(timer); clearInterval(clockTimer); clearInterval(npTimer);
    $('saver').classList.remove('show');
    document.body.classList.remove('saver-on');
    document.querySelectorAll('#saver .ss-photo').forEach(l => l.classList.remove('on'));
    if (api.onStop) api.onStop();
  }

  // Any button ends it (and does nothing else); so does real touchpad movement.
  // The media keys (play/pause, next, previous) control Spotify and leave the screensaver on; the song shown
  // updates a moment later.
  const MEDIA_KEYS = /^Media(PlayPause|Play|Pause|Stop|TrackNext|TrackPrevious)$/;
  window.addEventListener('keydown', e => {
    if (!active) return;
    if (MEDIA_KEYS.test(e.key)) { setTimeout(drawMusic, 900); setTimeout(drawMusic, 2500); return; }
    e.preventDefault(); e.stopImmediatePropagation();
    stop();
  }, true);
  window.addEventListener('mousemove', e => {
    if (!active) return;
    const moved = lastX !== null && Math.hypot(e.screenX - lastX, e.screenY - lastY) > 8;
    lastX = e.screenX; lastY = e.screenY;
    if (moved && performance.now() - startedAt > 1000) stop();
  }, true);
  window.addEventListener('mousedown', () => { if (active) stop(); }, true);
  window.addEventListener('blur', stop);            // an app came to the front

  loadPhotos();
  setInterval(loadPhotos, 6 * 3600e3);

  const api = { start, stop, onStop: null, get active() { return active; } };
  return api;
})();
