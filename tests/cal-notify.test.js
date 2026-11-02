/* Test della mail di «Chi fa cosa» (api/cal-notify), con la rete simulata:
   node --test tests/*.test.js */
"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var notify = require("../api/cal-notify");

var realFetch = global.fetch;
var ENV = { CRON_SECRET: "s3cret", BE_SUPABASE_SERVICE_KEY: "service", RESEND_API_KEY: "re_x", BE_DIGEST_FROM: "Mario <task@example.it>" };
test.beforeEach(function(){ Object.assign(process.env, ENV); });
test.afterEach(function(){
  global.fetch = realFetch;
  Object.keys(ENV).forEach(function(k){ delete process.env[k]; });
});

function fakeRes(){
  var r = { code: null, headers: {}, body: null };
  r.setHeader = function(k, v){ r.headers[k.toLowerCase()] = v; };
  r.status = function(c){ r.code = c; return r; };
  r.json = function(b){ r.body = b; return r; };
  return r;
}
function response(status, body){
  return { ok: status >= 200 && status < 300, status: status, json: async function(){ return body; } };
}
function req(method, auth){ return { method: method, headers: { authorization: auth } }; }

var EVENT = {
  id: "e1", change: "created", title: "Montaggio stand", date: "2026-11-03", date_end: null,
  half: "am", start_time: "09:30", end_time: "12:00", kind: "lavoro", status: "confermato",
  project: "Fiera", location: "Teatro dell'Aquila, Fermo", notes: "Portare il trapano\ne le prolunghe",
  series_id: null, recur: null, persons: ["Luca", "Valeria"], actor: "Alessandro"
};
var ROW = { user_id: "u1", email: "luca@example.it", display_name: "Luca", ids: [7], events: [EVENT] };

/* Rete finta: registra le chiamate e risponde secondo l'indirizzo */
function network(over){
  var calls = [];
  global.fetch = async function(url, opts){
    var body = opts && opts.body ? JSON.parse(opts.body) : null;
    calls.push({ url: url, body: body, headers: (opts && opts.headers) || {} });
    for(var k in over || {}) if(new RegExp(k).test(url)) return over[k](body);
    if(/auth\/v1\/user$/.test(url)) return response(200, { id: "u2" });
    if(/be_cal_notify_claim$/.test(url)) return response(200, [ROW]);
    if(/resend\.com/.test(url)) return response(200, { id: "m1" });
    return response(204, null);
  };
  return calls;
}

test("cal-notify: senza accesso -> 401 senza toccare la coda", async function(){
  var calls = network({ "auth/v1/user$": function(){ return response(401, {}); } });
  for(var r of [req("GET", undefined), req("GET", "Bearer sbagliato"), req("POST", "Bearer tok-scaduto"), req("POST", "s3cret")]){
    var res = fakeRes();
    await notify(r, res);
    assert.equal(res.code, 401);
  }
  assert.ok(calls.every(function(c){ return !/rpc|resend/.test(c.url); }));
});

test("cal-notify: altri metodi -> 405", async function(){
  var res = fakeRes();
  await notify(req("DELETE", "Bearer s3cret"), res);
  assert.equal(res.code, 405);
});

