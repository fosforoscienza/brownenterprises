/* Brown Enterprises · feed .ics di "Chi fa cosa" per Apple Calendar.
 *
 *   webcal://www.brownenterprises.it/api/cal-feed?t=<token>
 *
 * Apple Calendar non fa login: presenta solo il token segreto, che la
 * funzione be_cal_feed (sql/calendario.sql) traduce negli impegni di una
 * persona. La chiave anonima di Supabase e' pubblica (sta gia' nel sito). */

"use strict";

var buildIcs = require("./_lib/ics").buildIcs;

var SUPABASE_URL = process.env.BE_SUPABASE_URL || "https://api.fosforo.info";
var SUPABASE_KEY = process.env.BE_SUPABASE_ANON_KEY || "sb_publishable_U5-k5ljKyv3Edwlyt3brS5_0DLCA7Kq";

module.exports = async function(req, res){
  if(req.method !== "GET" && req.method !== "HEAD"){
    res.setHeader("Allow", "GET, HEAD");
    return res.status(405).send("Metodo non consentito");
  }
  var token = String((req.query && req.query.t) || "").replace(/\.ics$/i, "");
  if(!/^[A-Za-z0-9_-]{32,128}$/.test(token)){
    return res.status(404).send("Calendario non trovato");
  }

  var rows;
  try {
    var r = await fetch(SUPABASE_URL + "/rest/v1/rpc/be_cal_feed", {
      method: "POST",
      headers: {
        "apikey": SUPABASE_KEY,
        "Authorization": "Bearer " + SUPABASE_KEY,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ p_token: token }),
      signal: AbortSignal.timeout(10000)
    });
    if(!r.ok) return res.status(502).send("Calendario non disponibile");
    rows = await r.json();
  } catch(_){
    return res.status(502).send("Calendario non disponibile");
  }

  /* Un token sconosciuto restituisce zero righe: per Apple e' comunque
     un calendario valido, solo vuoto. */
  var ics = buildIcs(Array.isArray(rows) ? rows : [], { name: "Mario · Chi fa cosa" });

  res.setHeader("Content-Type", "text/calendar; charset=utf-8");
  res.setHeader("Content-Disposition", 'inline; filename="mario-chi-fa-cosa.ics"');
  res.setHeader("Cache-Control", "private, max-age=300");
  res.setHeader("X-Robots-Tag", "noindex");
  return res.status(200).send(req.method === "HEAD" ? "" : ics);
};
