/* TV remote navigation for ordinary websites. helper\tvnav-host.ps1 adds it to every page of every TV window.

   Arrows   move a highlight to the nearest clickable thing in that direction (scrolling when nothing is left
            on screen). Inside a text box, Left/Right move the caret and Up/Down leave the box.
   OK       (Enter) presses the highlighted thing.
   Back     (Backspace, outside text boxes) leaves full screen, or goes back a page.
   Video    while watching: Left/Right seek 10 s; OK makes the video full screen (or, once it fills the screen,
            pauses / plays); Up/Down bring the highlight back. The remote's play/pause key works natively.
   The pointer (touchpad) still works as normal; moving it hides the highlight. */
(function () {
  'use strict';
  if (window.top !== window) return;
  if (window.__tvnav) return;            // added both on page start and to the page already open: run once
  Object.defineProperty(window, '__tvnav', { value: true });

  const CLICKABLE = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [contenteditable=""], ' +
    '[contenteditable=true], [role=button], [role=link], [role=tab], [role=menuitem], [role=option], [role=checkbox], ' +
    '[role=switch], [role=radio], [role=slider], [tabindex]:not([tabindex="-1"]), [onclick]';
  const SEEK_SECONDS = 10;
  // Netflix: its player does its own seeking with Left/Right (it refuses being moved from outside), and a card
  // under the (hidden) pointer pops up a preview that covers its neighbours, so the pointer is moved off the page.
  const NETFLIX = /(^|\.)netflix\.com$/.test(location.hostname);
  // Rows a site draws as one thing but builds from several links and buttons: one stop each, OK plays it.
  const ROW_STOPS = location.hostname === 'open.spotify.com' ? '[data-testid="tracklist-row"]' : null;
  const nativePlayer = () => NETFLIX && location.pathname.startsWith('/watch');
  let DEBUG = false;
  try { DEBUG = sessionStorage.getItem('tvnav-debug') === '1'; } catch (e) { /* storage blocked */ }
  let current = null;           // highlighted element
  let ring = null;              // the highlight box
  let usingKeys = false;

  /* ---------- the highlight ---------- */
  function ensureRing() {
    if (ring && ring.isConnected) return ring;
    ring = document.createElement('div');
    ring.id = 'tvnav-ring';
    ring.setAttribute('aria-hidden', 'true');
    ring.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border-radius:10px;display:none;' +
      'box-shadow:0 0 0 3px #fff,0 0 0 6px rgba(80,140,255,.85),0 0 24px 6px rgba(80,140,255,.55);transition:all .12s ease-out';
    (document.body || document.documentElement).appendChild(ring);
    return ring;
  }
  /* The highlighted thing was replaced by a copy (Netflix rebuilds a row's cards when it pages): carry on from the
     copy, the same link nearest to where it was. */
  function relocate() {
    if (!current || current.isConnected || !current.getAttribute) return;
    const href = current.getAttribute('href'), label = current.getAttribute('aria-label');
    if (!href && !label) return;
    // In the same row if that is still there (the same film is often in several rows), else on the same level.
    const row = rowKey(current);
    const scope = row && row.isConnected ? row : document;
    let best = null, dist = Infinity;
    for (const c of scope.querySelectorAll(href ? 'a[href]' : '[aria-label]')) {
      if (href ? c.getAttribute('href') !== href : c.getAttribute('aria-label') !== label) continue;
      const b = c.getBoundingClientRect();
      if (b.width < 2) continue;
      const d = lastBox ? Math.abs(b.left - lastBox.left) + 10 * Math.abs(b.top - lastBox.top) : 0;
      if (d < dist) { dist = d; best = c; }
    }
    if (best) { current = best; lastBox = best.getBoundingClientRect(); try { best.focus({ preventScroll: true }); } catch (e) { /* ignore */ } }
  }
  function drawRing() {
    relocate();
    const r = ensureRing();
    if (!current || !current.isConnected || !usingKeys) { r.style.display = 'none'; return; }
    const b = current.getBoundingClientRect();
    if (b.width < 2 || b.height < 2) { r.style.display = 'none'; return; }
    r.style.display = 'block';
    r.style.left = (b.left - 2) + 'px'; r.style.top = (b.top - 2) + 'px';
    r.style.width = (b.width + 4) + 'px'; r.style.height = (b.height + 4) + 'px';
  }
  let rafPending = false;
  function redrawSoon() {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(() => { rafPending = false; drawRing(); });
  }
  window.addEventListener('scroll', redrawSoon, true);
  window.addEventListener('resize', redrawSoon);
  setInterval(() => { if (usingKeys && current) drawRing(); }, 400);   // pages that move things around by themselves

  /* ---------- what can be selected ---------- */
  function visibleBox(el) {
    // The part of el that is really on screen: clipped by every ancestor that hides overflow.
    let b = el.getBoundingClientRect();
    let left = b.left, top = b.top, right = b.right, bottom = b.bottom;
    for (let p = el.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
      const cs = getComputedStyle(p);
      if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible') {
        const pb = p.getBoundingClientRect();
        if (cs.overflowX !== 'visible') { left = Math.max(left, pb.left); right = Math.min(right, pb.right); }
        if (cs.overflowY !== 'visible') { top = Math.max(top, pb.top); bottom = Math.min(bottom, pb.bottom); }
      }
      if (cs.position === 'fixed') break;
    }
    return { left, top, right, bottom, width: right - left, height: bottom - top, full: b };
  }

  if (DEBUG) window.__tvnavCandidates = () => candidates();   // for testing (sessionStorage tvnav-debug = 1)
  function candidates() {
    const vh = innerHeight, vw = innerWidth;
    const out = [];
    const seen = new Set();
    for (const el of [...document.querySelectorAll(CLICKABLE), ...pointerBoxes(), ...(ROW_STOPS ? document.querySelectorAll(ROW_STOPS) : [])]) {
      if (seen.has(el) || el === ring) continue;
      seen.add(el);
      // (aria-hidden is not a reason to skip: sites hide duplicate links such as video thumbnails from screen
      // readers, and those are exactly what a TV remote should land on.)
      if (el.disabled) continue;
      // Netflix's row arrows are not stops: Right at the end of the screen pages the row on by itself.
      if (NETFLIX && (/(^|\s)handle/.test(String(el.className)) || /^see (more|previous) titles/i.test(el.getAttribute('aria-label') || '') ||
          (el.tagName === 'DIV' && el.closest('.carousel-row, .lolomoRow') && !el.querySelector('img')))) continue;
      const b = el.getBoundingClientRect();
      if (b.width < 12 || b.height < 12) continue;
      // Whole rows or panels made focusable (Spotify does this) are containers, not things to press.
      if (b.width > vw * 1.1 || b.width * b.height > vw * vh * 0.6) continue;
      if (b.bottom < -vh * 1.5 || b.top > vh * 2.5 || b.right < -vw || b.left > vw * 2) continue;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
      if (!(paints(el) || clickLayer(el, b)) || covered(el, b)) continue;
      out.push(el);
    }
    if (ROW_STOPS) {
      const rows = out.filter(e => e.matches(ROW_STOPS));
      if (rows.length) for (let i = out.length - 1; i >= 0; i--) if (!out[i].matches(ROW_STOPS) && rows.some(r => r.contains(out[i]))) out.splice(i, 1);
    }
    // Tiles: sites often make the whole tile clickable (pointer cursor, cover picture) but only its title text a
    // link (Spotify). Then the tile is the stop, and the bits inside it are not stops of their own.
    const tiles = new Set();
    for (let i = 0; i < out.length; i++) {
      const t = tileAround(out[i]);
      if (t) { tiles.add(t); out[i] = t; }
    }
    if (tiles.size) {
      for (let i = out.length - 1; i >= 0; i--) {
        const el = out[i];
        if (tiles.has(el)) continue;
        for (const t of tiles) if (t.contains(el)) { out.splice(i, 1); break; }
      }
    }
    for (let i = out.length - 1; i >= 0; i--) if (out.indexOf(out[i]) !== i) out.splice(i, 1);   // tiles found twice
    // Containers are not stops: screen-wide strips that hold their own buttons (cookie banners, bars), and any
    // other focusable box (not itself a link, button or field) holding two or more.
    for (let i = out.length - 1; i >= 0; i--) {
      const el = out[i];
      const inside = out.filter(o => o !== el && el.contains(o)).length;
      if (!inside || tiles.has(el)) continue;
      if (el.getBoundingClientRect().width >= vw * 0.9 || (inside >= 2 && !/^(A|BUTTON|INPUT|SELECT|TEXTAREA)$/.test(el.tagName))) out.splice(i, 1);
    }
    // Full screen: only the player's own controls (the rest of the page is not showing). YouTube's "more videos"
    // arrow is left out: just highlighting it slides a panel over the video.
    // (Only the player box: YouTube's full screen also holds the description and comments below it.)
    if (document.fullscreenElement) {
      // (plus an open menu wherever the site draws it: Twitch puts its settings menu outside the player)
      const root = fullscreenPlayer();
      return out.filter(el => (root.contains(el) || el.closest('[role="menu"], [role="listbox"], [role="dialog"]')) &&
        document.fullscreenElement.contains(el) && !/^more videos/i.test(el.getAttribute('aria-label') || '') &&
        !el.closest('[class*="caption-window" i], [class*="captions" i]'));     // (subtitle text is not a button)
    }
    // A pop-up is open (cookie choices, a sign-in box): stay inside it until it closes, as a TV does.
    const pop = openPopup();
    if (pop) {
      const inPop = out.filter(el => pop.contains(el));
      if (inPop.length) return inPop;
    }
    // An element inside another candidate of nearly the same size is the same thing twice (e.g. a card link and
    // its inner button): keep the outer one.
    const kept = new Set(out);
    const nested = out.filter(el => {
      for (let p = el.parentElement; p; p = p.parentElement) {
        if (kept.has(p)) {
          const a = el.getBoundingClientRect(), b = p.getBoundingClientRect();
          if (a.width * a.height > 0.6 * b.width * b.height) return false;
          break;
        }
      }
      return true;
    });
    // Links to the same page touching each other (a video's thumbnail and the title right under it) are one stop:
    // keep the biggest. Ones further apart stay separate: streaming sites show the same film in neighbouring rows,
    // and merging those made Up/Down skip a whole row.
    const byHref = new Map();
    const result = [];
    for (const el of nested) {
      const href = el.tagName === 'A' && el.href && linkKey(el);
      if (!href) { result.push(el); continue; }
      const b = el.getBoundingClientRect();
      const group = byHref.get(href) || [];
      const near = group.find(g => edgeGap(g.b, b) < 48);
      if (near) {
        if (b.width * b.height > near.b.width * near.b.height) { result[near.i] = el; near.b = b; }
        continue;
      }
      group.push({ b, i: result.length });
      byHref.set(href, group);
      result.push(el);
    }
    return result;
  }

  const letGo = new WeakSet();      // pop-ups the highlight was stuck in and left
  let stuck = 0;
  // What happened, for tvnav-host.log (so a page that misbehaves on the TV can be fixed without seeing it).
  let notes = 0, lastNote = 0;
  function describe(el) {
    const b = el.getBoundingClientRect();
    const name = (el.getAttribute('aria-label') || el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 30);
    return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.getAttribute('role') ? '[' + el.getAttribute('role') + ']' : '') +
      ' "' + name + '" @' + Math.round(b.left) + ',' + Math.round(b.top) + ' ' + Math.round(b.width) + 'x' + Math.round(b.height);
  }
  function note(msg) {
    if (typeof window.tvnavLog !== 'function' || notes > 60 || performance.now() - lastNote < 1500) return;
    notes++; lastNote = performance.now();
    try { window.tvnavLog(location.host + location.pathname.slice(0, 40) + ': ' + msg); } catch (e) { /* ignore */ }
  }
  /* Boxes that are clickable only because the site listens for clicks on them (DStv's profiles, channels and
     cards are plain boxes): the outermost box with a hand pointer, with no link or button inside it. */
  function pointerBoxes() {
    const out = [];
    if (!document.body) return out;
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    for (let n = walk.nextNode(), seen = 0; n && seen < 6000; n = walk.nextNode(), seen++) {
      if (n === ring || /^(A|BUTTON|INPUT|SELECT|TEXTAREA|svg|path|SCRIPT|STYLE)$/.test(n.tagName)) continue;
      const p = n.parentElement;
      if (getComputedStyle(n).cursor !== 'pointer' || (p && getComputedStyle(p).cursor === 'pointer')) continue;
      const b = n.getBoundingClientRect();
      if (b.width < 24 || b.height < 24 || b.bottom < -innerHeight || b.top > innerHeight * 2.5) continue;
      // (a hidden edit button inside, as on DStv's profiles, does not count)
      if (n.matches(CLICKABLE) || [...n.querySelectorAll(CLICKABLE)].some(c => {
        const r = c.getBoundingClientRect();
        return r.width >= 12 && r.height >= 12 && c.checkVisibility({ opacityProperty: true, visibilityProperty: true });
      })) continue;
      out.push(n);
    }
    return out;
  }

  // The front-most open pop-up: a dialog (or a box marked modal) that is showing and of a real size.
  function openPopup() {
    const found = [...document.querySelectorAll('dialog[open], [aria-modal="true"], [role="dialog"], [role="alertdialog"]')]
      .filter(d => {
        const b = d.getBoundingClientRect();
        return b.width > 120 && b.height > 80 && b.bottom > 0 && b.top < innerHeight && !hoverPreview(d) && !letGo.has(d) &&
          d.checkVisibility({ opacityProperty: true, visibilityProperty: true });
      });
    return found.length ? found[found.length - 1] : null;      // the last one in the page is usually on top
  }
  // Hover previews (Netflix's card pop-up) are not pop-ups to stay in.
  function hoverPreview(d) { return /mini-modal|preview-?modal--mini|hover-?card/i.test(String(d.className)) && d.getAttribute('aria-modal') !== 'true'; }
  // The page's pointer off the page, so nothing shows as hovered (only where hover pops things up: Netflix).
  function parkPointer() {
    if (!NETFLIX || document.fullscreenElement || typeof window.tvnavClick !== 'function') return;
    ignoreMouseUntil = performance.now() + 500;
    window.tvnavClick(JSON.stringify({ x: -40, y: -40, move: true }));
  }

  // The tile a small link sits in, if any: a box up to 5 levels up with a pointer cursor and a big picture,
  // clearly bigger than the link (3x) but not a whole panel.
  const tileCache = new WeakMap();
  // A picture covering at least a third of the box (cover art, not a channel's little round picture).
  function bigPicture(box, boxArea) {
    for (const im of box.querySelectorAll('img, picture, canvas, video, [style*="background-image"]')) {
      const r = im.getBoundingClientRect();
      if (r.width * r.height >= boxArea / 3) return true;
    }
    return false;
  }
  function tileAround(el) {
    if (tileCache.has(el)) return tileCache.get(el);
    let found = null;
    const a = el.getBoundingClientRect(), area = a.width * a.height;
    if (/^(A|BUTTON)$/.test(el.tagName) || el.getAttribute('role')) {
      let p = el.parentElement;
      for (let i = 0; p && i < 5 && p !== document.body; i++, p = p.parentElement) {
        const b = p.getBoundingClientRect(), pa = b.width * b.height;
        if (pa > innerWidth * innerHeight * 0.3 || b.width > innerWidth * 0.6) break;
        // A box with a row of its own buttons (Netflix's title panel: Resume, +, Like) is not one tile.
        if ([...p.querySelectorAll('a[href], button, [role=button]')].filter(x => {
          const r = x.getBoundingClientRect();
          return r.width >= 12 && r.height >= 12 && x.checkVisibility({ opacityProperty: true, visibilityProperty: true });
        }).length >= 3) break;
        if (pa >= area * 3 && getComputedStyle(p).cursor === 'pointer' && bigPicture(p, pa)) { found = p; }
      }
    }
    tileCache.set(el, found);
    return found;
  }

  function edgeGap(a, b) {
    const dx = Math.max(0, Math.max(a.left, b.left) - Math.min(a.right, b.right));
    const dy = Math.max(0, Math.max(a.top, b.top) - Math.min(a.bottom, b.bottom));
    return Math.hypot(dx, dy);
  }

  /* Does el show anything? Sites keep empty, see-through clickable boxes around (hover-only buttons, click
     catchers), which made the highlight land on "nothing". Looks for text, an image, or a filled/bordered box. */
  const CLEAR = /^(transparent|rgba\(.*,\s*0\))$/;
  function boxShows(n, cs) {
    if (cs.backgroundImage !== 'none' || !CLEAR.test(cs.backgroundColor)) return true;
    return parseFloat(cs.borderTopWidth) > 0 && cs.borderTopStyle !== 'none' && !CLEAR.test(cs.borderTopColor);
  }
  // A see-through click area laid exactly over something that shows (Spotify's library rows): that thing.
  function clickLayer(el, b) {
    if (getComputedStyle(el).cursor !== 'pointer') return false;
    for (let p = el.parentElement, i = 0; p && i < 2; p = p.parentElement, i++) {
      const pb = p.getBoundingClientRect();
      if (pb.width * pb.height > b.width * b.height * 1.3) return false;
      if (paints(p)) return true;
    }
    return false;
  }
  function paints(el) {
    if (/^(INPUT|SELECT|TEXTAREA|IMG|VIDEO|CANVAS|IFRAME)$/.test(el.tagName)) return true;
    if (boxShows(el, getComputedStyle(el))) return true;
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(), seen = 0; n; n = walk.nextNode()) {
      if (++seen > 80) return true;                     // big and complicated: assume it shows something
      if (n.nodeType === 3) {
        if (!n.data.trim()) continue;
        const p = n.parentElement;
        if (p && p.checkVisibility({ opacityProperty: true, visibilityProperty: true }) &&
            !CLEAR.test(getComputedStyle(p).color)) return true;
        continue;
      }
      const b = n.getBoundingClientRect();
      if (b.width < 6 || b.height < 6) continue;
      if (!n.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
      if (/^(IMG|svg|VIDEO|CANVAS|PICTURE)$/.test(n.tagName)) return true;
      if (boxShows(n, getComputedStyle(n))) return true;
    }
    return false;
  }

  /* Hidden under something else (another layer, a pop-up) at its middle. Things under a fixed or sticky bar
     (the site's header) still count: selecting them scrolls them out from under it. */
  // Where OK should click an element: a point where it really is on top (not always its middle: the bottom of
  // YouTube's settings menu lies over the progress bar's hover area).
  const clickPoints = new WeakMap();
  function covered(el, b) {
    // Only the part showing in its scrolling list counts (Spotify's song list runs on under the player bar).
    const v = visibleBox(el);
    if (v.width < 8 || v.height < 8) return false;               // scrolled out of its list: cannot tell
    b = { left: v.left, top: v.top, width: v.width, height: v.height };
    const x = b.left + b.width / 2, y = b.top + b.height / 2;
    if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return false;   // off screen: cannot tell
    clickPoints.delete(el);
    for (const [fx, fy] of [[0.5, 0.5], [0.5, 0.25], [0.25, 0.5], [0.75, 0.5], [0.5, 0.75]]) {
      const px = b.left + b.width * fx, py = b.top + b.height * fy;
      const h = document.elementFromPoint(px, py);
      if (h && (h === el || el.contains(h))) { clickPoints.set(el, { fx, fy }); return false; }
    }
    const hit = document.elementFromPoint(x, y);
    if (!hit || hit === el || el.contains(hit) || hit === ring) return false;
    // Under a row's own edge arrow (Netflix) it is the next card to page to, not hidden for good.
    const strip = hit.closest('div');
    if (NETFLIX && strip && strip.closest('.carousel-row, .lolomoRow') && strip.getBoundingClientRect().width < 90) return false;
    // A text box under its own floating label (Netflix's sign-in) is not covered.
    const label = hit.closest('label');
    if (label && (label.control === el || label.contains(el) || (el.labels && [...el.labels].includes(label)))) return false;
    if (el.labels && [...el.labels].some(l => l.contains(hit))) return false;
    // ...or under text inside its own wrapper (a label drawn as plain text over the box)
    const area = b.width * b.height;
    for (let p = el.parentElement, i = 0; p && i < 3; p = p.parentElement, i++) {
      const pb = p.getBoundingClientRect();
      if (pb.width * pb.height > area * 1.6) break;
      if (p.contains(hit)) return false;
    }
    for (let p = hit, i = 0; p && i < 25; p = p.parentElement, i++) {
      const pos = getComputedStyle(p).position;
      if (pos === 'fixed' || pos === 'sticky') return false;
    }
    return true;
  }

  // Which page a link leads to, ignoring tracking extras (YouTube's thumbnail and title links differ only there).
  function linkKey(a) {
    try {
      const u = new URL(a.href);
      if (u.hash && u.pathname === location.pathname) return null;        // in-page links
      // The query counts (Netflix's films are all /browse?jbv=<id>), except tracking and playlist extras.
      const keep = [...u.searchParams].filter(([k]) => !/^(utm_.*|pp|si|feature|t|start_radio|index|list|tctx|track.*)$/i.test(k))
        .map(([k, v]) => k + '=' + v).sort().join('&');
      return u.origin + u.pathname + (keep ? '?' + keep : '');
    } catch (e) { return null; }
  }

  function isTextBox(el) {
    if (!el) return false;
    if (el.isContentEditable) return true;
    if (el.tagName === 'TEXTAREA') return true;
    if (el.tagName === 'INPUT') return !/^(button|submit|reset|checkbox|radio|range|color|file|image)$/i.test(el.type);
    return false;
  }

  /* ---------- moving ---------- */
  /* Lower is better; Infinity = not in that direction. A target must really lie beyond the current item (its
     near edge past our middle, its middle past our far edge), and targets in the same column (Up/Down) or the
     same row (Left/Right) win clearly over ones that are only diagonal. */
  function score(f, t, dir) {
    const fcx = (f.left + f.right) / 2, fcy = (f.top + f.bottom) / 2;
    const tcx = (t.left + t.right) / 2, tcy = (t.top + t.bottom) / 2;
    const slackY = Math.min(f.height, t.height) * 0.25, slackX = Math.min(f.width, t.width) * 0.25;
    let gap;
    switch (dir) {
      case 'down':  if (t.top < fcy || tcy <= f.bottom - slackY) return Infinity; gap = t.top - f.bottom; break;
      case 'up':    if (t.bottom > fcy || tcy >= f.top + slackY) return Infinity; gap = f.top - t.bottom; break;
      case 'right': if (t.left < fcx || tcx <= f.right - slackX) return Infinity; gap = t.left - f.right; break;
      case 'left':  if (t.right > fcx || tcx >= f.left + slackX) return Infinity; gap = f.left - t.right; break;
    }
    const vertical = dir === 'up' || dir === 'down';
    const shared = vertical ? Math.min(f.right, t.right) - Math.max(f.left, t.left)
                            : Math.min(f.bottom, t.bottom) - Math.max(f.top, t.top);
    const sideways = shared > 0 ? 0 : 250 + -shared * 3;
    const offset = vertical ? Math.abs(tcx - fcx) : Math.abs(tcy - fcy);
    return Math.max(gap, 0) + sideways + offset * 0.1;
  }

  function startBox(dir) {
    // No highlight yet: start from the top-left of the screen (or the bottom for Up).
    const y = dir === 'up' ? innerHeight : 0;
    return { left: 0, right: innerWidth * 0.1, top: y, bottom: y, width: innerWidth * 0.1, height: 0 };
  }

  /* Column memory, as on a TV: Up/Down keep to the column you were in (set by the last Left/Right), so going
     down through rows of different card sizes does not drift sideways. */
  let anchorX = null;

  function move(dir) {
    relocate();
    const fromEl = current && current.isConnected ? current : null;
    // Where the highlight is. If that thing vanished when it got focus (Prime's search icon turns into a search
    // box), carry on from where it was.
    let from = fromEl ? fromEl.getBoundingClientRect() : startBox(dir);
    if (fromEl && (from.width < 2 || from.height < 2) && lastBox) from = lastBox;
    const vertical = dir === 'up' || dir === 'down';
    const list = [];
    for (const el of candidates()) {
      if (el === fromEl) continue;
      if (fromEl && (fromEl.contains(el) || el.contains(fromEl))) continue;
      const v = visibleBox(el);
      let box = v;
      if (v.width < 8 || v.height < 8) {
        // Clipped away. Fine inside a scrolling area, or (Left/Right) further along the same row: carousels that
        // hide their next cards. Otherwise it is a page of something that is not showing.
        const sameRow = !vertical && Math.min(from.bottom, v.full.bottom) - Math.max(from.top, v.full.top) > from.height * 0.5;
        if (!insideScroller(el) && !sameRow) continue;
        box = v.full;
      }
      // Netflix: cards peeking in at a row's edge are not stops, except to page the row on (Right), or back to
      // where it started (Left). Its rows wrap round, so Left on the first card would jump to the row's end.
      if (NETFLIX && v.width < v.full.width * 0.9) {
        if (vertical || (dir === 'left' && !((rowPages.get(rowKey(el)) || 0) > 0))) continue;
      }
      if (score(from, box, dir) === Infinity) continue;
      list.push({ el, b: box, hidden: box === v.full });
    }
    // Up goes back through the rows above (scrolling to them) before the menu bar pinned to the top of the screen.
    let pool = list;
    if (dir === 'up' && fromEl && !pinned(fromEl)) {
      const rows = list.filter(c => !pinned(c.el));
      if (rows.length) pool = rows;
    }
    let best = vertical ? pickInNextRow(from, pool, dir, fromEl) : pickBest(from, list, dir);
    // End of the visible part of a row: rather than stopping on the row's small arrow button, go on to the next
    // hidden card (select() then uses the arrow to bring it into view), like a TV app's rows.
    const isButton = best && (best.el.tagName === 'BUTTON' || best.el.getAttribute('role') === 'button');
    if (!vertical && isButton && !best.hidden) {
      const arrowSmall = best.b.width * best.b.height < from.width * from.height * 0.4;
      const hiddenCards = list.filter(c => c.hidden && c.b.width * c.b.height > from.width * from.height * 0.5);
      const card = arrowSmall && hiddenCards.length ? pickBest(from, hiddenCards, dir) : null;
      if (card) best = card;
    }
    if (best) {
      stuck = 0;
      if (!vertical || anchorX === null || !fromEl) { const b = best.b; anchorX = (b.left + b.right) / 2; }
      select(best.el);
      return;
    }
    // Held in a pop-up with nowhere to go that way, twice in a row: let go of it (a side panel that the site marks
    // as a pop-up must not trap the highlight).
    const pop = !document.fullscreenElement && openPopup();
    if (pop && ++stuck >= 2) { stuck = 0; letGo.add(pop); note('let go of pop-up ' + describe(pop)); move(dir); return; }
    note('nothing ' + dir + ' of ' + (fromEl ? describe(fromEl) : 'start') + ', ' + list.length + ' that way' + (pop ? ', in pop-up ' + describe(pop) : ''));
    // Nothing further that way: scroll the page instead (Up/Down), so more appears. (Not behind a pop-up.)
    if (vertical && !openPopup()) scrollBy({ top: (dir === 'down' ? 1 : -1) * innerHeight * 0.6, behavior: 'smooth' });
  }

  // Left/Right stay in the row: only things level with the current one (overlapping it vertically, or close).
  // At the end of a row nothing happens, as on a TV, instead of jumping diagonally into another row.
  function pickBest(from, list, dir) {
    const fcy = (from.top + from.bottom) / 2;
    const level = c => Math.min(from.bottom, c.b.bottom) - Math.max(from.top, c.b.top) > 0 ||
      Math.abs((c.b.top + c.b.bottom) / 2 - fcy) < Math.max(from.height, 40);
    let best = null, bestScore = Infinity;
    for (const c of list) {
      if (current && !level(c)) continue;
      const s = score(from, c.b, dir);
      if (s < bestScore) { bestScore = s; best = c; }
    }
    if (DEBUG) console.log('[tvnav]', dir, 'list', list.length, 'level', list.filter(level).map(c => c.el.tagName + ':' + (c.el.getAttribute('aria-label') || c.el.textContent || '').trim().slice(0, 16) + '@' + Math.round(c.b.left) + ',' + Math.round(c.b.top)).join(' | '), '->', best && best.el.textContent.trim().slice(0, 20));
    return best;
  }

  function pickInNextRow(from, list, dir, fromEl) {
    if (!list.length) return null;
    const gap = b => Math.max(0, dir === 'down' ? b.top - from.bottom : from.top - b.bottom);
    // Small text links between rows ("See more", row titles, "Join") are stepped over when something bigger
    // follows within a screen, so Down goes row of cards to row of cards. Buttons (chips, tabs) never are.
    const area = from.width * from.height;
    const small = c => c.el.tagName === 'A' && c.b.width * c.b.height < Math.max(area * 0.15, innerWidth * innerHeight * 0.01);
    // Only small links that lie before the next row of bigger things are stepped over; small links in that same
    // row (a menu bar's text tabs next to its icon buttons) stay.
    // Not when OK on the highlighted thing just opened something (a profile menu): then what appeared comes
    // first, before anything that was already there.
    let pool = list;
    // (also while moving within it: the current item is itself one that appeared)
    const inMenu = fromEl && beforeOk && (beforeOk.el === fromEl || !beforeOk.seen.has(fromEl));
    const opened = inMenu ? list.filter(c => !beforeOk.seen.has(c.el)) : [];
    const opener = inMenu && beforeOk.el !== fromEl && list.find(c => c.el === beforeOk.el);
    if (opened.length) pool = opened;
    else if (opener) return opener;                    // past the menu's first item: back to what opened it
    else if (fromEl && area > innerWidth * innerHeight * 0.02) {
      // (only from a card, towards more cards: in menus and side bars every link is a stop)
      const cardSized = c => c.b.width * c.b.height >= area * 0.3;
      const cards = list.filter(cardSized);
      // A card's caption (its title, channel, tags just under it, within its width) belongs to the card: Up and
      // Down step over it, as a TV app treats a tile as one stop. Left/Right can still reach it.
      const under = (c, k) => c.b.top >= k.bottom - 6 && c.b.top - k.bottom < 90 && c.b.left >= k.left - 12 && c.b.right <= k.right + 12;
      const caption = c => !cardSized(c) && (under(c, from) || cards.some(k => under(c, k.b)));
      let p = list.filter(c => !caption(c));
      const big = p.filter(c => cardSized(c) && gap(c.b) < innerHeight * 0.9);
      if (big.length) {
        const bigGap = Math.min(...big.map(c => gap(c.b)));
        p = p.filter(c => !small(c) || gap(c.b) >= bigGap - 12);
      }
      if (p.length) pool = p;
    }
    // Keep to the column: things off to the side (a mute button in a corner, a carousel's edge arrow) only when
    // there is nothing in line.
    const ax0 = anchorX !== null && fromEl ? anchorX : (from.left + from.right) / 2;
    const off = b => ax0 < b.left ? b.left - ax0 : ax0 > b.right ? ax0 - b.right : 0;
    // Straight down/up the column first (a side bar next to the content is its own column); then close to it.
    // Nothing straight below: the nearest thing, counting sideways distance at half (a form in the middle of
    // the page below a logo at the edge is nearer than the footer link under the logo).
    const straight = pool.filter(c => off(c.b) === 0 && gap(c.b) < innerHeight * 0.9);
    if (straight.length) pool = straight;
    else {
      let near = null, cost = Infinity;
      for (const c of pool) { const k = gap(c.b) + off(c.b) * 0.5; if (k < cost) { cost = k; near = c; } }
      if (DEBUG) console.log('[tvnav]', dir, 'nothing straight, nearest', near && near.el.tagName);
      return near;
    }
    // The next row: everything starting about as close as the nearest thing.
    let nearest = pool[0];
    for (const c of pool) if (gap(c.b) < gap(nearest.b)) nearest = c;
    const reach = gap(nearest.b) + Math.max(24, nearest.b.height * 0.5);
    const row = pool.filter(c => gap(c.b) <= reach);
    // In that row: the one under (or closest to) the remembered column.
    const ax = anchorX !== null && fromEl ? anchorX : (from.left + from.right) / 2;
    const away = b => ax < b.left ? b.left - ax : ax > b.right ? ax - b.right : 0;
    let best = row[0];
    for (const c of row) {
      const d = away(c.b) - away(best.b);
      if (d < 0 || (d === 0 && gap(c.b) < gap(best.b))) best = c;
    }
    if (DEBUG) console.log('[tvnav]', dir, 'list', list.length, 'pool', pool.length, 'row', row.map(c => c.el.tagName + ':' + (c.el.textContent || '').trim().slice(0, 20) + '@' + Math.round(c.b.left) + ',' + Math.round(c.b.top) + ' ' + Math.round(c.b.width) + 'x' + Math.round(c.b.height)).join(' | '));
    return best;
  }

  // In a bar fixed to the screen (a site's header)?
  function pinned(el) {
    for (let p = el, i = 0; p && p !== document.body && i < 15; p = p.parentElement, i++) {
      const pos = getComputedStyle(p).position;
      if (pos === 'fixed' || pos === 'sticky') return true;
    }
    return false;
  }

  function insideScroller(el) {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const cs = getComputedStyle(p);
      if (/(auto|scroll)/.test(cs.overflowX + cs.overflowY)) return true;
    }
    return false;
  }

  let lastBox = null;
  function select(el) {
    current = el;
    lastBox = el.getBoundingClientRect();
    usingKeys = true;
    try {
      if (!el.matches('a[href], button, input, select, textarea, [tabindex]')) el.setAttribute('tabindex', '-1');
      el.focus({ preventScroll: true });
    } catch (e) { /* some elements refuse focus; the highlight still works */ }
    const b = el.getBoundingClientRect();
    const v = visibleBox(el);
    const clipped = v.width < b.width * 0.9;
    // (Never in full screen: scrolling YouTube's player there slides its "more videos" grid up over the video.)
    if (document.fullscreenElement) { drawRing(); return; }
    if (clipped || b.top < 60 || b.bottom > innerHeight - 40 || b.left < 0 || b.right > innerWidth) {
      el.scrollIntoView({ block: 'center', inline: clipped ? 'center' : 'nearest', behavior: 'smooth' });
    }
    if (clipped) setTimeout(() => revealInCarousel(el), 450);
    drawRing();
  }

  // How many pages a row has been moved on (by revealInCarousel), so Left never wraps past its start.
  const rowPages = new WeakMap();
  function rowKey(el) { return el.closest('.carousel-row, .lolomoRow, .rowContainer, [data-list-context], .slider') || el.parentElement; }

  /* A carousel that moves its cards itself (no scrolling): press its own next/previous arrow until the card shows. */
  function revealInCarousel(el, tries = 0) {
    if (current !== el || tries > 6) return;
    const b = el.getBoundingClientRect(), v = visibleBox(el);
    if (v.width >= b.width * 0.9) { drawRing(); return; }
    const right = b.left > (v.left + v.right) / 2 || v.width < 8 && b.left >= v.right;
    const words = right ? /next|right|forward|more|scroll right|weiter/i : /prev|left|back|scroll left/i;
    let row = el.parentElement;
    for (let i = 0; row && i < 8; row = row.parentElement, i++) {
      const btn = [...row.querySelectorAll('button, [role=button]')].find(x =>
        words.test((x.getAttribute('aria-label') || '') + ' ' + (x.title || '') + ' ' + x.className) && !x.contains(el));
      // (or an unlabelled arrow: a narrow clickable strip at that edge of the row, as Netflix has)
      const strip = btn ? null : [...row.querySelectorAll('div, span')].find(x => {
        if (x.contains(el) || getComputedStyle(x).cursor !== 'pointer' || x.querySelector('img')) return false;
        const r = x.getBoundingClientRect(), rb = row.getBoundingClientRect();
        return r.width < 90 && r.height > 60 && (right ? r.right >= Math.min(rb.right, innerWidth) - 8 : r.left <= Math.max(rb.left, 0) + 8);
      });
      if (btn || strip) {
        press(btn || strip);
        const key = rowKey(el);
        rowPages.set(key, (rowPages.get(key) || 0) + (right ? 1 : -1));
        setTimeout(() => revealInCarousel(el, tries + 1), 500);
        return;
      }
    }
  }

  /* OK: a real click at the highlight, like tapping the touchpad there. Some sites only respond to real clicks
     (Prime Video's cards and profile menu). helper\tvnav-host.ps1 provides window.tvnavClick and sends the click
     into the page (the real pointer does not move). Without it: a made-up click. */
  let ignoreMouseUntil = 0;
  let beforeOk = null;          // what could be selected when OK was pressed, to spot a menu it opens
  function okPress(el) {
    if (ROW_STOPS && el.matches(ROW_STOPS)) {
      const play = el.querySelector('button[aria-label^="Play" i], button[aria-label^="Pause" i]');
      if (play) { press(play); return; }
    }
    beforeOk = { el, seen: new Set(candidates()) };
    setTimeout(() => followAfterOk(el), 450);
    const v = visibleBox(el);
    const l = Math.max(v.left, 0), r = Math.min(v.right, innerWidth), t = Math.max(v.top, 0), btm = Math.min(v.bottom, innerHeight);
    covered(el, el.getBoundingClientRect());               // finds the point where it is on top
    const pt = clickPoints.get(el) || { fx: 0.5, fy: 0.5 };
    const x = l + (r - l) * pt.fx, y = t + (btm - t) * pt.fy;
    const hit = document.elementFromPoint(x, y);
    // Only when the highlighted thing really is what lies under that point (otherwise the click would land on
    // whatever covers it).
    const real = typeof window.tvnavClick === 'function' && el.tagName !== 'SELECT' &&
      !!hit && (hit === el || el.contains(hit));
    if (!real) { press(el); return; }
    ignoreMouseUntil = performance.now() + 1500;          // the click's own pointer movement
    window.tvnavClick(JSON.stringify({ x, y }));
    setTimeout(parkPointer, 300);
  }

  // OK replaced what was highlighted with something new (a sub-menu, the next step of a form): the highlight
  // goes to the nearest new item, as on a TV, instead of being left on nothing.
  function followAfterOk(el, tries = 0) {
    // (a copy of el counts: Netflix rebuilds the cards behind the panel it opens)
    const same = x => x === el || (x && x.getAttribute && el.getAttribute('href') && x.getAttribute('href') === el.getAttribute('href'));
    relocate();
    if (!same(current) || !beforeOk || !same(beforeOk.el)) return;
    el = current;
    // OK opened a pop-up (Netflix's film panel): into it, on its Play / Resume button if it has one.
    const pop = !document.fullscreenElement && openPopup();
    if (pop && !pop.contains(el)) {
      const inPop = candidates().filter(c => pop.contains(c));
      const name = c => ((c.getAttribute('aria-label') || '') + ' ' + c.textContent).trim();
      const play = inPop.find(c => /^(play|resume|watch)\b/i.test(name(c)));
      if (!play && tries < 4) { setTimeout(() => followAfterOk(el, tries + 1), 350); return; }   // still sliding in
      const pick = play ||
        inPop.slice().sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0];
      if (pick) { beforeOk = { el: pick, seen: beforeOk.seen }; anchorX = null; select(pick); return; }
    }
    const b = el.isConnected ? el.getBoundingClientRect() : null;
    if (b && b.width > 1 && b.height > 1 && el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return;
    const from = lastBox || { left: 0, top: 0, right: 0, bottom: 0 };
    const fx = (from.left + from.right) / 2, fy = (from.top + from.bottom) / 2;
    let best = null, dist = Infinity;
    // In a full-screen player only into a menu (YouTube's settings and their sub-menus); after choosing in one
    // (a quality), back to watching, as on a TV.
    const fsMenu = c => !document.fullscreenElement || /^(menuitem|menuitemradio|menuitemcheckbox|option|radio)$/.test(c.getAttribute('role') || '');
    for (const c of candidates()) {
      if (beforeOk.seen.has(c) || !fsMenu(c)) continue;
      const r = c.getBoundingClientRect();
      const d = Math.hypot((r.left + r.right) / 2 - fx, (r.top + r.bottom) / 2 - fy);
      if (d < dist) { dist = d; best = c; }
    }
    if (best) { beforeOk = { el: best, seen: beforeOk.seen }; select(best); }
    else if (document.fullscreenElement) hideControls();
  }

  function press(el) {
    const b = el.getBoundingClientRect();
    const x = b.left + b.width / 2, y = b.top + b.height / 2;
    const opts = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, view: window };
    // Full pointer sequence: some sites (React, YouTube) only react to pointer/mouse down and up, not click().
    el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerType: 'mouse', isPrimary: true }, opts)));
    el.dispatchEvent(new MouseEvent('mousedown', opts));
    el.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerType: 'mouse', isPrimary: true }, opts)));
    el.dispatchEvent(new MouseEvent('mouseup', opts));
    el.click();
  }

  /* ---------- video ---------- */
  /* "Watching": a big video (not a small preview) that you started: it began playing soon after you pressed OK
     (also across the page change OK caused), or it is full screen. Trailers that start by themselves (Prime
     Video's and Netflix's banners) do not count, so they never take over the arrows. */
  const BIG = 0.25;
  const OK_KEY = 'tvnav-ok-at';
  const userVideos = new WeakSet();
  let autoFsDoneFor = null, fullscreenByOk = false;
  // OK counts as starting a video when it opened another page (a film's player) or was pressed on something to
  // play ("Play", "Watch", an episode, the video itself), not on a menu or logo of a page with a trailer.
  function okRecently() {
    let ok = null;
    try { ok = JSON.parse(sessionStorage.getItem(OK_KEY) || 'null'); } catch (e) { /* storage blocked */ }
    if (!ok || typeof ok !== 'object' || Date.now() - ok.t >= 12000) return false;
    return ok.play || ok.href !== location.href;
  }
  const PLAYISH = /\b(play|watch|resume|continue|start|episode|ep\s?\d|live|stream|trailer)/i;
  function playish(el) {
    if (!el || !el.isConnected) return true;
    if (el.tagName === 'VIDEO' || el.querySelector('video')) return true;
    const text = (el.getAttribute('aria-label') || '') + ' ' + (el.title || '') + ' ' + (el.textContent || '').slice(0, 200);
    return PLAYISH.test(text);
  }
  function noteOk(el) {
    try { sessionStorage.setItem(OK_KEY, JSON.stringify({ t: Date.now(), href: location.href, play: playish(el) })); } catch (e) { /* storage blocked */ }
  }
  function share(v) { const b = v.getBoundingClientRect(); return (b.width * b.height) / (innerWidth * innerHeight); }
  const yours = v => userVideos.has(v) || (document.fullscreenElement && document.fullscreenElement.contains(v));
  function bigPlayingVideo() {
    for (const v of document.querySelectorAll('video')) {
      if (v.paused || v.ended || v.readyState < 2) continue;
      if (share(v) > BIG && yours(v)) return v;
    }
    return null;
  }
  function bigVideo() {
    for (const v of document.querySelectorAll('video')) {
      if (v.readyState >= 1 && share(v) > BIG && yours(v)) return v;
    }
    return null;
  }
  /* Full screen the way the site's own button does it (YouTube's and Twitch's players lay themselves out for it),
     else the player box itself. Browsers only allow full screen from a real key press or click, which a video
     starting a moment after OK no longer counts as, so helper	vnav-host.ps1 runs it as a user action
     (window.tvnavGesture). */
  const FS_BUTTONS = '.ytp-fullscreen-button, [data-a-target="player-fullscreen-button"], ' +
    'button[aria-label*="full screen" i], button[aria-label*="fullscreen" i], button[title*="full screen" i], button[title*="fullscreen" i]';
  function playerOf(v) {
    return v.closest('#movie_player, .html5-video-player, [data-a-target="video-player"], [class*="player" i], [id*="player" i]') || v.parentElement || v;
  }
  // In full screen: the player of the biggest video inside it, else the full-screen element itself.
  function fullscreenPlayer() {
    const fs = document.fullscreenElement;
    let big = null, area = 0;
    for (const v of fs.querySelectorAll('video')) {
      const r = v.getBoundingClientRect();
      if (r.width * r.height > area) { area = r.width * r.height; big = v; }
    }
    const pl = big && playerOf(big);
    return pl && fs.contains(pl) ? pl : fs;
  }
  function goFullscreen(v) {
    if (document.fullscreenElement) return;
    const player = playerOf(v);
    const scope = player.parentElement || document;
    const btn = [...scope.querySelectorAll(FS_BUTTONS)].find(b => !/exit/i.test((b.getAttribute('aria-label') || '') + (b.title || '')));
    window.__tvnavGesture = () => {
      if (document.fullscreenElement) return;
      if (btn && btn.isConnected) btn.click();
      else if (player.requestFullscreen) player.requestFullscreen().catch(() => {});
    };
    if (typeof window.tvnavGesture !== 'function') { window.__tvnavGesture(); return; }
    // First the player's own full-screen key (F on YouTube, Twitch, Netflix, Prime Video, Disney+), pressed for
    // real, so the player switches to its own full-screen layout; if nothing happens, its button.
    if (!isTextBox(document.activeElement)) { try { document.activeElement.blur(); } catch (e) { /* ignore */ } }
    window.tvnavGesture('key:f');
    setTimeout(() => { if (!document.fullscreenElement) window.tvnavGesture('fullscreen'); }, 900);
  }
  // OK while watching: full screen if it is not yet, otherwise pause / play.
  function okOnVideo(v) {
    if (!document.fullscreenElement && share(v) < 0.85) { goFullscreen(v); return; }
    if (v.paused) v.play().catch(() => {}); else v.pause();
  }

  /* Full screen: Up/Down show the player's controls with the highlight on them (bottom row first), so settings
     such as quality are reachable. The controls are kept showing while the highlight is on them. */
  // Players only show their controls for real pointer movement, so the companion moves the page's pointer a
  // little over the player (the real pointer stays where it is). Without it: a made-up movement.
  let jiggle = 0;
  function showControls() {
    const fs = document.fullscreenElement;
    if (!fs) return;
    // Onto the highlighted control (moving away from an open menu closes it on Twitch), else the middle.
    const onCtl = current && current.isConnected && fs.contains(current);
    const b = (onCtl ? current : fullscreenPlayer()).getBoundingClientRect();
    const x = b.left + b.width / 2 + (jiggle = 1 - jiggle) * 2;
    const y = onCtl ? b.top + b.height / 2 : b.top + Math.min(b.height, innerHeight) * 0.55;
    ignoreMouseUntil = performance.now() + 800;
    if (typeof window.tvnavClick === 'function') { window.tvnavClick(JSON.stringify({ x, y, move: true })); return; }
    const opts = { bubbles: true, clientX: x, clientY: y, view: window };
    (document.elementFromPoint(x, y) || fs).dispatchEvent(new MouseEvent('mousemove', opts));
  }
  setInterval(() => { if (usingKeys && document.fullscreenElement) showControls(); }, 1500);
  // Bottom control row, leftmost first (Play), once the controls have faded in.
  function controlsFromBottom(tries = 0) {
    showControls();
    current = null;
    setTimeout(() => {
      const bar = candidates().map(el => ({ el, b: el.getBoundingClientRect() }))
        .filter(c => c.b.top > innerHeight * 0.6 && c.b.bottom <= innerHeight + 2);
      if (!bar.length && tries < 3) { controlsFromBottom(tries + 1); return; }
      if (!bar.length) { move('up'); return; }
      // The lowest row with several buttons (the control bar), not a lone button under it (DStv's "Channel Lineup").
      const rows = [];
      for (const c of bar.sort((x, y) => y.b.bottom - x.b.bottom)) {
        const r = rows.find(r => Math.abs(r[0].b.bottom - c.b.bottom) < 24);
        if (r) r.push(c); else rows.push([c]);
      }
      const row = (rows.find(r => r.length >= 3) || rows[0]).sort((a, b) => a.b.left - b.b.left);
      anchorX = null;
      select(row[0].el);
    }, 300);
  }
  // Back to watching: highlight off, and the video back in its place (a scrolled full-screen player is YouTube's
  // "more videos" grid, with the video squeezed to the top).
  function hideControls() {
    usingKeys = false; current = null; drawRing();
    unscrollPlayer();
  }
  function unscrollPlayer() {
    const fs = document.fullscreenElement;
    if (!fs) return;
    for (let p = fullscreenPlayer(); p; p = p.parentElement) {
      if (p.scrollTop) p.scrollTop = 0;
      if (p === fs) break;
    }
  }
  // The highlight lives in the page; in full screen only the full-screen part is drawn, so it moves in there.
  document.addEventListener('fullscreenchange', () => {
    const r = ensureRing();
    (document.fullscreenElement || document.body || document.documentElement).appendChild(r);
    if (!document.fullscreenElement) { usingKeys = false; drawRing(); }
  });

  /* ---------- keys ---------- */
  const DIRS = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };

  window.addEventListener('keydown', e => {
    if (e.ctrlKey || e.altKey || e.metaKey) return;
    if (e.key === 'MediaPlayPause' || e.key === 'MediaPlay') { noteOk(null); return; }   // started by you, too
    const active = document.activeElement;
    const typing = isTextBox(active);
    const dir = DIRS[e.key];

    if (e.key === 'Backspace') {
      if (typing) return;                               // delete a character, as usual
      e.preventDefault(); e.stopPropagation();
      if (e.repeat) return;                             // held: tv.ahk takes it home
      if (document.fullscreenElement) {
        // On the controls: hide them (back to watching). Watching: leave the video, back to where you came from.
        if (usingKeys) { hideControls(); return; }
        document.exitFullscreen().catch(() => {});
        if (fullscreenByOk && history.length > 1) history.back();
        fullscreenByOk = false;
        return;
      }
      if (history.length > 1) history.back();
      return;
    }

    if (dir) {
      if (typing && (dir === 'left' || dir === 'right')) return;     // move the caret
      if (nativePlayer() && !usingKeys && (dir === 'left' || dir === 'right')) return;   // Netflix seeks itself
      const watching = !usingKeys && (bigPlayingVideo() || (document.fullscreenElement && bigVideo()));
      // (not on live streams, which have no length to skip through)
      if (watching && isFinite(watching.duration) && (dir === 'left' || dir === 'right')) {
        e.preventDefault(); e.stopPropagation();
        unscrollPlayer();
        watching.currentTime = Math.max(0, watching.currentTime + (dir === 'right' ? SEEK_SECONDS : -SEEK_SECONDS));
        return;
      }
      if (document.fullscreenElement && !usingKeys) {
        unscrollPlayer();
        // Full screen: Up/Down (or Left/Right on a live stream) bring up the player's controls.
        e.preventDefault(); e.stopPropagation();
        controlsFromBottom();
        return;
      }
      e.preventDefault(); e.stopPropagation();
      if (typing) active.blur();
      parkPointer();
      move(dir);
      return;
    }

    if (e.key === 'Enter' || e.key === 'NumpadEnter') {
      noteOk(typing ? active : current && current.isConnected && usingKeys ? current : null);
      if (typing) { usingKeys = false; drawRing(); return; }        // submit the search box etc. as usual
      if (current && current.isConnected && usingKeys) {
        e.preventDefault(); e.stopPropagation();
        okPress(current);
        return;
      }
      const v = bigVideo();
      if (v && nativePlayer() && (document.fullscreenElement || share(v) >= 0.85)) return;   // Netflix pauses itself
      if (v) {
        e.preventDefault(); e.stopPropagation();
        okOnVideo(v);
      }
    }
  }, true);

  // Touchpad: real pointer movement hides the highlight (the pointer is in charge again).
  let lx = null, ly = null;
  window.addEventListener('mousemove', e => {
    const moved = lx !== null && (e.screenX !== lx || e.screenY !== ly);
    lx = e.screenX; ly = e.screenY;
    if (performance.now() < ignoreMouseUntil) return;     // our own click moved it
    if (moved && usingKeys) { usingKeys = false; anchorX = null; drawRing(); }
  }, true);

  // When a big video you started begins, the highlight steps aside so Left/Right seek; Up/Down bring it back.
  const seenStart = new WeakSet();
  document.addEventListener('play', e => { if (e.target instanceof HTMLVideoElement) videoStarted(e.target); }, true);
  // (Netflix starts its video before adding it to the page, so that start never reaches this page: look too.)
  setInterval(() => {
    for (const v of document.querySelectorAll('video')) if (!v.paused && !seenStart.has(v)) videoStarted(v);
  }, 1000);
  document.addEventListener('pause', e => { if (e.target instanceof HTMLVideoElement) seenStart.delete(e.target); }, true);
  function videoStarted(v) {
    seenStart.add(v);
    if (NETFLIX && !nativePlayer()) return;          // trailers in Netflix's panels are never "yours"
    if (okRecently() || (document.fullscreenElement && document.fullscreenElement.contains(v))) userVideos.add(v);
    if (userVideos.has(v)) startedBig(v, okRecently(), 0);
  }
  // (The player may still be growing to its full size when the video starts, as Netflix's does: look again.)
  function startedBig(v, byOk, tries) {
    if (v.paused) return;
    if (share(v) <= BIG) { if (tries < 12) setTimeout(() => startedBig(v, byOk, tries + 1), 500); return; }
    {
      usingKeys = false; drawRing();
      // Opened with OK: straight to full screen, as a TV app plays a video (once per page, so leaving full
      // screen yourself sticks).
      if (byOk && !document.fullscreenElement && autoFsDoneFor !== location.href) {
        autoFsDoneFor = location.href;
        fullscreenByOk = true;
        setTimeout(() => { if (!v.paused) goFullscreen(v); }, 400);
      }
    }
  }
})();
