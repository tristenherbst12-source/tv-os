// Report VP8/VP9/AV1 as unsupported so the player falls back to H.264 (hardware-decoded on Haswell).
(function () {
  const blocked = /vp0?[89]|vp09|av01|av1/i;

  if (window.MediaSource && MediaSource.isTypeSupported) {
    const orig = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = type => blocked.test(type || '') ? false : orig(type);
  }
  if (window.ManagedMediaSource && ManagedMediaSource.isTypeSupported) {
    const orig = ManagedMediaSource.isTypeSupported.bind(ManagedMediaSource);
    ManagedMediaSource.isTypeSupported = type => blocked.test(type || '') ? false : orig(type);
  }
  if (window.HTMLMediaElement) {
    const orig = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (type) { return blocked.test(type || '') ? '' : orig.call(this, type); };
  }
  if (navigator.mediaCapabilities && navigator.mediaCapabilities.decodingInfo) {
    const orig = navigator.mediaCapabilities.decodingInfo.bind(navigator.mediaCapabilities);
    navigator.mediaCapabilities.decodingInfo = cfg => {
      const ct = cfg && cfg.video && cfg.video.contentType;
      if (ct && blocked.test(ct)) return Promise.resolve({ supported: false, smooth: false, powerEfficient: false });
      return orig(cfg);
    };
  }
})();
