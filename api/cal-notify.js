/* Brown Enterprises · «Chi fa cosa»: la mail a chi riceve un impegno.
 *
 *   POST /api/cal-notify   Authorization: Bearer <access token Supabase>
 *   GET  /api/cal-notify   Authorization: Bearer <CRON_SECRET>  (cron di Vercel)
 *
 * Quando qualcuno crea un impegno per altre persone, o le aggiunge, il
 * trigger di sql/calendario_email.sql mette in coda una riga per persona.
 * Qui la coda si svuota: be_cal_notify_claim la prende in carico raggruppata
 * per persona, ognuna riceve una mail sola con tutti i suoi impegni nuovi e
 * be_cal_notify_done segna l'invio (o rimette in coda se Resend non
 * risponde). La chiama il browser subito dopo aver salvato; il cron di ogni
 * mattina raccoglie quello che e' rimasto indietro. Non riceve dati: quello
 * che finisce nella mail viene solo dal database.
 *
 * Variabili d'ambiente su Vercel: le stesse di api/task-digest
 * (CRON_SECRET, BE_SUPABASE_SERVICE_KEY, RESEND_API_KEY, BE_DIGEST_FROM). */

"use strict";

var mail = require("./_lib/mail");
var esc = mail.esc, rpc = mail.rpc, sendMail = mail.sendMail;

var SUPABASE_KEY = process.env.BE_SUPABASE_ANON_KEY || "sb_publishable_U5-k5ljKyv3Edwlyt3brS5_0DLCA7Kq";
var CAL_URL = "https://www.brownenterprises.it/app.html?apri=chi-fa-cosa";

var GIORNI = ["domenica","lunedì","martedì","mercoledì","giovedì","venerdì","sabato"];
var MESI = ["gennaio","febbraio","marzo","aprile","maggio","giugno","luglio","agosto","settembre","ottobre","novembre","dicembre"];
var HALF = { am: "mattina", pm: "pomeriggio", day: "tutto il giorno" };

/* "2026-11-03" -> "martedì 3 novembre 2026" (senza anno se year e' false) */
function longDate(s, year){
  var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s || ""));
  if(!m) return String(s || "");
  var d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return GIORNI[d.getUTCDay()] + " " + d.getUTCDate() + " " + MESI[d.getUTCMonth()] +
         (year === false ? "" : " " + d.getUTCFullYear());
}

/* La fascia, con l'orario se c'e': "mattina, 09:30–12:00" */
function slot(e){
  var h = HALF[e.half] || "";
  if(!e.start_time) return h;
  var t = e.start_time + (e.end_time && e.end_time !== e.start_time ? "–" + e.end_time : "");
  return h ? h + ", " + t : t;
}

function sameYear(a, b){ return String(a).slice(0, 4) === String(b).slice(0, 4); }

/* Quando: un giorno, piu' giorni (ferie) o le date di una serie */
function when(items){
  var e = items[0];
  if(items.length > 1){
    var first = items[0].date, last = items[items.length - 1].date;
    var days = e.recur && Array.isArray(e.recur.days) ? e.recur.days.slice().sort() : [];
    var every = days.length
      ? "ogni " + days.map(function(n){ return GIORNI[n % 7]; }).join(", ").replace(/, ([^,]*)$/, " e $1") + ", "
      : "";
    return every + "dal " + longDate(first, !sameYear(first, last)) + " al " + longDate(last) +
           " (" + items.length + " date)" + (slot(e) ? " · " + slot(e) : "");
  }
  if(e.date_end && e.date_end > e.date){
    return "dal " + longDate(e.date, !sameYear(e.date, e.date_end)) + " al " + longDate(e.date_end);
  }
  return longDate(e.date) + (slot(e) ? " · " + slot(e) : "");
}

/* Gli impegni di una serie arrivano insieme: diventano una voce sola */
function groupSeries(events){
  var groups = [], index = {};
  events.forEach(function(e){
    var k = e.series_id ? "s:" + e.series_id : "e:" + e.id;
    if(!(k in index)){ index[k] = groups.length; groups.push([]); }
    groups[index[k]].push(e);
  });
  return groups;
}

/* Le righe di dettaglio di una voce: [etichetta, testo] */
function details(items, me){
  var e = items[0];
  var rows = [["Quando", when(items)]];
  if(e.location) rows.push(["Dove", e.location]);
  if(e.project) rows.push(["Progetto", e.project]);
  var others = (e.persons || []).filter(function(p){ return String(p).toLowerCase() !== String(me || "").toLowerCase(); });
  if(others.length) rows.push(["Con", others.join(", ")]);
  if(e.notes) rows.push(["Note", e.notes]);
  rows.push([e.change === "added" ? "Aggiunto da" : "Creato da", e.actor || "qualcuno"]);
  return rows;
}

