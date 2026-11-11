/* Network speed test against Cloudflare's public speed-test service (the same one speed.cloudflare.com uses).
   TV.speedTest.run(onProgress, signal) -> { pingMs, downMbps, upMbps }
   onProgress({ phase: 'ping'|'download'|'upload', mbps?, pingMs? }) is called as numbers come in.
   Uses roughly 8 seconds of downloading and 8 of uploading: about 100 MB each on a 100 Mbit/s line. */
window.TV = window.TV || {};

(function () {
  const BASE = 'https://speed.cloudflare.com';
  const SECONDS = 8, STREAMS = 4;

  async function ping(signal) {
    const times = [];
    for (let i = 0; i < 6; i++) {
      const t = performance.now();
      await fetch(BASE + '/__down?bytes=0&r=' + Math.random(), { cache: 'no-store', signal });
      times.push(performance.now() - t);
    }
    times.shift();                                  // the first one includes setting up the connection
    times.sort((a, b) => a - b);
    return times[Math.floor(times.length / 2)];
  }

  async function download(onMbps, signal) {
    let bytes = 0;
    const start = performance.now();
    const stop = new AbortController();
    const end = () => stop.abort();
    signal.addEventListener('abort', end);
    const timer = setTimeout(end, SECONDS * 1000);
    const tick = setInterval(() => onMbps(bytes * 8 / ((performance.now() - start) / 1000) / 1e6), 400);
    const stream = async () => {
      while (!stop.signal.aborted) {
        try {
          const r = await fetch(BASE + '/__down?bytes=25000000&r=' + Math.random(), { cache: 'no-store', signal: stop.signal });
          const reader = r.body.getReader();
          for (;;) { const { done, value } = await reader.read(); if (done) break; bytes += value.length; }
        } catch (e) { if (!stop.signal.aborted) throw e; }
      }
    };
    try { await Promise.all(Array.from({ length: STREAMS }, stream)); }
    finally { clearTimeout(timer); clearInterval(tick); signal.removeEventListener('abort', end); }
    return bytes * 8 / ((performance.now() - start) / 1000) / 1e6;
  }

  async function upload(onMbps, signal) {
    let bytes = 0;
    const start = performance.now();
    const blob = new Blob([new Uint8Array(4 * 1024 * 1024)]);      // 4 MB of zeros per request
    const deadline = start + SECONDS * 1000;
    const tick = setInterval(() => onMbps(bytes * 8 / ((performance.now() - start) / 1000) / 1e6), 400);
    const stream = async () => {
      while (performance.now() < deadline && !signal.aborted) {
        await fetch(BASE + '/__up?r=' + Math.random(), { method: 'POST', body: blob, cache: 'no-store', signal });
        bytes += blob.size;
      }
    };
    try { await Promise.all(Array.from({ length: STREAMS }, stream)); }
    finally { clearInterval(tick); }
    return bytes * 8 / ((performance.now() - start) / 1000) / 1e6;
  }

  TV.speedTest = {
    async run(onProgress, signal) {
      onProgress({ phase: 'ping' });
      const pingMs = await ping(signal);
      onProgress({ phase: 'download', pingMs, mbps: 0 });
      const downMbps = await download(mbps => onProgress({ phase: 'download', pingMs, mbps }), signal);
      onProgress({ phase: 'upload', pingMs, downMbps, mbps: 0 });
      const upMbps = await upload(mbps => onProgress({ phase: 'upload', pingMs, downMbps, mbps }), signal);
      return { pingMs, downMbps, upMbps };
    }
  };
})();
