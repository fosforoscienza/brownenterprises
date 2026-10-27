# CLAUDE.md

Le istruzioni del progetto sono in AGENTS.md, condivise con gli altri agenti:

@AGENTS.md

## In più per Claude Code

- Rispondi in italiano.
- `app.html` è lungo circa 7000 righe: cerca la sezione che ti serve (per
  esempio con `grep -n`) e leggi solo quella invece del file intero.
- Il database si raggiunge solo via SSH sul Mac mini (`docker exec -i
  supabase-db psql -U postgres -d postgres`). Le letture sono libere; per
  qualunque scrittura, migrazione o `tests/calendario.test.sql` chiedi prima.
- Per vedere una modifica al sito basta un server statico nella radice, per
  esempio `python3 -m http.server`. Le funzioni `api/` girano solo su Vercel
  (o con `vercel dev`).
- `.claude/` è nel `.gitignore`: le impostazioni locali restano fuori dal
  repository.
