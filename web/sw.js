// Offline shell. Financial records are never cached here — they live
// encrypted in IndexedDB and are only ever decrypted in the page.

const CACHE = 'moneyup-shell-v1';
const SHELL = [
  './', './index.html', './manifest.webmanifest',
  './src/main.js', './src/app.js', './src/sheets.js', './src/domain.js',
  './src/budget.js', './src/report.js', './src/parse.js', './src/crypto.js',
  './src/store.js', './src/i18n.js', './src/format.js', './src/csv.js',
  './icons/icon-192.png', './icons/icon-512.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(
      keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))
    ))
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  event.respondWith(
    caches.match(event.request).then((cached) => cached ?? fetch(event.request))
  );
});
