#!/bin/sh
# Build step del sito statico: una riga sola, nessun bundler.
#
# Il service worker versiona le sue cache su CACHE_VERSION. Senza un hash nei
# nomi dei file (il sito e' un mirror WordPress), l'unico modo per invalidare
# gli asset dopo un deploy e' legare la versione al commit.
# Vercel espone la SHA come VERCEL_GIT_COMMIT_SHA anche sui progetti statici.
set -e

BUILD_ID="${VERCEL_GIT_COMMIT_SHA:-dev}"
BUILD_ID=$(echo "$BUILD_ID" | cut -c1-12)

sed "s/__BUILD__/${BUILD_ID}/g" sw.js > sw.js.tmp && mv sw.js.tmp sw.js

echo "service worker: CACHE_VERSION = be-${BUILD_ID}"
