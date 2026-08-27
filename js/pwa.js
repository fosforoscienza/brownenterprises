/* =========================================================================
 * Brown Enterprises — runtime PWA condiviso
 *
 * Un solo file incluso da tutte le pagine, al posto del codice inline che
 * prima viveva duplicato in index.html e en/index.html (e mancava altrove).
 *
 * Fa cinque cose:
 *   1. registra il service worker e gestisce l'arrivo di una nuova versione
 *   2. offre l'installazione su Android (beforeinstallprompt) ricordando il rifiuto
 *   3. offre l'istruzione "Aggiungi a Home" su iOS, che non ha quell'evento
 *   4. avvisa quando la connessione cade e quando torna
 *   5. espone le safe area come variabili CSS e marca <html> con lo stato PWA
 *
 * Niente dipendenze, niente build step: e' servito cosi' com'e'.
 * ========================================================================= */

(function () {
  'use strict';

  var doc = document;
  var root = doc.documentElement;
  var EN = (root.lang || '').toLowerCase().indexOf('en') === 0;

  var T = EN ? {
    install: 'Install the app',
    installAria: 'Install the Brown Enterprises app',
    iosTitle: 'Install on your iPhone',
    iosBody: 'Tap the Share button, then <b>Add to Home Screen</b>.',
    offline: 'You are offline. You can keep browsing the pages already saved.',
    online: 'You are back online.',
    updateBody: 'A new version is available.',
    updateBtn: 'Update',
    later: 'Not now',
    close: 'Close'
  } : {
    install: 'Installa l’app',
    installAria: 'Installa l’app Brown Enterprises',
    iosTitle: 'Installa sul tuo iPhone',
    iosBody: 'Tocca il pulsante Condividi, poi <b>Aggiungi a Home</b>.',
    offline: 'Sei offline. Puoi continuare a sfogliare le pagine già salvate.',
    online: 'Sei di nuovo online.',
    updateBody: 'È disponibile una nuova versione.',
    updateBtn: 'Aggiorna',
    later: 'Non ora',
    close: 'Chiudi'
  };

  /* --- stato: installata? quale piattaforma? -------------------------- */

  function isStandalone() {
    return (
      (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ||
      (window.matchMedia && window.matchMedia('(display-mode: fullscreen)').matches) ||
      (window.matchMedia && window.matchMedia('(display-mode: minimal-ui)').matches) ||
      navigator.standalone === true
    );
  }

  var IS_IOS =
    /iPad|iPhone|iPod/.test(navigator.platform || '') ||
    (/Mac/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);

  // Marca <html>: il CSS delle pagine puo' reagire senza duplicare la logica.
  root.classList.add('be-js');
  if (isStandalone()) root.classList.add('be-standalone');
  if (IS_IOS) root.classList.add('be-ios');

  /* --- store delle scelte dell'utente (rifiuto install, ecc.) --------- */

  function get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

  var DISMISS_KEY = 'be-install-dismissed';
  var DISMISS_DAYS = 60;

  function installDismissed() {
    var v = get(DISMISS_KEY);
    if (!v) return false;
    var when = parseInt(v, 10);
    if (!when) return false;
    return (Date.now() - when) < DISMISS_DAYS * 86400000;
  }

  /* --- stile: iniettato una volta sola -------------------------------- */

  // Solo i componenti creati da questo file. Le safe area e le correzioni
  // strutturali stanno in /css/pwa.css, che vale gia' al primo paint.
  var CSS =
    '.be-fab{' +
      'position:fixed;z-index:99998;' +
      'right:calc(24px + var(--be-r,0px));' +
      'bottom:calc(88px + var(--be-b,0px));' +
      'min-height:44px;padding:12px 20px;' +
      'background:#0e1217;color:#fff;' +
      'border:1px solid rgba(255,255,255,0.14);border-radius:999px;' +
      'font:600 14px/1 Inter,system-ui,-apple-system,sans-serif;letter-spacing:.3px;' +
      'box-shadow:0 8px 24px rgba(0,0,0,.35);cursor:pointer;' +
      'display:none;align-items:center;gap:8px;' +
      '-webkit-tap-highlight-color:transparent;touch-action:manipulation;' +
    '}' +
    '.be-fab.be-show{display:inline-flex}' +
    '.be-toast{' +
      'position:fixed;z-index:2147483600;' +
      'left:calc(16px + var(--be-l,0px));right:calc(16px + var(--be-r,0px));' +
      'bottom:calc(16px + var(--be-b,0px));' +
      'max-width:520px;margin:0 auto;' +
      'background:#0e1217;color:#fff;' +
      'border:1px solid rgba(255,255,255,.16);border-radius:14px;' +
      'padding:14px 16px;box-shadow:0 14px 44px rgba(0,0,0,.5);' +
      'font:400 14px/1.5 Inter,system-ui,-apple-system,sans-serif;' +
      'display:flex;align-items:center;gap:12px;flex-wrap:wrap;' +
      'transform:translateY(12px);opacity:0;transition:opacity .18s,transform .18s;' +
    '}' +
    '.be-toast.be-show{transform:translateY(0);opacity:1}' +
    '.be-toast p{margin:0;flex:1 1 200px}' +
    '.be-toast button{' +
      'min-height:40px;padding:9px 16px;border-radius:999px;cursor:pointer;' +
      'font:600 14px/1 Inter,system-ui,sans-serif;' +
      '-webkit-tap-highlight-color:transparent;touch-action:manipulation;' +
    '}' +
    '.be-toast .be-primary{border:0;background:#fff;color:#0e1217}' +
    '.be-toast .be-ghost{border:1px solid rgba(255,255,255,.24);background:transparent;color:#fff}' +
    '.be-toast.be-warn{border-color:rgba(255,176,32,.5)}' +
    '@media (prefers-reduced-motion:reduce){.be-toast{transition:none}}';

  var styleInjected = false;
  function ensureStyle() {
    if (styleInjected) return;
    styleInjected = true;
    var s = doc.createElement('style');
    s.setAttribute('data-be-pwa', '');
    s.textContent = CSS;
    (doc.head || root).appendChild(s);
  }

  function onReady(fn) {
    if (doc.body) { fn(); return; }
    doc.addEventListener('DOMContentLoaded', fn, { once: true });
  }

  /* --- toast riutilizzabile ------------------------------------------- */

  function toast(opts) {
    ensureStyle();
    onReady(function () {
      var old = doc.querySelector('.be-toast[data-be-kind="' + opts.kind + '"]');
      if (old) old.remove();

      var box = doc.createElement('div');
      box.className = 'be-toast' + (opts.warn ? ' be-warn' : '');
      box.setAttribute('data-be-kind', opts.kind);
      box.setAttribute('role', opts.warn ? 'alert' : 'status');

      var p = doc.createElement('p');
      p.innerHTML = opts.html;
      box.appendChild(p);

      function close() {
        box.classList.remove('be-show');
        setTimeout(function () {
          box.remove();
          if (!doc.querySelector('.be-toast')) root.classList.remove('be-toast-open');
        }, 200);
      }

      if (opts.action) {
        var a = doc.createElement('button');
        a.type = 'button';
        a.className = 'be-primary';
        a.textContent = opts.action.label;
        a.addEventListener('click', function () { close(); opts.action.run(); });
        box.appendChild(a);
      }
      if (opts.dismiss !== false) {
        var d = doc.createElement('button');
        d.type = 'button';
        d.className = 'be-ghost';
        d.textContent = opts.dismissLabel || T.close;
        d.addEventListener('click', function () {
          close();
          if (opts.onDismiss) opts.onDismiss();
        });
        box.appendChild(d);
      }

      doc.body.appendChild(box);
      // I bottoni flottanti del sito vivono nella stessa zona in basso a
      // destra: mentre un avviso e' aperto si tolgono di mezzo (vedi pwa.css).
      root.classList.add('be-toast-open');
      requestAnimationFrame(function () { box.classList.add('be-show'); });

      if (opts.autoHide) setTimeout(close, opts.autoHide);
    });
  }

  /* --- 1. service worker + aggiornamenti ------------------------------ */

  function promptUpdate(worker) {
    toast({
      kind: 'update',
      html: T.updateBody,
      action: {
        label: T.updateBtn,
        run: function () { worker.postMessage({ type: 'SKIP_WAITING' }); }
      },
      dismissLabel: T.later
    });
  }

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('/sw.js', { scope: '/' }).then(function (reg) {
        // Una versione e' gia' in attesa da una visita precedente.
        if (reg.waiting && navigator.serviceWorker.controller) promptUpdate(reg.waiting);

        reg.addEventListener('updatefound', function () {
          var sw = reg.installing;
          if (!sw) return;
          sw.addEventListener('statechange', function () {
            // "installed" con un controller attivo = aggiornamento, non prima installazione.
            if (sw.state === 'installed' && navigator.serviceWorker.controller) {
              promptUpdate(sw);
            }
          });
        });
      }).catch(function () {});

      // Il nuovo SW ha preso il controllo: ricarica una volta sola.
      var refreshing = false;
      navigator.serviceWorker.addEventListener('controllerchange', function () {
        if (refreshing) return;
        refreshing = true;
        window.location.reload();
      });
    });
  }

  /* --- 2. installazione su Android ------------------------------------ */

  var deferred = null;
  var fab = null;

  function ensureFab() {
    if (fab) return fab;
    ensureStyle();
    fab = doc.createElement('button');
    fab.id = 'be-a2hs';
    fab.type = 'button';
    fab.className = 'be-fab';
    fab.textContent = T.install;
    fab.setAttribute('aria-label', T.installAria);
    fab.addEventListener('click', function () {
      if (!deferred) return;
      deferred.prompt();
      var done = function (choice) {
        if (choice && choice.outcome === 'dismissed') set(DISMISS_KEY, String(Date.now()));
        deferred = null;
        hideFab();
      };
      if (deferred.userChoice && deferred.userChoice.then) {
        deferred.userChoice.then(done, function () { done(null); });
      } else { done(null); }
    });
    onReady(function () { doc.body.appendChild(fab); });
    return fab;
  }

  function showFab() { ensureFab(); onReady(function () { fab.classList.add('be-show'); }); }
  function hideFab() { if (fab) fab.classList.remove('be-show'); }

  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    deferred = e;
    if (isStandalone() || installDismissed()) return;
    showFab();
  });

  window.addEventListener('appinstalled', function () {
    deferred = null;
    hideFab();
    try { localStorage.removeItem(DISMISS_KEY); } catch (err) {}
  });

  /* --- 3. istruzione "Aggiungi a Home" su iOS -------------------------- */

  // Safari non emette beforeinstallprompt: l'unica via e' spiegare il gesto.
  // Lo si mostra una volta sola, e solo a chi non ha gia' installato.
  if (IS_IOS && !isStandalone() && !installDismissed()) {
    window.addEventListener('load', function () {
      setTimeout(function () {
        toast({
          kind: 'ios-install',
          html: '<b>' + T.iosTitle + '</b><br>' + T.iosBody,
          onDismiss: function () { set(DISMISS_KEY, String(Date.now())); },
          dismissLabel: T.close
        });
      }, 4000);
    });
  }

  /* --- 3bis. ritorno indietro nell'app installata ---------------------- */

  // Solo in standalone e solo fuori dalla home: in una finestra senza barra
  // del browser, da una sottopagina non si tornerebbe indietro in alcun modo.
  // L'area riservata ha una sua navigazione e resta esclusa.
  function isHome(p) {
    return p === '/' || p === '/index.html' || p === '/en/' || p === '/en/index.html';
  }
  function isApp(p) {
    return p === '/app.html' || p === '/login.html';
  }

  if (isStandalone() && !isHome(location.pathname) && !isApp(location.pathname)) {
    onReady(function () {
      if (doc.getElementById('be-back')) return;
      var b = doc.createElement('button');
      b.id = 'be-back';
      b.type = 'button';
      b.setAttribute('aria-label', EN ? 'Go back' : 'Torna indietro');
      b.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" ' +
        'stroke="currentColor" stroke-width="2.4" stroke-linecap="round" ' +
        'stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>';
      b.addEventListener('click', function () {
        if (history.length > 1) history.back();
        else location.href = EN ? '/en/' : '/';
      });
      doc.body.appendChild(b);
    });
  }

  /* --- 4. stato della connessione -------------------------------------- */

  var offlineShown = false;

  window.addEventListener('offline', function () {
    offlineShown = true;
    toast({ kind: 'net', html: T.offline, warn: true, dismiss: true });
  });

  window.addEventListener('online', function () {
    if (!offlineShown) return;
    offlineShown = false;
    toast({ kind: 'net', html: T.online, autoHide: 3500, dismiss: false });
  });

  /* --- 5. API minima per le pagine ------------------------------------- */

  window.bePWA = {
    isStandalone: isStandalone,
    isIOS: IS_IOS,
    toast: toast
  };
})();
