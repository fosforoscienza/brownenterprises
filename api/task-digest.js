/* Brown Enterprises · riepilogo email giornaliero dei task.
 *
 * Parte alle 00:01 ora italiana. I cron di Vercel ragionano in UTC, e
 * mezzanotte in Italia e' alle 23:00 UTC d'inverno e alle 22:00 d'estate:
 * vercel.json la lancia a tutte e due le ore (?utc=22, ?utc=23: solo per
 * distinguerle nei log) e la funzione lavora solo
 * quando a Roma e' fra mezzanotte e l'una. Per ogni persona
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

var mail = require("./_lib/mail");
var esc = mail.esc, rpc = mail.rpc, sendMail = mail.sendMail;

/* L'ora a Roma, 0-23 */
function romeHour(date){
  return +new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Rome", hour: "2-digit", hourCycle: "h23" }).format(date);
}

var APP_URL = "https://www.brownenterprises.it/app.html";

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

var digest = module.exports = async function(req, res){
  var secret = process.env.CRON_SECRET;
  if(!secret || req.headers.authorization !== "Bearer " + secret){
    return res.status(401).json({ error: "Non autorizzato" });
  }
  /* dei due cron (vedi sopra) lavora solo quello che cade dopo mezzanotte */
  var hour = romeHour(digest.clock());
  if(hour !== 0){
    console.log("task-digest: a Roma sono le", hour, "- il riepilogo parte solo a mezzanotte");
    return res.status(200).json({ skipped: true });
  }
  var key = process.env.BE_SUPABASE_SERVICE_KEY;
  if(!mail.configured()){
    console.error("task-digest: mancano BE_SUPABASE_SERVICE_KEY, RESEND_API_KEY o BE_DIGEST_FROM");
    return res.status(500).json({ error: "Configurazione mancante" });
  }

  var rows;
  try { rows = await rpc("be_task_digest_pending", {}, key); }
  catch(err){
    console.error("task-digest: be_task_digest_pending", err && err.message);
    return res.status(502).json({ error: "Database non raggiungibile" });
  }

  var sent = 0, failed = 0;
  for(var row of Array.isArray(rows) ? rows : []){
    if(!row.email || !Array.isArray(row.events) || !row.events.length) continue;
    try {
      await sendMail(row.email, buildEmail(row));
      await rpc("be_task_digest_mark", { p_user: row.user_id, p_until: row.until }, key);
      sent++;
    } catch(err){
      /* il segno non si sposta: gli eventi tornano nel riepilogo di domani */
      console.error("task-digest: riepilogo non spedito a", row.user_id, err && err.message);
      failed++;
    }
  }
  console.log("task-digest:", sent, "spediti,", failed, "non spediti");
  return res.status(failed && !sent ? 502 : 200).json({ sent: sent, failed: failed });
};

/* L'orologio: i test lo sostituiscono */
digest.clock = function(){ return new Date(); };
digest.romeHour = romeHour;

module.exports.buildEmail = buildEmail;
module.exports.describe = describe;
