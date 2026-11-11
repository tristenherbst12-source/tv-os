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
  function drawRing() {
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

  function candidates() {
    const vh = innerHeight, vw = innerWidth;
    const out = [];
    const seen = new Set();
    for (const el of document.querySelectorAll(CLICKABLE)) {
      if (seen.has(el) || el === ring) continue;
      seen.add(el);
      // (aria-hidden is not a reason to skip: sites hide duplicate links such as video thumbnails from screen
      // readers, and those are exactly what a TV remote should land on.)
      if (el.disabled) continue;
      const b = el.getBoundingClientRect();
      if (b.width < 12 || b.height < 12) continue;
      // Whole rows or panels made focusable (Spotify does this) are containers, not things to press.
      if (b.width > vw * 1.1 || b.width * b.height > vw * vh * 0.6) continue;
      if (b.bottom < -vh * 1.5 || b.top > vh * 2.5 || b.right < -vw || b.left > vw * 2) continue;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
      if (!paints(el) || covered(el, b)) continue;
      out.push(el);
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

  // The front-most open pop-up: a dialog (or a box marked modal) that is showing and of a real size.
  function openPopup() {
    const found = [...document.querySelectorAll('dialog[open], [aria-modal="true"], [role="dialog"], [role="alertdialog"]')]
      .filter(d => {
        const b = d.getBoundingClientRect();
        return b.width > 120 && b.height > 80 && b.bottom > 0 && b.top < innerHeight &&
          d.checkVisibility({ opacityProperty: true, visibilityProperty: true });
      });
    return found.length ? found[found.length - 1] : null;      // the last one in the page is usually on top
  }

  // The tile a small link sits in, if any: a box up to 5 levels up with a pointer cursor and a picture, clearly
  // bigger than the link (3x) but not a whole panel.
  const tileCache = new WeakMap();
  function tileAround(el) {
    if (tileCache.has(el)) return tileCache.get(el);
    let found = null;
    const a = el.getBoundingClientRect(), area = a.width * a.height;
    if (/^(A|BUTTON)$/.test(el.tagName) || el.getAttribute('role')) {
      let p = el.parentElement;
      for (let i = 0; p && i < 5 && p !== document.body; i++, p = p.parentElement) {
        const b = p.getBoundingClientRect(), pa = b.width * b.height;
        if (pa > innerWidth * innerHeight * 0.3 || b.width > innerWidth * 0.6) break;
        if (pa >= area * 3 && getComputedStyle(p).cursor === 'pointer' &&
            p.querySelector('img, picture, canvas, video, [style*="background-image"]')) { found = p; }
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
  function covered(el, b) {
    const x = b.left + b.width / 2, y = b.top + b.height / 2;
    if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return false;   // off screen: cannot tell
    const hit = document.elementFromPoint(x, y);
    if (!hit || hit === el || el.contains(hit) || hit === ring) return false;
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
      return u.origin + u.pathname + (u.searchParams.get('v') ? '?v=' + u.searchParams.get('v') : '');
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
      if (score(from, box, dir) === Infinity) continue;
      list.push({ el, b: box, hidden: box === v.full });
    }
    let best = vertical ? pickInNextRow(from, list, dir, fromEl) : pickBest(from, list, dir);
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
      if (!vertical || anchorX === null || !fromEl) { const b = best.b; anchorX = (b.left + b.right) / 2; }
      select(best.el);
      return;
    }
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
    if (clipped || b.top < 60 || b.bottom > innerHeight - 40 || b.left < 0 || b.right > innerWidth) {
      el.scrollIntoView({ block: 'center', inline: clipped ? 'center' : 'nearest', behavior: 'smooth' });
    }
    if (clipped) setTimeout(() => revealInCarousel(el), 450);
    drawRing();
  }

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
      if (btn) {
        press(btn);
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
    beforeOk = { el, seen: new Set(candidates()) };
    const v = visibleBox(el);
    const x = (Math.max(v.left, 0) + Math.min(v.right, innerWidth)) / 2;
    const y = (Math.max(v.top, 0) + Math.min(v.bottom, innerHeight)) / 2;
    const hit = document.elementFromPoint(x, y);
    // Only when the highlighted thing really is what lies under that point (otherwise the click would land on
    // whatever covers it).
    const real = typeof window.tvnavClick === 'function' && el.tagName !== 'SELECT' &&
      !!hit && (hit === el || el.contains(hit));
    if (!real) { press(el); return; }
    ignoreMouseUntil = performance.now() + 1500;          // the click's own pointer movement
    window.tvnavClick(JSON.stringify({ x, y }));
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
  function okRecently() {
    let t = 0;
    try { t = Number(sessionStorage.getItem(OK_KEY)) || 0; } catch (e) { /* storage blocked */ }
    return Date.now() - t < 12000;
  }
  function noteOk() { try { sessionStorage.setItem(OK_KEY, String(Date.now())); } catch (e) { /* storage blocked */ } }
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
  // OK while watching: full screen if the video does not fill the window yet, otherwise pause / play.
  function okOnVideo(v) {
    if (!document.fullscreenElement && share(v) < 0.85) {
      const player = v.closest('#movie_player, [class*="player" i], [id*="player" i]') || v.parentElement || v;
      (player.requestFullscreen ? player.requestFullscreen() : Promise.reject()).catch(() => { if (v.paused) v.play(); else v.pause(); });
      return;
    }
    if (v.paused) v.play().catch(() => {}); else v.pause();
  }

  /* ---------- keys ---------- */
  const DIRS = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };

  window.addEventListener('keydown', e => {
    if (e.ctrlKey || e.altKey || e.metaKey) return;
    if (e.key === 'MediaPlayPause' || e.key === 'MediaPlay') { noteOk(); return; }   // started by you, too
    const active = document.activeElement;
    const typing = isTextBox(active);
    const dir = DIRS[e.key];

    if (e.key === 'Backspace') {
      if (typing) return;                               // delete a character, as usual
      e.preventDefault(); e.stopPropagation();
      if (e.repeat) return;                             // held: tv.ahk takes it home
      if (document.fullscreenElement) { document.exitFullscreen().catch(() => {}); return; }
      if (history.length > 1) history.back();
      return;
    }

    if (dir) {
      if (typing && (dir === 'left' || dir === 'right')) return;     // move the caret
      const watching = !usingKeys && (bigPlayingVideo() || (document.fullscreenElement && bigVideo()));
      // (not on live streams, which have no length to skip through)
      if (watching && isFinite(watching.duration) && (dir === 'left' || dir === 'right')) {
        e.preventDefault(); e.stopPropagation();
        watching.currentTime = Math.max(0, watching.currentTime + (dir === 'right' ? SEEK_SECONDS : -SEEK_SECONDS));
        return;
      }
      if (watching && document.fullscreenElement) {
        // Full screen: Up/Down leave it first, so the highlight has the page to move around in.
        document.exitFullscreen().catch(() => {});
      }
      e.preventDefault(); e.stopPropagation();
      if (typing) active.blur();
      move(dir);
      return;
    }

    if (e.key === 'Enter' || e.key === 'NumpadEnter') {
      noteOk();
      if (typing) { usingKeys = false; drawRing(); return; }        // submit the search box etc. as usual
      if (current && current.isConnected && usingKeys) {
        e.preventDefault(); e.stopPropagation();
        okPress(current);
        return;
      }
      const v = bigVideo();
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
  document.addEventListener('play', e => {
    const v = e.target;
    if (!(v instanceof HTMLVideoElement)) return;
    if (okRecently() || (document.fullscreenElement && document.fullscreenElement.contains(v))) userVideos.add(v);
    if (share(v) > BIG && userVideos.has(v)) { usingKeys = false; drawRing(); }
  }, true);
})();
