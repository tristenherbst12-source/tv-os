/* The phone remote's service worker: what Chrome looks for to offer "Install app". It keeps the page itself for when
   the TV is off (the page then says it cannot reach the TV); the buttons always go to the TV. */
const PAGE = 'tv-remote-v1';
self.addEventListener('install', e => {
  e.waitUntil(caches.open(PAGE).then(c => c.addAll(['/', '/manifest.webmanifest', '/icon-192.png'])).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.pathname.startsWith('/api/')) return;       // buttons and status: always live
  // The page: the TV's latest when it answers, else the kept copy.
  e.respondWith(fetch(e.request).then(r => {
    if (r.ok) { const copy = r.clone(); caches.open(PAGE).then(c => c.put(e.request, copy)); }
    return r;
  }).catch(() => caches.match(e.request, { ignoreSearch: true })));
});
