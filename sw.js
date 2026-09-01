/* =========================================================================
 * Brown Enterprises — Service Worker (vanilla, no Workbox)
 * "Canalizziamo le tue idee"
 *
 * Strategie:
 *  - Navigazioni (HTML)  -> network-first con timeout, fallback cache,
 *                           fallback /offline.html (o /en/offline.html)
 *  - Asset statici       -> stale-while-revalidate, con revalidate che
 *                           bypassa la HTTP cache (altrimenti dopo un deploy
 *                           il CSS resta vecchio finche' non scade il max-age)
 *  - Cross-origin        -> non intercettate (gtag/GA/Supabase passano diretti)
 *  - Solo GET same-origin
 *
 * Note di progetto:
 *  - il sito e' un mirror statico di WordPress/Elementor: gli asset non hanno
 *    hash nel nome, quindi la cache e' versionata sulla build (vedi CACHE_VERSION)
 *  - ogni scrittura in cache passa da event.waitUntil: senza, il browser puo'
 *    terminare il worker appena risposto e abortire il salvataggio
 * ========================================================================= */

'use strict';

/* La build sostituisce __BUILD__ con la SHA del commit (vedi vercel.json).
 * In locale resta 'dev' e va benissimo. */
const CACHE_VERSION = 'be-__BUILD__';
const SHELL_CACHE = CACHE_VERSION + '-shell';
const ASSET_CACHE = CACHE_VERSION + '-assets';
const PAGE_CACHE = CACHE_VERSION + '-pages';

/* App shell: cio' che deve esserci offline anche alla primissima visita.
 * Include il CSS critico, altrimenti offline la home appare senza stile —
 * peggio della pagina offline curata. */
const APP_SHELL = [
  '/',
  '/en/',
  '/offline.html',
  '/en/offline.html',
  '/manifest.webmanifest',
  '/en/manifest.webmanifest',
  '/css/pwa.css',
  '/js/pwa.js',
  '/favicon.ico',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/apple-touch-icon.png',
  // L'area riservata e' una scorciatoia del manifest: senza queste, aprirla
  // offline finiva sulla pagina di errore invece che sul login.
  '/login.html',
  '/app.html',
  '/js/be-config.js',
  '/vendor/supabase-js.min.js',
];

/* Fallback offline, per lingua. */
const OFFLINE_IT = '/offline.html';
const OFFLINE_EN = '/en/offline.html';

/* Quanto aspettare la rete su una navigazione prima di servire la cache.
 * Serve contro il "lie-fi": connesso ma inutilizzabile. */
const NAV_TIMEOUT_MS = 4000;

/* Tetti alle cache, per non far crescere lo storage senza controllo
 * (una galleria di immagini o un PDF pesante lo riempirebbero). */
const LIMITS = { assets: 160, pages: 40 };

const STATIC_ASSET_RE = /\.(?:css|js|mjs|json|webmanifest|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot|map)$/i;

/* =========================================================================
 * INSTALL — precache resiliente
 * ========================================================================= */
self.addEventListener('install', (event) => {
  event.waitUntil(precache());
  // NB: niente skipWaiting() qui. La nuova versione resta in attesa e la
  // pagina propone "Aggiorna": cosi' una tab aperta non si ritrova gli asset
  // cancellati sotto i piedi a meta' navigazione.
});

async function precache() {
  const cache = await caches.open(SHELL_CACHE);
  await Promise.all(
    APP_SHELL.map(async (url) => {
      try {
        const response = await fetch(new Request(url, { cache: 'reload' }));
        if (response && response.ok) await cache.put(url, response.clone());
      } catch (err) {
        // Risorsa non disponibile: si salta, l'install procede comunque.
      }
    })
  );
}

/* =========================================================================
 * ACTIVATE — pulizia + navigation preload + claim
 * ========================================================================= */
self.addEventListener('activate', (event) => {
  event.waitUntil(activate());
});

async function activate() {
  // Avvia la richiesta di rete in parallelo al boot del worker: su mobile
  // toglie qualche centinaio di ms a ogni navigazione.
  if (self.registration.navigationPreload) {
    try { await self.registration.navigationPreload.enable(); } catch (e) {}
  }

  const keep = new Set([SHELL_CACHE, ASSET_CACHE, PAGE_CACHE]);
  const keys = await caches.keys();
  await Promise.all(keys.map((k) => (keep.has(k) ? Promise.resolve() : caches.delete(k))));

  await self.clients.claim();
}

/* =========================================================================
 * FETCH
 * ========================================================================= */
self.addEventListener('fetch', (event) => {
  const request = event.request;

  if (request.method !== 'GET') return;
  // Le risposte parziali (206) non sono cacheabili.
  if (request.headers.has('range')) return;

  let url;
  try { url = new URL(request.url); } catch (err) { return; }

  // Cross-origin (GA, Supabase, CDN): non intercettiamo.
  if (url.origin !== self.location.origin) return;
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return;

  if (isNavigationRequest(request)) {
    event.respondWith(handleNavigation(event));
    return;
  }
  if (isStaticAsset(request, url)) {
    event.respondWith(handleStaticAsset(event));
    return;
  }
  event.respondWith(networkWithCacheFallback(event));
});

