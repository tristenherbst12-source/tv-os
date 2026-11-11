/* Spotify in the TV window: tells the home screen what is playing (song, artist, cover, playing or paused).
   (Added to every page by helper\tvnav-host.ps1; does nothing on other sites.) Spotify publishes the song for the
   system's media controls (navigator.mediaSession); this passes it on through window.tvnavNowPlaying, which
   tvnav-host.ps1 writes to a file the helper serves to the home screen. */
(function () {
  'use strict';
  if (window.top !== window || location.hostname !== 'open.spotify.com') return;
  if (window.__tvnavSpotify) return;
  Object.defineProperty(window, '__tvnavSpotify', { value: true });

  let last = '', lastSent = 0;
  function report() {
    if (typeof window.tvnavNowPlaying !== 'function') return;
    const ms = navigator.mediaSession;
    const m = ms && ms.metadata;
    let info = { title: '', artist: '', art: '', playing: false };
    if (m && m.title) {
      const art = (m.artwork || []).slice().sort((a, b) => parseInt(b.sizes) - parseInt(a.sizes))[0];
      const media = [...document.querySelectorAll('audio, video')];
      info = {
        title: m.title, artist: m.artist || '', art: art ? art.src : '',
        playing: ms.playbackState === 'playing' || media.some(e => !e.paused)
      };
    }
    const text = JSON.stringify(info);
    // Sent when it changes, and every 10 s so the home screen knows the window is still there.
    if (text === last && Date.now() - lastSent < 10000) return;
    last = text; lastSent = Date.now();
    window.tvnavNowPlaying(JSON.stringify(Object.assign({ at: Date.now() }, info)));
  }
  setInterval(report, 2000);
})();
