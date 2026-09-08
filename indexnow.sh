#!/bin/sh
# Notifica a IndexNow (Bing, Yandex e chi condivide il loro indice) che alcune
# pagine sono cambiate. Google non partecipa: per lui resta Search Console.
#
# La chiave e' un file di testo servito dalla radice del dominio e contenente
# solo se' stessa: e' cosi' che IndexNow verifica che chi segnala le URL
# controlli davvero il sito. Se il file sparisce, le segnalazioni vengono
# rifiutate — quindi non va rimosso dal repository.
#
# Uso:
#   ./indexnow.sh                      tutte le URL della sitemap
#   ./indexnow.sh /software/ /en/      solo i percorsi indicati
set -e

KEY=0c461c62c30ca2cf16f2df68aca048e5
HOST=www.brownenterprises.it
BASE="https://$HOST"

if [ $# -gt 0 ]; then
	URLS=$(for p in "$@"; do echo "$BASE$p"; done)
else
	URLS=$(sed -n 's;.*<loc>\(.*\)</loc>.*;\1;p' sitemap.xml)
fi

LIST=$(echo "$URLS" | sed 's/.*/"&"/' | paste -sd, -)
COUNT=$(echo "$URLS" | grep -c .)

BODY=$(printf '{"host":"%s","key":"%s","keyLocation":"%s/%s.txt","urlList":[%s]}' \
	"$HOST" "$KEY" "$BASE" "$KEY" "$LIST")

echo "$URLS"
echo "--- $COUNT URL a IndexNow"

CODE=$(curl -s -o /tmp/indexnow-out -w '%{http_code}' \
	-H 'Content-Type: application/json; charset=utf-8' \
	-d "$BODY" https://api.indexnow.org/indexnow)

echo "HTTP $CODE"
[ -s /tmp/indexnow-out ] && cat /tmp/indexnow-out && echo
case "$CODE" in
	200|202) echo "accettato" ;;
	*) echo "rifiutato: 400 richiesta malformata, 403 chiave non valida, 422 URL fuori dal dominio, 429 troppe richieste" ; exit 1 ;;
esac