/* Solo il vero mode:'navigate'. Il vecchio fallback su Accept:text/html
 * catturava anche fetch di dati e li trattava come pagine. */
function isNavigationRequest(request) {
  return request.mode === 'navigate';
}

function isStaticAsset(request, url) {
  const dest = request.destination;
  if (dest === 'style' || dest === 'script' || dest === 'image' ||
      dest === 'font' || dest === 'manifest') return true;
  return STATIC_ASSET_RE.test(url.pathname);
}

function offlineUrlFor(request) {
  return new URL(request.url).pathname.indexOf('/en/') === 0 ? OFFLINE_EN : OFFLINE_IT;
}

/* Una risposta redirected non puo' essere restituita a una navigazione:
 * il browser solleva un TypeError. La si ricostruisce. */
async function safeForNavigation(response) {
  if (!response || !response.redirected) return response;
  const body = await response.blob();
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout')), ms);
    promise.then(
      (v) => { clearTimeout(t); resolve(v); },
      (e) => { clearTimeout(t); reject(e); }
    );
  });
}

/* =========================================================================
 * NAVIGAZIONI — network-first con timeout
 * ========================================================================= */
async function handleNavigation(event) {
  const request = event.request;
  const cache = await caches.open(PAGE_CACHE);

  try {
    // navigationPreload: la richiesta e' gia' partita mentre il worker si avviava.
    const preload = event.preloadResponse ? await event.preloadResponse : null;
    const response = preload || (await withTimeout(fetch(request), NAV_TIMEOUT_MS));

    if (response && response.ok) {
      const copy = response.clone();
      // waitUntil: la scrittura sopravvive alla risposta.
      event.waitUntil(
        cache.put(request, copy).then(() => trim(PAGE_CACHE, LIMITS.pages)).catch(() => {})
      );
    }
    return await safeForNavigation(response);
  } catch (err) {
    const cached = await cache.match(request);
    if (cached) return safeForNavigation(cached);

    const noSearch = await cache.match(request, { ignoreSearch: true });
    if (noSearch) return safeForNavigation(noSearch);

    // start_url '/?utm_source=pwa' -> chiave '/' nell'app shell.
    const shell = await caches.open(SHELL_CACHE);
    const fromShell = await shell.match(request, { ignoreSearch: true });
    if (fromShell) return safeForNavigation(fromShell);

    const offline = await shell.match(offlineUrlFor(request));
    if (offline) return offline;

    return new Response(
      '<!doctype html><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' +
        '<title>Offline · Brown Enterprises</title>' +
        '<style>html,body{margin:0;height:100%;background:#0E1217;color:#fff;' +
        'font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;' +
        'display:grid;place-items:center;text-align:center;padding:24px}</style>' +
        '<div><h1>Sei offline</h1><p>Brown Enterprises</p></div>',
      {
        status: 503,
        statusText: 'Service Unavailable',
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      }
    );
  }
}

/* =========================================================================
 * ASSET STATICI — stale-while-revalidate
 * ========================================================================= */
async function handleStaticAsset(event) {
  const request = event.request;
  const cache = await caches.open(ASSET_CACHE);
  const cached = await cache.match(request);

  // cache:'no-cache' forza la rivalidazione condizionale (If-None-Match):
  // su asset invariati il server risponde 304, quindi costa pochi byte, ma
  // dopo un deploy il file nuovo arriva subito invece di aspettare il max-age.
  const revalidate = fetch(new Request(request, { cache: 'no-cache' }))
    .then((response) => {
      if (response && response.status === 200 && response.type === 'basic') {
        return cache.put(request, response.clone())
          .then(() => trim(ASSET_CACHE, LIMITS.assets))
          .then(() => response)
          .catch(() => response);
      }
      return response;
    })
    .catch(() => null);

  if (cached) {
    // Serviamo subito la copia locale, ma teniamo vivo il worker finche'
    // il refresh in background non ha finito di scrivere.
    event.waitUntil(revalidate);
    return cached;
  }

  const network = await revalidate;
  if (network) return network;
  return new Response('', { status: 504, statusText: 'Gateway Timeout' });
}

/* =========================================================================
 * DEFAULT — network-first con fallback cache
 * ========================================================================= */
async function networkWithCacheFallback(event) {
  const request = event.request;
  const cache = await caches.open(ASSET_CACHE);
  try {
    const response = await fetch(request);
    if (response && response.status === 200 && response.type === 'basic') {
      const copy = response.clone();
      event.waitUntil(cache.put(request, copy).catch(() => {}));
    }
    return response;
  } catch (err) {
    const cached = await cache.match(request);
    if (cached) return cached;
    return new Response('', { status: 504, statusText: 'Gateway Timeout' });
  }
}

/* =========================================================================
 * Tetto alle cache: elimina le voci piu' vecchie (FIFO sull'ordine di keys())
 * ========================================================================= */
async function trim(cacheName, max) {
  const cache = await caches.open(cacheName);
  const keys = await cache.keys();
  if (keys.length <= max) return;
  await Promise.all(keys.slice(0, keys.length - max).map((k) => cache.delete(k)));
}

/* =========================================================================
 * MESSAGE — "Aggiorna" dalla pagina
 * ========================================================================= */
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
