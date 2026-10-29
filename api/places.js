/* Brown Enterprises · suggerimenti di Google Maps per il luogo di un impegno.
 *
 *   POST /api/places   { "q": "teatro dell'aquila" }
 *   Authorization: Bearer <access token Supabase>
 *
 * Gira qui e non nel browser perche' la chiave di Google (GOOGLE_MAPS_KEY,
 * solo su Vercel) costa a ogni ricerca: non deve finire nel sito. Accetta
 * solo utenti collegati. Restituisce il testo da mostrare e il place_id, che
 * le condizioni di Google permettono di conservare; le coordinate no.
 * Senza chiave risponde 503 e l'app torna ai suggerimenti di OpenStreetMap. */

"use strict";

var SUPABASE_URL = process.env.BE_SUPABASE_URL || "https://api.fosforo.info";
var SUPABASE_KEY = process.env.BE_SUPABASE_ANON_KEY || "sb_publishable_U5-k5ljKyv3Edwlyt3brS5_0DLCA7Kq";
var GOOGLE_URL = "https://places.googleapis.com/v1/places:autocomplete";
var FIELDS = "suggestions.placePrediction.placeId,suggestions.placePrediction.text.text";

/* Si cerca mentre si scrive: un token gia' verificato vale qualche minuto,
   cosi' non serve chiedere a Supabase a ogni lettera. */
var TOKEN_TTL = 5 * 60 * 1000;
var verified = new Map();

async function signedIn(req){
  var auth = String(req.headers.authorization || "");
  if(!/^Bearer \S+$/.test(auth)) return false;
  var now = Date.now();
  if((verified.get(auth) || 0) > now) return true;
  try {
    var r = await fetch(SUPABASE_URL + "/auth/v1/user", {
      headers: { "apikey": SUPABASE_KEY, "Authorization": auth },
      signal: AbortSignal.timeout(8000)
    });
    if(!r.ok) return false;
  } catch(_){ return false; }
  if(verified.size > 200) verified.clear();
  verified.set(auth, now + TOKEN_TTL);
  return true;
}

/* "Teatro dell'Aquila, Corso Cefalonia, Fermo, FM, Italia" -> senza ", Italia" */
function shortLabel(text){
  return String(text || "").replace(/,\s*Italia$/, "").trim();
}

function toPlaces(json){
  var seen = {};
  return ((json && json.suggestions) || []).map(function(s){
    var p = s.placePrediction || {};
    return { label: shortLabel(p.text && p.text.text), place_id: p.placeId || "" };
  }).filter(function(x){
    if(!x.label || !x.place_id || seen[x.label]) return false;
    seen[x.label] = 1;
    return true;
  }).slice(0, 6);
}

module.exports = async function(req, res){
  res.setHeader("Cache-Control", "no-store");
  if(req.method !== "POST"){
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Metodo non consentito" });
  }
  if(!(await signedIn(req))) return res.status(401).json({ error: "Accesso richiesto" });

  var key = process.env.GOOGLE_MAPS_KEY;
  if(!key) return res.status(503).json({ error: "Google Maps non configurato" });

  var q = String((req.body && req.body.q) || "").trim();
  if(q.length < 3 || q.length > 200) return res.status(400).json({ error: "Ricerca non valida" });

  var r;
  try {
    r = await fetch(GOOGLE_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask": FIELDS
      },
      body: JSON.stringify({
        input: q,
        languageCode: "it",
        regionCode: "it",
        // vicino a Fermo i risultati vengono prima, ma si trova anche altrove
        locationBias: { circle: { center: { latitude: 43.16, longitude: 13.72 }, radius: 50000 } }
      }),
      signal: AbortSignal.timeout(8000)
    });
  } catch(_){
    return res.status(502).json({ error: "Google Maps non raggiungibile" });
  }
  if(!r.ok){
    // 403: chiave sbagliata o API non abilitata; 429: quota esaurita
    return res.status(502).json({ error: "Google Maps ha risposto " + r.status });
  }
  var json = await r.json().catch(function(){ return null; });
  return res.status(200).json({ places: toPlaces(json) });
};

module.exports.toPlaces = toPlaces;
