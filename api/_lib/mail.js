/* Brown Enterprises · codice comune alle funzioni che spediscono email
 * (api/task-digest, api/cal-notify): chiamate alle funzioni SQL con la
 * chiave service_role e invio con Resend.
 *
 * Variabili d'ambiente su Vercel:
 *   BE_SUPABASE_SERVICE_KEY   chiave service_role di Supabase (segreta)
 *   RESEND_API_KEY            chiave di Resend
 *   BE_DIGEST_FROM            mittente, es. "Mario <task@brownenterprises.it>" */

"use strict";

var SUPABASE_URL = process.env.BE_SUPABASE_URL || "https://api.fosforo.info";

function esc(t){
  return String(t == null ? "" : t)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
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

/* Le chiavi per spedire ci sono tutte? */
function configured(){
  return !!(process.env.BE_SUPABASE_SERVICE_KEY && process.env.RESEND_API_KEY && process.env.BE_DIGEST_FROM);
}

module.exports = { SUPABASE_URL: SUPABASE_URL, esc: esc, rpc: rpc, sendMail: sendMail, configured: configured };
