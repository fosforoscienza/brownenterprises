/* Test delle funzioni Vercel in api/, con la rete simulata: node --test tests/*.test.js */
"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var calFeed = require("../api/cal-feed");
var appleIcs = require("../api/apple-ics");

var realFetch = global.fetch;
test.afterEach(function(){ global.fetch = realFetch; });

function fakeRes(){
  var r = { code: null, headers: {}, body: null };
  r.setHeader = function(k, v){ r.headers[k.toLowerCase()] = v; };
  r.status = function(c){ r.code = c; return r; };
  r.send = function(b){ r.body = b; return r; };
  r.json = function(b){ r.body = b; return r; };
  return r;
}
function response(status, body, headers){
  headers = headers || {};
  return {
    ok: status >= 200 && status < 300,
    status: status,
    headers: { get: function(k){ return headers[k.toLowerCase()] || null; } },
    json: async function(){ return typeof body === "string" ? JSON.parse(body) : body; },
    text: async function(){ return typeof body === "string" ? body : JSON.stringify(body); }
  };
}
var TOKEN = "a".repeat(48);
var ICS = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=Europe/Rome:20261027T100000\r\nSUMMARY:Dentista\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";

/* ------------------------------------------------------------------ */
/* cal-feed */

test("cal-feed: token assente, corto o con caratteri strani -> 404 senza chiamare Supabase", async function(){
  var called = 0;
  global.fetch = async function(){ called++; return response(200, []); };
  for(var t of [undefined, "", "abc", "a".repeat(31), "a".repeat(129), "../../etc" + "a".repeat(40), TOKEN + "'"]){
    var res = fakeRes();
    await calFeed({ method: "GET", query: { t: t } }, res);
    assert.equal(res.code, 404, "token " + t);
  }
  assert.equal(called, 0);
});

test("cal-feed: metodo diverso da GET/HEAD -> 405", async function(){
  var res = fakeRes();
  await calFeed({ method: "POST", query: { t: TOKEN } }, res);
  assert.equal(res.code, 405);
});

test("cal-feed: chiama la RPC con il token e restituisce text/calendar", async function(){
  var seen;
  global.fetch = async function(url, opts){
    seen = { url: url, opts: opts };
    return response(200, [{ id: "e1", date: "2026-10-27", half: "pm", title: "Lab", persons: ["Alessandro"], kind: "lavoro", status: "confermato" }]);
  };
  var res = fakeRes();
  await calFeed({ method: "GET", query: { t: TOKEN + ".ics" } }, res);
  assert.equal(res.code, 200);
  assert.match(seen.url, /\/rest\/v1\/rpc\/be_cal_feed$/);
  assert.equal(JSON.parse(seen.opts.body).p_token, TOKEN);
  assert.ok(seen.opts.headers.apikey);
  assert.match(res.headers["content-type"], /^text\/calendar/);
  assert.match(res.body, /SUMMARY:Lab/);
  assert.match(res.body, /DTSTART;TZID=Europe\/Rome:20261027T143000/);
});

test("cal-feed: token sconosciuto -> calendario valido ma vuoto", async function(){
  global.fetch = async function(){ return response(200, []); };
  var res = fakeRes();
  await calFeed({ method: "GET", query: { t: TOKEN } }, res);
  assert.equal(res.code, 200);
  assert.ok(!/BEGIN:VEVENT/.test(res.body));
});

test("cal-feed: Supabase in errore, giu' o con risposta strana -> 502 senza crash", async function(){
  var cases = [
    async function(){ return response(500, { message: "boom" }); },
    async function(){ throw new Error("ECONNREFUSED"); },
    async function(){ return response(200, { not: "an array" }); }
  ];
  for(var i = 0; i < cases.length; i++){
    global.fetch = cases[i];
    var res = fakeRes();
    await calFeed({ method: "GET", query: { t: TOKEN } }, res);
    assert.ok(res.code === 502 || (res.code === 200 && !/BEGIN:VEVENT/.test(res.body)), "caso " + i + ": " + res.code);
  }
});

test("cal-feed: HEAD risponde senza corpo", async function(){
  global.fetch = async function(){ return response(200, []); };
  var res = fakeRes();
  await calFeed({ method: "HEAD", query: { t: TOKEN } }, res);
  assert.equal(res.code, 200);
  assert.equal(res.body, "");
});

/* ------------------------------------------------------------------ */
/* apple-ics */

/* fetch finto: la prima chiamata e' il controllo del login su Supabase */
function router(routes){
  var calls = [];
  global.fetch = async function(url, opts){
    calls.push(String(url));
    for(var i = 0; i < routes.length; i++){
      if(routes[i][0].test(String(url))) return routes[i][1](url, opts);
    }
    throw new Error("rete non prevista: " + url);
  };
  return calls;
}
var AUTH_OK = [/\/auth\/v1\/user$/, async function(){ return response(200, { id: "u1" }); }];
function req(body, auth){
  return { method: "POST", headers: { authorization: auth === undefined ? "Bearer tok" : auth }, body: body };
}