function heading(e){
  return "«" + (e.title || "senza titolo") + "»" + (e.status === "da_confermare" ? " (da confermare)" : "");
}

function buildEmail(row){
  var events = Array.isArray(row.events) ? row.events : [];
  var groups = groupSeries(events);
  var n = groups.length;
  var actors = events.map(function(e){ return e.actor; })
    .filter(function(a, i, all){ return a && all.indexOf(a) === i; });
  var who = actors.length === 1 ? actors[0] : "";

  var subject = n === 1
    ? "Chi fa cosa · " + (who || "Qualcuno") + " ti ha assegnato " + heading(groups[0][0])
    : "Chi fa cosa · " + n + " nuovi impegni per te";
  var hello = row.display_name ? "Ciao " + row.display_name + "," : "Ciao,";
  var intro = (who ? who + " ti ha assegnato " : "ti hanno assegnato ") +
              (n === 1 ? "un impegno" : n + " impegni") + " in «Chi fa cosa».";

  var text = hello + "\n" + intro + "\n\n" + groups.map(function(items){
    return heading(items[0]) + "\n" + details(items, row.display_name).map(function(d){
      return "  " + d[0] + ": " + String(d[1]).replace(/\n/g, "\n    ");
    }).join("\n");
  }).join("\n\n") + "\n\nApri Chi fa cosa: " + CAL_URL + "\n";

  var html =
    '<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1d2125;max-width:560px">' +
      '<p>' + esc(hello) + '<br>' + esc(intro) + '</p>' +
      groups.map(function(items){
        return '<h3 style="font-size:16px;margin:22px 0 6px">' + esc(heading(items[0])) + '</h3>' +
          '<table style="border-collapse:collapse;font-size:14px">' +
          details(items, row.display_name).map(function(d){
            return '<tr><td style="color:#626f86;padding:2px 12px 2px 0;vertical-align:top;white-space:nowrap">' + esc(d[0]) + '</td>' +
                   '<td style="padding:2px 0">' + esc(d[1]).replace(/\n/g, "<br>") + '</td></tr>';
          }).join("") +
          '</table>';
      }).join("") +
      '<p style="margin-top:26px"><a href="' + CAL_URL + '" style="color:#0c66e4">Apri Chi fa cosa</a></p>' +
      '<p style="font-size:12px;color:#8590a2">Ricevi questa mail perché qualcuno ti ha assegnato un impegno. Per non riceverla più, in Mario clicca sulla tua iniziale in alto a destra.</p>' +
    '</div>';

  return { subject: subject, text: text, html: html };
}

/* Il cron presenta il suo segreto, il browser il token di chi e' collegato */
async function allowed(req){
  var auth = String(req.headers.authorization || "");
  var secret = process.env.CRON_SECRET;
  if(secret && auth === "Bearer " + secret) return true;
  if(req.method !== "POST" || !/^Bearer \S+$/.test(auth)) return false;
  try {
    var r = await fetch(mail.SUPABASE_URL + "/auth/v1/user", {
      headers: { "apikey": SUPABASE_KEY, "Authorization": auth },
      signal: AbortSignal.timeout(8000)
    });
    return r.ok;
  } catch(_){ return false; }
}

module.exports = async function(req, res){
  res.setHeader("Cache-Control", "no-store");
  if(req.method !== "POST" && req.method !== "GET"){
    res.setHeader("Allow", "GET, POST");
    return res.status(405).json({ error: "Metodo non consentito" });
  }
  if(!(await allowed(req))) return res.status(401).json({ error: "Non autorizzato" });
  if(!mail.configured()) return res.status(500).json({ error: "Configurazione mancante" });
  var key = process.env.BE_SUPABASE_SERVICE_KEY;

  var rows;
  try { rows = await rpc("be_cal_notify_claim", {}, key); }
  catch(_){ return res.status(502).json({ error: "Database non raggiungibile" }); }

  var sent = 0, failed = 0;
  for(var row of Array.isArray(rows) ? rows : []){
    var ids = Array.isArray(row.ids) ? row.ids : [];
    if(!ids.length) continue;
    var ok = false;
    try {
      if(row.email && Array.isArray(row.events) && row.events.length){
        await sendMail(row.email, buildEmail(row));
        ok = true;
      }
    } catch(_){}
    try { await rpc("be_cal_notify_done", { p_ids: ids, p_sent: ok }, key); } catch(_){}
    /* non spedite: tornano in coda per il prossimo giro */
    if(ok) sent++; else failed++;
  }
  return res.status(failed && !sent ? 502 : 200).json({ sent: sent, failed: failed });
};

module.exports.buildEmail = buildEmail;
module.exports.when = when;
