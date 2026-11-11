/* TV remote navigation for ordinary websites (loaded into every TV window by the helper).

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

  const CLICKABLE = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [contenteditable=""], ' +
    '[contenteditable=true], [role=button], [role=link], [role=tab], [role=menuitem], [role=option], [role=checkbox], ' +
    '[role=switch], [role=radio], [role=slider], [tabindex]:not([tabindex="-1"]), [onclick]';
  const SEEK_SECONDS = 10;
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
      out.push(el);
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
    // Links to the same page sitting next to each other (a video's thumbnail and its title) are one stop: keep
    // the biggest. Far-apart links to the same page (e.g. in a menu and in the content) stay separate.
    const byHref = new Map();
    const result = [];
    for (const el of nested) {
      const href = el.tagName === 'A' && el.href && linkKey(el);
      if (!href) { result.push(el); continue; }
      const b = el.getBoundingClientRect();
      const group = byHref.get(href) || [];
      const near = group.find(g => Math.hypot((g.b.left + g.b.right - b.left - b.right) / 2, (g.b.top + g.b.bottom - b.top - b.bottom) / 2) < Math.max(600, innerWidth * 0.45));
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

  function move(dir) {
    const fromEl = current && current.isConnected ? current : null;
    const from = fromEl ? fromEl.getBoundingClientRect() : startBox(dir);
    let best = null, bestScore = Infinity;
    for (const el of candidates()) {
      if (el === fromEl) continue;
      if (fromEl && (fromEl.contains(el) || el.contains(fromEl))) continue;
      const v = visibleBox(el);
      // Hidden inside a clipped area (e.g. a carousel page that is not showing) and not scrollable into view.
      if ((v.width < 8 || v.height < 8) && !insideScroller(el)) continue;
      const s = score(from, v.width >= 8 && v.height >= 8 ? v : v.full, dir);
      if (s < bestScore) { bestScore = s; best = el; }
    }
    if (best) { select(best); return; }
    // Nothing further that way: scroll the page instead (Up/Down), so more appears.
    if (dir === 'down' || dir === 'up') scrollBy({ top: (dir === 'down' ? 1 : -1) * innerHeight * 0.6, behavior: 'smooth' });
  }

  function insideScroller(el) {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const cs = getComputedStyle(p);
      if (/(auto|scroll)/.test(cs.overflowX + cs.overflowY)) return true;
    }
    return false;
  }

  function select(el) {
    current = el;
    usingKeys = true;
    try {
      if (!el.matches('a[href], button, input, select, textarea, [tabindex]')) el.setAttribute('tabindex', '-1');
      el.focus({ preventScroll: true });
    } catch (e) { /* some elements refuse focus; the highlight still works */ }
    const b = el.getBoundingClientRect();
    if (b.top < 60 || b.bottom > innerHeight - 40 || b.left < 0 || b.right > innerWidth) {
      el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
    }
    drawRing();
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
  // "Watching": a video that is a main part of the page (not a small preview) and is playing or paused mid-way.
  const BIG = 0.25;
  function share(v) { const b = v.getBoundingClientRect(); return (b.width * b.height) / (innerWidth * innerHeight); }
  function bigPlayingVideo() {
    for (const v of document.querySelectorAll('video')) {
      if (v.paused || v.ended || v.readyState < 2) continue;
      if (share(v) > BIG) return v;
    }
    return null;
  }
  function bigVideo() {
    for (const v of document.querySelectorAll('video')) {
      if (v.readyState >= 1 && share(v) > BIG) return v;
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
      if (watching && (dir === 'left' || dir === 'right')) {
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
      if (typing) { usingKeys = false; drawRing(); return; }        // submit the search box etc. as usual
      if (current && current.isConnected && usingKeys) {
        e.preventDefault(); e.stopPropagation();
        press(current);
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
    if (moved && usingKeys) { usingKeys = false; drawRing(); }
  }, true);

  // When a big video starts, the highlight steps aside so Left/Right seek; Up/Down bring it back.
  document.addEventListener('play', e => {
    const v = e.target;
    if (!(v instanceof HTMLVideoElement)) return;
    if (share(v) > BIG) { usingKeys = false; drawRing(); }
  }, true);
})();
