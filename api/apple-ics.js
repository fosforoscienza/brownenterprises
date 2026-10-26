/* Brown Enterprises · lettura del calendario pubblico iCloud di una persona.
 *
 *   POST /api/apple-ics   { "url": "webcal://pXX-caldav.icloud.com/published/2/..." }
 *   Authorization: Bearer <access token Supabase>
 *
 * Il browser non puo' scaricare il .ics da iCloud (manca CORS): lo fa questa
 * funzione e restituisce le occorrenze gia' in ora di Roma. Accetta solo
 * utenti collegati e solo indirizzi icloud.com, cosi' non diventa un proxy
 * aperto verso qualunque sito. */

"use strict";

var parseIcs = require("./_lib/ics").parseIcs;

var SUPABASE_URL = process.env.BE_SUPABASE_URL || "https://api.fosforo.info";
var SUPABASE_KEY = process.env.BE_SUPABASE_ANON_KEY || "sb_publishable_U5-k5ljKyv3Edwlyt3brS5_0DLCA7Kq";
var MAX_BYTES = 5 * 1024 * 1024;

function allowedUrl(raw){
  var u;
  try { u = new URL(String(raw || "").trim().replace(/^webcals?:\/\//i, "https://")); }
  catch(_){ return null; }
  if(u.protocol !== "https:") return null;
  var host = u.hostname.toLowerCase();
  if(host !== "icloud.com" && !/\.icloud\.com$/.test(host)) return null;
  return u;
}

function isoDay(offsetDays){
  var d = new Date(Date.now() + offsetDays * 86400000);
  return d.toISOString().slice(0, 10);
}

async function signedIn(req){
  var auth = String(req.headers.authorization || "");
  if(!/^Bearer \S+$/.test(auth)) return false;
  try {
    var r = await fetch(SUPABASE_URL + "/auth/v1/user", {
      headers: { "apikey": SUPABASE_KEY, "Authorization": auth },
      signal: AbortSignal.timeout(8000)
    });
    return r.ok;
  } catch(_){ return false; }
}

/* Segue i redirect a mano: ogni salto deve restare su icloud.com */
async function fetchIcs(url){
  for(var hop = 0; hop < 4; hop++){
    var r = await fetch(url, {
      redirect: "manual",
      headers: { "Accept": "text/calendar, */*" },
      signal: AbortSignal.timeout(12000)
    });
    if(r.status >= 300 && r.status < 400 && r.headers.get("location")){
      var next = allowedUrl(new URL(r.headers.get("location"), url).toString());
      if(!next) throw new Error("redirect fuori da iCloud");
      url = next;
      continue;
    }
    if(!r.ok) throw new Error("iCloud ha risposto " + r.status);
    var len = +(r.headers.get("content-length") || 0);
    if(len > MAX_BYTES) throw new Error("calendario troppo grande");
    var text = await r.text();
    if(text.length > MAX_BYTES) throw new Error("calendario troppo grande");
    if(text.indexOf("BEGIN:VCALENDAR") < 0) throw new Error("il link non e' un calendario");
    return text;
  }
  throw new Error("troppi redirect");
}

module.exports = async function(req, res){
  res.setHeader("Cache-Control", "no-store");
  if(req.method !== "POST"){
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Metodo non consentito" });
  }
  if(!(await signedIn(req))){
    return res.status(401).json({ error: "Accesso richiesto" });
  }
  var body = req.body;
  if(typeof body === "string"){ try { body = JSON.parse(body); } catch(_){ body = {}; } }
  var url = allowedUrl(body && body.url);
  if(!url){
    return res.status(400).json({ error: "Serve il link di un calendario pubblico iCloud (webcal://…icloud.com/…)" });
  }

  var from = isoDay(-60), to = isoDay(365);
  try {
    var text = await fetchIcs(url);
    var events = parseIcs(text, from, to);
    return res.status(200).json({ from: from, to: to, events: events });
  } catch(e){
    return res.status(502).json({ error: "Non riesco a leggere il calendario: " + ((e && e.message) || "errore") });
  }
};
