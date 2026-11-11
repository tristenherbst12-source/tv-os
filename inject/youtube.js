/* YouTube in the TV window: play at 1080p, or the best below it. (Added to every page by helper\tvnav-host.ps1;
   does nothing on other sites.) 1080p H.264 is what the Haswell graphics decode smoothly, and YouTube's own
   "Auto" often starts lower on a big screen. Changing it by hand from the player's gear menu still works; this only
   sets it once per video. */
(function () {
  'use strict';
  if (window.top !== window || !/(^|\.)youtube\.com$/.test(location.hostname)) return;
  if (window.__tvnavYouTube) return;
  Object.defineProperty(window, '__tvnavYouTube', { value: true });

  const WANT = ['hd1080', 'hd720', 'large', 'medium'];     // best first, never above 1080p
  const tries = new Map();                                 // video id -> attempts

  function apply() {
    const p = document.getElementById('movie_player');
    if (!p || typeof p.getAvailableQualityLevels !== 'function') return;
    if (p.classList.contains('ad-showing')) return;       // adverts have their own qualities
    const data = typeof p.getVideoData === 'function' ? p.getVideoData() : null;
    const id = data && data.video_id;
    if (!id) return;
    const levels = p.getAvailableQualityLevels() || [];
    const q = WANT.find(l => levels.includes(l));
    if (!q) return;
    const n = tries.get(id) || 0;
    if (n >= 3 || (typeof p.getPlaybackQuality === 'function' && p.getPlaybackQuality() === q)) { tries.set(id, 3); return; }
    tries.set(id, n + 1);
    if (typeof p.setPlaybackQualityRange === 'function') p.setPlaybackQualityRange(q, q);
    if (typeof p.setPlaybackQuality === 'function') p.setPlaybackQuality(q);
  }
  setInterval(apply, 2000);
})();