test("apple-ics: solo POST", async function(){
  var res = fakeRes();
  await appleIcs({ method: "GET", headers: {} }, res);
  assert.equal(res.code, 405);
});

test("apple-ics: senza login o con token non valido -> 401", async function(){
  router([[/\/auth\/v1\/user$/, async function(){ return response(401, {}); }]]);
  for(var a of ["", "Basic xyz", "Bearer bad"]){
    var res = fakeRes();
    await appleIcs(req({ url: "webcal://p1-caldav.icloud.com/published/2/x" }, a), res);
    assert.equal(res.code, 401, "auth " + a);
  }
});

test("apple-ics: rifiuta indirizzi che non sono iCloud (niente proxy aperto)", async function(){
  var calls = router([AUTH_OK]);
  var bad = [
    "https://evil.com/x.ics", "http://p1-caldav.icloud.com/x", "https://icloud.com.evil.com/x",
    "https://evilicloud.com/x", "file:///etc/passwd", "https://localhost/x", "https://127.0.0.1/x",
    "webcal://user:pw@evil.com/x", "", null, 42
  ];
  for(var u of bad){
    var res = fakeRes();
    await appleIcs(req({ url: u }), res);
    assert.equal(res.code, 400, "url " + u);
  }
  assert.ok(calls.every(function(c){ return /auth\/v1\/user/.test(c); }), "nessun download");
});

test("apple-ics: webcal:// diventa https:// e il calendario viene letto", async function(){
  var calls = router([AUTH_OK, [/icloud\.com/, async function(){ return response(200, ICS); }]]);
  var res = fakeRes();
  await appleIcs(req({ url: "webcal://p52-caldav.icloud.com/published/2/abc" }), res);
  assert.equal(res.code, 200);
  assert.equal(calls[1], "https://p52-caldav.icloud.com/published/2/abc");
  assert.equal(res.body.events.length, 1);
  assert.equal(res.body.events[0].title, "Dentista");
  assert.match(res.body.from, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(res.headers["cache-control"], "no-store");
});

test("apple-ics: corpo come stringa JSON", async function(){
  router([AUTH_OK, [/icloud\.com/, async function(){ return response(200, ICS); }]]);
  var res = fakeRes();
  await appleIcs(req(JSON.stringify({ url: "https://p1-caldav.icloud.com/published/2/x" })), res);
  assert.equal(res.code, 200);
});

test("apple-ics: segue i redirect dentro iCloud", async function(){
  var calls = router([AUTH_OK,
    [/p1-caldav/, async function(){ return response(301, "", { location: "https://p77-caldav.icloud.com/published/2/x" }); }],
    [/p77-caldav/, async function(){ return response(200, ICS); }]]);
  var res = fakeRes();
  await appleIcs(req({ url: "webcal://p1-caldav.icloud.com/published/2/x" }), res);
  assert.equal(res.code, 200);
  assert.equal(calls.length, 3);
});

test("apple-ics: redirect verso fuori da iCloud bloccato", async function(){
  var calls = router([AUTH_OK,
    [/icloud\.com/, async function(){ return response(302, "", { location: "https://evil.com/steal" }); }]]);
  var res = fakeRes();
  await appleIcs(req({ url: "webcal://p1-caldav.icloud.com/published/2/x" }), res);
  assert.equal(res.code, 502);
  assert.ok(!calls.some(function(c){ return /evil/.test(c); }));
});

test("apple-ics: troppi redirect, 404, file non calendario, file enorme -> 502", async function(){
  var cases = [
    async function(u){ return response(302, "", { location: String(u) + "x" }); },
    async function(){ return response(404, "not found"); },
    async function(){ return response(200, "<html>login</html>"); },
    async function(){ return response(200, ICS, { "content-length": String(50 * 1024 * 1024) }); },
    async function(){ throw new Error("timeout"); }
  ];
  for(var i = 0; i < cases.length; i++){
    router([AUTH_OK, [/icloud\.com/, cases[i]]]);
    var res = fakeRes();
    await appleIcs(req({ url: "https://p1-caldav.icloud.com/published/2/x" }), res);
    assert.equal(res.code, 502, "caso " + i);
    assert.match(res.body.error, /Non riesco a leggere il calendario/);
  }
});

test("apple-ics: Supabase irraggiungibile durante il controllo login -> 401, non crash", async function(){
  router([[/\/auth\/v1\/user$/, async function(){ throw new Error("down"); }]]);
  var res = fakeRes();
  await appleIcs(req({ url: "https://p1-caldav.icloud.com/published/2/x" }), res);
  assert.equal(res.code, 401);
});