test("cal-notify: dal browser, una mail per persona e poi segna l'invio", async function(){
  var calls = network();
  var res = fakeRes();
  await notify(req("POST", "Bearer tok"), res);
  assert.equal(res.code, 200);
  assert.deepEqual(res.body, { sent: 1, failed: 0 });
  assert.deepEqual(calls.map(function(c){ return c.url.replace(/^.*\//, ""); }),
                   ["user", "be_cal_notify_claim", "emails", "be_cal_notify_done"]);
  assert.equal(calls[0].headers.Authorization, "Bearer tok");
  assert.equal(calls[1].headers.Authorization, "Bearer service");
  assert.deepEqual(calls[2].body.to, ["luca@example.it"]);
  assert.equal(calls[2].body.subject, "Chi fa cosa · Alessandro ti ha assegnato «Montaggio stand»");
  assert.deepEqual(calls[3].body, { p_ids: [7], p_sent: true });
});

test("cal-notify: il cron entra col suo segreto, senza chiedere a Supabase chi e'", async function(){
  var calls = network();
  var res = fakeRes();
  await notify(req("GET", "Bearer s3cret"), res);
  assert.equal(res.code, 200);
  assert.ok(!calls.some(function(c){ return /auth\/v1/.test(c.url); }));
});

test("cal-notify: coda vuota -> nessuna mail", async function(){
  var calls = network({ "be_cal_notify_claim$": function(){ return response(200, []); } });
  var res = fakeRes();
  await notify(req("POST", "Bearer tok"), res);
  assert.equal(res.code, 200);
  assert.deepEqual(res.body, { sent: 0, failed: 0 });
  assert.ok(!calls.some(function(c){ return /resend/.test(c.url); }));
});

test("cal-notify: se la mail non parte le righe tornano in coda", async function(){
  var calls = network({ "resend\\.com": function(){ return response(500, {}); } });
  var res = fakeRes();
  await notify(req("POST", "Bearer tok"), res);
  assert.equal(res.code, 502);
  var done = calls.filter(function(c){ return /be_cal_notify_done$/.test(c.url); });
  assert.deepEqual(done.map(function(c){ return c.body; }), [{ p_ids: [7], p_sent: false }]);
});

test("cal-notify: senza le chiavi di Resend -> 500", async function(){
  delete process.env.RESEND_API_KEY;
  network();
  var res = fakeRes();
  await notify(req("GET", "Bearer s3cret"), res);
  assert.equal(res.code, 500);
});

test("cal-notify: la mail ha tutti i dettagli dell'impegno", function(){
  var m = notify.buildEmail(ROW);
  assert.match(m.text, /^Ciao Luca,\nAlessandro ti ha assegnato un impegno in «Chi fa cosa»\./);
  assert.match(m.text, /Quando: martedì 3 novembre 2026 · mattina, 09:30–12:00/);
  assert.match(m.text, /Dove: Teatro dell'Aquila, Fermo/);
  assert.match(m.text, /Progetto: Fiera/);
  assert.match(m.text, /Con: Valeria\n/);
  assert.match(m.text, /Note: Portare il trapano\n    e le prolunghe/);
  assert.match(m.text, /Creato da: Alessandro/);
  assert.match(m.text, /app\.html\?apri=chi-fa-cosa/);
  assert.match(m.html, /Portare il trapano<br>e le prolunghe/);
});

test("cal-notify: il testo dell'email esegue l'escape dell'HTML", function(){
  var m = notify.buildEmail({ display_name: "<b>", events: [Object.assign({}, EVENT, { title: "<script>", notes: "a & b" })] });
  assert.ok(!/<script>|<b>/.test(m.html));
  assert.match(m.html, /&lt;script&gt;/);
  assert.match(m.html, /a &amp; b/);
});

test("cal-notify: una serie diventa una voce sola, piu' impegni un oggetto al plurale", function(){
  var recur = { days: [3, 1], from: "2026-11-02", to: "2026-11-11" };
  var serie = ["2026-11-02", "2026-11-04", "2026-11-09", "2026-11-11"].map(function(d, i){
    return Object.assign({}, EVENT, { id: "s" + i, date: d, series_id: "s_1", recur: recur, start_time: null, end_time: null, half: "pm" });
  });
  var other = Object.assign({}, EVENT, { id: "e9", title: "Ferie", kind: "ferie", date: "2026-12-29", date_end: "2027-01-02",
                                         half: "day", status: "da_confermare", change: "added", actor: "Mattia" });
  var m = notify.buildEmail({ display_name: "Luca", events: serie.concat(other) });
  assert.equal(m.subject, "Chi fa cosa · 2 nuovi impegni per te");
  assert.match(m.text, /ti hanno assegnato 2 impegni/);
  assert.equal(m.text.match(/«Montaggio stand»/g).length, 1);
  assert.match(m.text, /Quando: ogni lunedì e mercoledì, dal lunedì 2 novembre al mercoledì 11 novembre 2026 \(4 date\) · pomeriggio/);
  assert.match(m.text, /«Ferie» \(da confermare\)\n  Quando: dal martedì 29 dicembre 2026 al sabato 2 gennaio 2027\n/);
  assert.match(m.text, /Aggiunto da: Mattia/);
});

test("cal-notify: le date", function(){
  assert.equal(notify.when([{ date: "2026-11-08", half: "day" }]), "domenica 8 novembre 2026 · tutto il giorno");
  assert.equal(notify.when([{ date: "2026-11-02", date_end: "2026-11-06", half: "day" }]),
               "dal lunedì 2 novembre al venerdì 6 novembre 2026");
  assert.equal(notify.when([{ date: "2026-11-02", half: "am", start_time: "10:00", end_time: "10:00" }]),
               "lunedì 2 novembre 2026 · mattina, 10:00");
});

test("cal-notify: il motivo del rifiuto di Resend finisce nei log", async function(){
  network({ "resend\\.com": function(){
    return { ok: false, status: 403, json: async function(){ return {}; },
             text: async function(){ return '{"message":"The brownenterprises.it domain is not verified"}'; } };
  } });
  var logged = [], realError = console.error;
  console.error = function(){ logged.push(Array.prototype.join.call(arguments, " ")); };
  try {
    var res = fakeRes();
    await notify(req("GET", "Bearer s3cret"), res);
    assert.equal(res.code, 502);
  } finally { console.error = realError; }
  assert.ok(logged.some(function(l){ return /HTTP 403 .*domain is not verified/.test(l); }), logged.join("\n"));
});
