/* =========================================================================
 * Brown Enterprises — Service Worker (vanilla, no Workbox)
 * "Canalizziamo le tue idee"
 *
 * Strategie:
 *  - Navigazioni (HTML)  -> network-first, fallback cache, fallback /offline.html
 *  - Asset statici       -> stale-while-revalidate (cache-first + refresh async)
 *  - Cross-origin        -> non intercettate (gtag/GA/CDN passano direttamente)
 *  - Solo richieste GET same-origin vengono gestite
 * ========================================================================= */

'use strict';

/* Versione cache: incrementare (be-v2, be-v3, ...) a ogni rilascio
 * per invalidare gli asset vecchi. */
const CACHE = 'be-v1';

/* App shell minimale e "sicuro": file core dell'applicazione.
 * NB: la cache viene popolata in modo resiliente (vedi precache),
 * quindi un singolo file mancante NON rompe l'installazione. */
const APP_SHELL = [
  '/',
  '/index.html',
  '/product/seven-wireless/',
  '/offline.html',
  '/manifest.webmanifest',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/favicon.ico',
];

/* Pagina di fallback offline (deve far parte dell'app shell). */
const OFFLINE_URL = '/offline.html';

/* Estensioni considerate "asset statici" -> stale-while-revalidate. */
const STATIC_ASSET_RE = /\.(?:css|js|mjs|json|webmanifest|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot|map)$/i;

/* =========================================================================
 * INSTALL — precache resiliente dell'app shell + skipWaiting
 * ========================================================================= */
self.addEventListener('install', (event) => {
  event.waitUntil(precache());
  // Attiva subito la nuova versione senza attendere la chiusura delle tab.
  self.skipWaiting();
});

/**
 * Aggiunge ogni risorsa dell'app shell singolarmente: se una fallisce
 * (404, rete, ecc.) viene ignorata e l'install procede comunque.
 * Questo evita il comportamento "tutto o niente" di cache.addAll().
 */
async function precache() {
  const cache = await caches.open(CACHE);
  await Promise.all(
    APP_SHELL.map(async (url) => {
      try {
        // cache: 'reload' -> bypassa la HTTP cache del browser in fase di precache.
        const request = new Request(url, { cache: 'reload' });
        const response = await fetch(request);
        // Cacheamo solo risposte valide (ok) per non salvare 404/500.
        if (response && response.ok) {
          await cache.put(url, response.clone());
        }
      } catch (err) {
        // Risorsa non disponibile: la saltiamo senza interrompere l'install.
        // (intenzionalmente silenzioso in produzione)
      }
    })
  );
}

/* =========================================================================
 * ACTIVATE — pulizia cache vecchie + clients.claim
 * ========================================================================= */
self.addEventListener('activate', (event) => {
  event.waitUntil(activate());
});

async function activate() {
  // Elimina tutte le cache che non corrispondono alla versione corrente.
  const keys = await caches.keys();
  await Promise.all(
    keys.map((key) => (key === CACHE ? Promise.resolve() : caches.delete(key)))
  );
  // Prende il controllo dei client già aperti senza necessità di reload.
  await self.clients.claim();
}

/* =========================================================================
 * FETCH — routing delle richieste
 * ========================================================================= */
self.addEventListener('fetch', (event) => {
  const { request } = event;

  // 1) Gestiamo SOLO richieste GET.
  if (request.method !== 'GET') return;

  // 2) Ignoriamo richieste con header Range (es. streaming video/audio):
  //    le risposte parziali (206) non sono adatte alla cache.
  if (request.headers.has('range')) return;

  let url;
  try {
    url = new URL(request.url);
  } catch (err) {
    return; // URL non valido: lasciamo gestire al browser.
  }

  // 3) Solo same-origin: cross-origin (Google Analytics, gtag, CDN, font
  //    esterni, ecc.) NON viene intercettato e passa direttamente in rete.
  if (url.origin !== self.location.origin) return;

  // 4) Solo schemi http/https (ignora chrome-extension:, data:, ecc.).
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return;

  // 5) Routing per tipo di richiesta.
  if (isNavigationRequest(request)) {
    event.respondWith(handleNavigation(request));
    return;
  }

  if (isStaticAsset(request, url)) {
    event.respondWith(handleStaticAsset(request));
    return;
  }

  // Default: network-first leggero con fallback alla cache (se presente).
  event.respondWith(networkWithCacheFallback(request));
});

