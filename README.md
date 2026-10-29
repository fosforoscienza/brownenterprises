# Brown Enterprises

Il sito di [Brown Enterprises](https://www.brownenterprises.it/), società di
comunicazione e divulgazione scientifica di Senigallia, e l'area riservata
del team, **Mario Project Manager**.

![Home su mobile](screenshots/mobile-home.jpg)

## Cosa c'è dentro

| Parte | Dove | Cosa fa |
|---|---|---|
| Sito pubblico | `index.html`, `en/`, `product/`, `software/` | Mirror statico del vecchio sito WordPress, in italiano e inglese, installabile come PWA |
| Area riservata | `login.html`, `app.html` | Progetti in categorie (più Personale, Preferiti e Archiviati) e schede, Archivio, Panoramica, scadenze e il calendario condiviso «Chi fa cosa» |
| Funzioni | `api/` | Feed `.ics` per Apple Calendar, lettura dei calendari pubblici iCloud e riepilogo email giornaliero dei task |
| Database | `sql/` | Le modifiche allo schema Supabase, da eseguire a mano |
| Test | `tests/` | Test delle funzioni e del calendario |

Non c'è nessun bundler e nessuna dipendenza da installare: i file vengono
pubblicati così come sono.

## Dove gira

- **Sito e funzioni**: Vercel. Ogni merge su `main` va in produzione; gli
  altri branch hanno un'anteprima. `build.sh` lega la cache del service
  worker al commit.
- **Database**: Supabase self-hosted sul Mac mini dell'ufficio, raggiungibile
  su `https://api.fosforo.info` attraverso un Cloudflare Tunnel. Lo stack è
  `~/Software/supabase-local` sul Mac mini (database nel container
  `supabase-db`, Postgres 17).

## Lavorare in locale

Il sito si apre con un qualunque server statico:

```sh
python3 -m http.server 8080
```

L'area riservata in locale usa comunque il database vero: attenzione a
quello che si modifica.

Le funzioni in `api/` girano su Vercel (in locale con `vercel dev`).
`api/task-digest` parte ogni mattina dal cron di `vercel.json` e ha bisogno
di `CRON_SECRET`, `BE_SUPABASE_SERVICE_KEY`, `RESEND_API_KEY` e
`BE_DIGEST_FROM` nelle variabili d'ambiente di Vercel.

## Test

```sh
node --test tests/*.test.js
```

Servono solo Node 18 o più recente. I test SQL del calendario, degli Extra,
delle categorie e del coordinatore (`tests/calendario.test.sql`,
`tests/calendario_extra.test.sql`, `tests/categorie.test.sql`,
`tests/coordinatore.test.sql`) girano sul
database vero dentro una transazione annullata; il comando è
nell'intestazione dei file.

## Modificare il database

Ogni file in `sql/` si esegue una volta sola nell'editor SQL di Supabase
Studio. Per una modifica nuova si aggiunge un file, senza riscrivere quelli
già eseguiti. Le regole di accesso ai dati sono policy RLS di Postgres.

## Contribuire

1. Lavora su un branch (`test` o `claude/<argomento>`).
2. Fai girare i test.
3. Apri una pull request verso `main`.

Le regole per gli agenti di codice sono in [AGENTS.md](AGENTS.md)
(e [CLAUDE.md](CLAUDE.md) per Claude Code).
