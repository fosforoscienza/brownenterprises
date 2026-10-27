# AGENTS.md

Istruzioni per gli agenti di codice (Claude Code, Codex, Cursor & co.) che
lavorano su questo repository. Per la panoramica pensata per le persone vedi
[README.md](README.md).

## Cos'è

Il sito di Brown Enterprises (www.brownenterprises.it) più l'area riservata
del team, «Mario Project Manager».

- **Sito pubblico**: mirror statico di un vecchio sito WordPress/Elementor
  (`wp-content/`, `wp-includes/` vengono da lì). Italiano nella radice,
  inglese in `en/`. Pagine prodotto in `product/`, sezione software
  («Brown Coding Enterprises») in `software/`.
- **Area riservata**: `login.html` + `app.html`, una single page in HTML, CSS
  e JavaScript inline (circa 7000 righe) che parla direttamente con Supabase
  dal browser. Progetti divisi in categorie del team (più «Personale»,
  Preferiti e Archiviati), schede To Do / In Progress / Done, Archivio
  (file e link Drive), Panoramica, scadenze e il calendario «Chi fa cosa».
- **Funzioni serverless** in `api/` (Vercel, Node): il feed `.ics` per Apple
  Calendar e la lettura dei calendari pubblici iCloud.

## Stack e vincoli

- **Niente bundler, niente framework, niente `package.json`.** I file sono
  serviti così come sono. Non introdurre npm, build step o dipendenze senza
  che venga chiesto.
- JavaScript vanilla in stile ES5 (`var`, `function`, `"use strict"`) nelle
  funzioni `api/` e in `js/`. Segui lo stile del file che stai toccando.
- `vendor/supabase-js.min.js` è la libreria Supabase copiata a mano: si
  aggiorna sostituendo il file (vedi i commit `chore: supabase-js …`).
- `build.sh` fa una cosa sola: scrive la SHA del commit dentro `sw.js`, così
  la cache del service worker cambia a ogni deploy. Gli asset non hanno hash
  nel nome, quindi non togliere quel passaggio.
- Commenti e testi dell'interfaccia sono in italiano (le pagine `en/` in
  inglese). Nei commenti gli accenti finali sono spesso scritti con
  l'apostrofo (`e'`, `puo'`): è voluto, mantienilo nei file che lo usano.

## Database

Supabase **self-hosted sul Mac mini dell'ufficio**, non Supabase Cloud.

- URL pubblico: `https://api.fosforo.info`, che passa da Cloudflare e da un
  Cloudflare Tunnel (`cloudflared` sul Mac mini) fino a Kong.
- Sul Mac mini è lo stack Docker Compose `~/Software/supabase-local`
  (container `supabase-*`, database nel container `supabase-db`, Postgres 17).
  Il nome «Local Dev» nella sua configurazione è fuorviante: è quello di
  produzione.
- Sullo stesso Mac mini c'è un secondo stack, `~/Software/supabase-fosforo`
  (container `fosforo-*`, `ospiti.fosforo.info`). **Non è di questo
  progetto**: non toccarlo.
- La chiave pubblicabile (anon) sta in `js/be-config.js` ed è pubblica per
  costruzione. Le funzioni `api/` la leggono da `BE_SUPABASE_URL` e
  `BE_SUPABASE_ANON_KEY` se impostate su Vercel. La service key non deve
  mai finire nel repository né nel browser.
- Tutta la sicurezza dei dati è affidata alle policy RLS di Postgres:
  ogni tabella nuova ha bisogno delle sue policy.
- Gli utenti accedono col nome; l'email vera è `<nome>@brown.internal`
  (`beEmailForName` in `js/be-config.js`). Il team si riconosce da quel
  dominio, non dal nome visualizzato.

### Schema e migrazioni

Non c'è un sistema di migrazioni. Ogni file in `sql/` è una modifica da
eseguire **una sola volta**, a mano, nell'editor SQL di Supabase Studio o con
`psql` sul container. I file sono scritti per essere idempotenti
(`if not exists`, `create or replace`, `drop policy if exists`).

- Le tabelle di base (`be_projects`, `be_columns`, `be_cards`, `be_profiles`,
  `be_project_shares`) sono state create prima di questa cartella e non hanno
  un file in `sql/`.
- Per una modifica nuova: crea un nuovo file in `sql/` con l'intestazione
  standard (cosa fa, perché, «Eseguire una sola volta…», eventuali
  dipendenze), non riscrivere quelli vecchi.
- **Non eseguire SQL sul database di produzione senza una conferma esplicita
  di chi ti ha chiesto il lavoro.** È il database vero del team.

## Test

```sh
node --test tests/*.test.js
```

Test di `api/` e `api/_lib/ics.js` con `node:test`, senza dipendenze e con la
rete simulata. Devono passare prima di ogni commit che tocca `api/`.

`tests/calendario.test.sql`, `tests/calendario_extra.test.sql` e
`tests/categorie.test.sql` provano i file omonimi di `sql/` sul database vero
dentro una transazione annullata alla fine. Si lancia via SSH sul Mac mini
(l'intestazione dei file usa l'alias `mac-mini`; usa quello configurato sulla
tua macchina) e vanno eseguiti solo se richiesto.

`tests/` è nel repository ma non viene pubblicata (`.vercelignore`).

## Deploy e branch

- Vercel pubblica `main` in produzione su www.brownenterprises.it; gli altri
  branch hanno un deploy di anteprima.
- Si lavora su un branch (`test` o `claude/<argomento>`) e si apre una pull
  request verso `main`. Non fare push diretti su `main`.
- Messaggi di commit in italiano con prefisso: `feat:`, `fix:`, `ui:`,
  `perf:`, `a11y:`, `test:`, `chore:`. I nomi delle funzioni dell'app vanno
  tra caporali, es. `feat: «Chi fa cosa» in Agenda`.

## Cose da non rompere

- `0c461c62c30ca2cf16f2df68aca048e5.txt` è la chiave di IndexNow e deve
  restare nella radice (vedi `indexnow.sh`).
- `sitemap.xml`, `robots.txt`, `llms.txt` (e `en/llms.txt`) vanno aggiornati
  quando si aggiungono o tolgono pagine pubbliche; poi `./indexnow.sh <percorsi>`.
- Ogni pagina pubblica ha la sua gemella in `en/`: una modifica ai contenuti
  va fatta in entrambe le lingue.
- Le intestazioni HTTP (cache del service worker, manifest, icone) stanno in
  `vercel.json`.
- I file in `api/` che iniziano con `_` non diventano funzioni su Vercel:
  è lì che va il codice condiviso.