/* =========================================================================
 * Helper di classificazione richieste
 * ========================================================================= */

/** Una richiesta è "di navigazione" se mode === 'navigate'
 *  oppure se accetta esplicitamente HTML (fallback per browser datati). */
function isNavigationRequest(request) {
  if (request.mode === 'navigate') return true;
  const accept = request.headers.get('accept') || '';
  return accept.includes('text/html');
}

/** Identifica gli asset statici per destination o per estensione. */
function isStaticAsset(request, url) {
  const dest = request.destination;
  if (
    dest === 'style' ||
    dest === 'script' ||
    dest === 'image' ||
    dest === 'font' ||
    dest === 'manifest'
  ) {
    return true;
  }
  return STATIC_ASSET_RE.test(url.pathname);
}

/* =========================================================================
 * Strategie
 * ========================================================================= */

/**
 * NAVIGAZIONI — Network-first:
 *  1. Prova la rete (e aggiorna la cache se la risposta è ok).
 *  2. Se la rete fallisce -> cerca la pagina in cache.
 *  3. Se non in cache -> restituisce /offline.html.
 *  4. Ultima spiaggia -> risposta sintetica 503.
 */
async function handleNavigation(request) {
  const cache = await caches.open(CACHE);

  try {
    const response = await fetch(request);
    // Salviamo in cache solo risposte "buone" (ok = status 200-299,
    // non opache: per same-origin non avremo risposte opache).
    if (response && response.ok) {
      cache.put(request, response.clone()).catch(() => {});
    }
    return response;
  } catch (err) {
    // Offline o errore di rete: proviamo i fallback in cascata.
    const cached = await cache.match(request);
    if (cached) return cached;

    // Fallback: ignora la query string (es. start_url '/?utm_source=pwa' -> chiave '/').
    const cachedNoSearch = await cache.match(request, { ignoreSearch: true });
    if (cachedNoSearch) return cachedNoSearch;

    const offline = await cache.match(OFFLINE_URL);
    if (offline) return offline;

    // Fallback finale se persino /offline.html non è in cache.
    return new Response(
      '<!doctype html><meta charset="utf-8"><title>Offline</title>' +
        '<h1>Sei offline</h1><p>Brown Enterprises</p>',
      {
        status: 503,
        statusText: 'Service Unavailable',
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      }
    );
  }
}

/**
 * ASSET STATICI — Stale-While-Revalidate:
 *  - Restituisce subito la copia in cache (se presente).
 *  - In parallelo richiede la versione aggiornata e la salva per la
 *    prossima volta.
 *  - Se non c'è copia in cache, attende la rete.
 */
async function handleStaticAsset(request) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(request);

  const networkFetch = fetch(request)
    .then((response) => {
      // Cacheamo solo risposte valide e non opache (status === 200).
      // Le opaque (cross-origin no-cors) sono già escluse a monte.
      if (response && response.status === 200 && response.type === 'basic') {
        cache.put(request, response.clone()).catch(() => {});
      }
      return response;
    })
    .catch(() => null);

  // Se in cache -> serviamo subito; la rete aggiorna in background.
  if (cached) {
    // Non attendiamo networkFetch: è il "revalidate" silenzioso.
    return cached;
  }

  // Niente in cache -> dipendiamo dalla rete.
  const network = await networkFetch;
  if (network) return network;

  // Asset non recuperabile e non in cache.
  return new Response('', { status: 504, statusText: 'Gateway Timeout' });
}

/**
 * DEFAULT — Network-first con fallback alla cache.
 * Usata per richieste GET same-origin che non sono né navigazioni
 * né asset statici riconosciuti.
 */
async function networkWithCacheFallback(request) {
  const cache = await caches.open(CACHE);
  try {
    const response = await fetch(request);
    if (response && response.status === 200 && response.type === 'basic') {
      cache.put(request, response.clone()).catch(() => {});
    }
    return response;
  } catch (err) {
    const cached = await cache.match(request);
    if (cached) return cached;
    return new Response('', { status: 504, statusText: 'Gateway Timeout' });
  }
}

/* =========================================================================
 * MESSAGE — attivazione manuale dal client (es. "Aggiorna ora")
 * ========================================================================= */
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
