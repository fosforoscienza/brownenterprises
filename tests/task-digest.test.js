/* Test del riepilogo email dei task (api/task-digest), con la rete simulata:
   node --test tests/*.test.js */
"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var digest = require("../api/task-digest");

var realFetch = global.fetch;
var ENV = { CRON_SECRET: "s3cret", BE_SUPABASE_SERVICE_KEY: "service", RESEND_API_KEY: "re_x", BE_DIGEST_FROM: "Mario <task@example.it>" };
test.beforeEach(function(){ Object.assign(process.env, ENV); });
test.afterEach(function(){
  global.fetch = realFetch;
  Object.keys(ENV).forEach(function(k){ delete process.env[k]; });
});

function fakeRes(){
  var r = { code: null, body: null };
  r.setHeader = function(){};
  r.status = function(c){ r.code = c; return r; };
  r.json = function(b){ r.body = b; return r; };
  r.send = r.json;
  return r;
}
function response(status, body){
  return { ok: status >= 200 && status < 300, status: status, json: async function(){ return body; } };
}
function req(auth){ return { method: "GET", headers: { authorization: auth } }; }

var ROW = {
  user_id: "u1", email: "ale@example.it", display_name: "Alessandro", until: "2026-10-29T06:00:00Z",
  events: [
    { kind: "assigned", title: "Preventivo", project: "Sito", actor: "Luca", detail: {} },
    { kind: "moved", title: "Preventivo", project: "Sito", actor: "Luca", detail: { from: "To Do", to: "In Progress" } },
    { kind: "updated", title: "Logo", project: "Brand", actor: "", detail: { fields: ["date"] } }
  ]
};

test("task-digest: senza il segreto del cron -> 401 senza chiamare nessuno", async function(){
  var called = 0;
  global.fetch = async function(){ called++; return response(200, []); };
  for(var a of [undefined, "", "Bearer sbagliato", "s3cret"]){
    var res = fakeRes();
    await digest(req(a), res);
    assert.equal(res.code, 401);
  }
  assert.equal(called, 0);
});

test("task-digest: manda una mail per persona e poi segna l'invio", async function(){
  var calls = [];
  global.fetch = async function(url, opts){
    calls.push({ url: url, body: JSON.parse(opts.body), headers: opts.headers });
    if(/be_task_digest_pending$/.test(url)) return response(200, [ROW, { user_id: "u2", email: "x@y.it", events: [] }]);
    if(/resend\.com/.test(url)) return response(200, { id: "m1" });
    return response(204, null);
  };
  var res = fakeRes();
  await digest(req("Bearer s3cret"), res);
  assert.equal(res.code, 200);
  assert.deepEqual(res.body, { sent: 1, failed: 0 });
  assert.equal(calls.length, 3);
  assert.equal(calls[0].headers.Authorization, "Bearer service");
  assert.deepEqual(calls[1].body.to, ["ale@example.it"]);
  assert.match(calls[1].body.subject, /3 novità/);
  assert.match(calls[1].body.text, /Luca ti ha assegnato «Preventivo»/);
  assert.match(calls[1].body.text, /da To Do a In Progress/);
  assert.match(calls[2].url, /be_task_digest_mark$/);
  assert.deepEqual(calls[2].body, { p_user: "u1", p_until: ROW.until });
});

test("task-digest: se la mail non parte il segno resta dov'era", async function(){
  var marked = 0;
  global.fetch = async function(url){
    if(/pending$/.test(url)) return response(200, [ROW]);
    if(/resend\.com/.test(url)) return response(500, {});
    marked++;
    return response(204, null);
  };
  var res = fakeRes();
  await digest(req("Bearer s3cret"), res);
  assert.equal(res.code, 502);
  assert.equal(marked, 0);
});

test("task-digest: il testo dell'email esegue l'escape dell'HTML", function(){
  var mail = digest.buildEmail({ display_name: "<b>", events: [{ kind: "deleted", title: "<script>", project: "P", actor: "A" }] });
  assert.ok(!/<script>/.test(mail.html));
  assert.match(mail.html, /&lt;script&gt;/);
  assert.match(mail.text, /A ha eliminato «<script>»/);
});

test("task-digest: descrizioni degli eventi", function(){
  assert.equal(digest.describe({ kind: "unassigned", title: "T", actor: "Ale" }), "Ale ti ha tolto da «T»");
  assert.equal(digest.describe({ kind: "updated", title: "Nuovo", actor: "Ale", detail: { fields: ["titolo"], old_title: "Vecchio" } }),
               "Ale ha rinominato «Vecchio» in «Nuovo»");
  assert.equal(digest.describe({ kind: "updated", title: "T", actor: "", detail: { fields: ["priorità", "date"] } }),
               "Qualcuno ha modificato «T» (priorità, date)");
});
