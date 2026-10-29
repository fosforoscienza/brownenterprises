/* Brown Enterprises · riepilogo email giornaliero dei task.
 *
 * Lo lancia ogni mattina il cron di Vercel (vercel.json). Per ogni persona
 * che ha indicato un indirizzo in be_notify_prefs, la funzione SQL
 * be_task_digest_pending (sql/task.sql) restituisce quello che e' successo
 * dall'ultimo invio ai task di cui e' destinataria; qui diventa una mail,
 * spedita con Resend. Dopo l'invio be_task_digest_mark sposta in avanti il
 * segno, cosi' un evento non arriva due volte.
 *
 * Variabili d'ambiente su Vercel:
 *   CRON_SECRET               Vercel lo manda come "Authorization: Bearer ..."
 *   BE_SUPABASE_SERVICE_KEY   chiave service_role di Supabase (segreta)
 *   RESEND_API_KEY            chiave di Resend
 *   BE_DIGEST_FROM            mittente, es. "Mario <task@brownenterprises.it>" */

"use strict";

var SUPABASE_URL = process.env.BE_SUPABASE_URL || "https://api.fosforo.info";
var APP_URL = "https://www.brownenterprises.it/app.html";

function esc(t){
  return String(t == null ? "" : t)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/* Una riga per evento, in testo semplice */
function describe(e){
  var who = e.actor || "Qualcuno";
  var t = "«" + (e.title || "senza titolo") + "»";
  var d = e.detail || {};
  switch(e.kind){
    case "assigned":   return who + " ti ha assegnato " + t;
    case "unassigned": return who + " ti ha tolto da " + t;
    case "moved":      return who + " ha spostato " + t + (d.from && d.to ? " da " + d.from + " a " + d.to : "");
    case "deleted":    return who + " ha eliminato " + t;
    case "updated":
      if(d.old_title) return who + " ha rinominato «" + d.old_title + "» in " + t;
      return who + " ha modificato " + t + (d.fields && d.fields.length ? " (" + d.fields.join(", ") + ")" : "");
    default:           return who + " ha aggiornato " + t;
  }
}

function byProject(events){
  var groups = [], index = {};
  events.forEach(function(e){
    var k = e.project || "Senza progetto";
    if(!(k in index)){ index[k] = groups.length; groups.push({ project: k, events: [] }); }
    groups[index[k]].events.push(e);
  });
  return groups;
}

function buildEmail(row){
  var events = Array.isArray(row.events) ? row.events : [];
  var n = events.length;
  var subject = "Mario · " + n + " novità sui tuoi task";
  var hello = row.display_name ? "Ciao " + row.display_name + "," : "Ciao,";
  var intro = n === 1 ? "ecco cosa è successo a un task che ti riguarda."
                      : "ecco cosa è successo ai task che ti riguardano.";
  var groups = byProject(events);

  var text = hello + "\n" + intro + "\n\n" + groups.map(function(g){
    return g.project + "\n" + g.events.map(function(e){ return "  • " + describe(e); }).join("\n");
  }).join("\n\n") + "\n\nApri Mario: " + APP_URL + "\n";

  var html =
    '<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1d2125;max-width:560px">' +
      '<p>' + esc(hello) + '<br>' + esc(intro) + '</p>' +
      groups.map(function(g){
        return '<h3 style="font-size:13px;text-transform:uppercase;letter-spacing:.4px;color:#626f86;margin:22px 0 6px">' + esc(g.project) + '</h3>' +
          '<ul style="margin:0;padding-left:18px">' +
          g.events.map(function(e){ return '<li style="margin:3px 0">' + esc(describe(e)) + '</li>'; }).join("") +
          '</ul>';
      }).join("") +
      '<p style="margin-top:26px"><a href="' + APP_URL + '" style="color:#0c66e4">Apri Mario</a></p>' +
      '<p style="font-size:12px;color:#8590a2">Ricevi questa mail perché hai attivato il riepilogo dei task. Per disattivarlo, in Mario clicca sulla tua iniziale in alto a destra.</p>' +
    '</div>';

  return { subject: subject, text: text, html: html };
}

async function rpc(name, body, key){
  var r = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      "apikey": key,
      "Authorization": "Bearer " + key,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(body || {}),
    signal: AbortSignal.timeout(15000)
  });
  if(!r.ok) throw new Error(name + ": HTTP " + r.status);
  return r.status === 204 ? null : r.json();
}

async function sendMail(to, mail){
  var r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": "Bearer " + process.env.RESEND_API_KEY,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      from: process.env.BE_DIGEST_FROM, to: [to],
      subject: mail.subject, text: mail.text, html: mail.html
    }),
    signal: AbortSignal.timeout(15000)
  });
  if(!r.ok) throw new Error("Resend: HTTP " + r.status);
}

module.exports = async function(req, res){
  var secret = process.env.CRON_SECRET;
  if(!secret || req.headers.authorization !== "Bearer " + secret){
    return res.status(401).json({ error: "Non autorizzato" });
  }
  var key = process.env.BE_SUPABASE_SERVICE_KEY;
  if(!key || !process.env.RESEND_API_KEY || !process.env.BE_DIGEST_FROM){
    return res.status(500).json({ error: "Configurazione mancante" });
  }

  var rows;
  try { rows = await rpc("be_task_digest_pending", {}, key); }
  catch(_){ return res.status(502).json({ error: "Database non raggiungibile" }); }

  var sent = 0, failed = 0;
  for(var row of Array.isArray(rows) ? rows : []){
    if(!row.email || !Array.isArray(row.events) || !row.events.length) continue;
    try {
      await sendMail(row.email, buildEmail(row));
      await rpc("be_task_digest_mark", { p_user: row.user_id, p_until: row.until }, key);
      sent++;
    } catch(_){
      /* il segno non si sposta: gli eventi tornano nel riepilogo di domani */
      failed++;
    }
  }
  return res.status(failed && !sent ? 502 : 200).json({ sent: sent, failed: failed });
};

module.exports.buildEmail = buildEmail;
module.exports.describe = describe;
