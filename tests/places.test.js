/* Test dei suggerimenti di Google Maps (api/places), con la rete simulata:
   node --test tests/*.test.js */
"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var places = require("../api/places");

var realFetch = global.fetch;
test.beforeEach(function(){ process.env.GOOGLE_MAPS_KEY = "g-key"; });
test.afterEach(function(){
  global.fetch = realFetch;
  delete process.env.GOOGLE_MAPS_KEY;
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
/* Ogni test usa un token suo: quelli gia' verificati la funzione li ricorda */
var n = 0;
function req(q, auth){
  return { method: "POST", headers: { authorization: auth === undefined ? "Bearer tok" + (++n) : auth }, body: { q: q } };
}
var GOOGLE = {
  suggestions: [
    { placePrediction: { placeId: "ChIJ1", text: { text: "Teatro dell'Aquila, Corso Cefalonia, Fermo, FM, Italia" } } },
    { placePrediction: { placeId: "ChIJ2", text: { text: "Teatro dell'Aquila, Corso Cefalonia, Fermo, FM, Italia" } } },
    { queryPrediction: { text: { text: "teatro" } } },
    { placePrediction: { placeId: "ChIJ3", text: { text: "Piazza del Popolo, Fermo, FM" } } }
  ]
};

test("places: senza accesso -> 401 e Google non viene chiamato", async function(){
  var google = 0;
  global.fetch = async function(url){
    if(/googleapis/.test(url)) google++;
    return response(401, {});
  };
  for(var a of ["", "Basic x", "Bearer sbagliato"]){
    var res = fakeRes();
    await places(req("fermo", a), res);
    assert.equal(res.code, 401);
  }
  assert.equal(google, 0);
});

test("places: metodo diverso da POST -> 405", async function(){
  var res = fakeRes();
  await places({ method: "GET", headers: {}, query: { q: "fermo" } }, res);
  assert.equal(res.code, 405);
});

test("places: senza chiave -> 503, cosi' l'app usa OpenStreetMap", async function(){
  delete process.env.GOOGLE_MAPS_KEY;
  global.fetch = async function(){ return response(200, {}); };
  var res = fakeRes();
  await places(req("fermo"), res);
  assert.equal(res.code, 503);
});

test("places: ricerca troppo corta -> 400", async function(){
  global.fetch = async function(){ return response(200, {}); };
  var res = fakeRes();
  await places(req("fe"), res);
  assert.equal(res.code, 400);
});

test("places: chiede a Google con la chiave e restituisce testo e place_id", async function(){
  var calls = [];
  global.fetch = async function(url, opts){
    calls.push({ url: url, opts: opts });
    return /googleapis/.test(url) ? response(200, GOOGLE) : response(200, { id: "u1" });
  };
  var res = fakeRes();
  await places(req("  teatro aquila "), res);
  assert.equal(res.code, 200);
  assert.equal(res.headers["cache-control"], "no-store");
  assert.deepEqual(res.body.places, [
    { label: "Teatro dell'Aquila, Corso Cefalonia, Fermo, FM", place_id: "ChIJ1" },
    { label: "Piazza del Popolo, Fermo, FM", place_id: "ChIJ3" }
  ]);
  var g = calls[1];
  assert.match(g.url, /places:autocomplete$/);
  assert.equal(g.opts.headers["X-Goog-Api-Key"], "g-key");
  var body = JSON.parse(g.opts.body);
  assert.equal(body.input, "teatro aquila");
  assert.equal(body.languageCode, "it");
});

test("places: un token gia' verificato non torna da Supabase", async function(){
  var auth = 0;
  global.fetch = async function(url){
    if(/auth\/v1\/user/.test(url)){ auth++; return response(200, {}); }
    return response(200, GOOGLE);
  };
  for(var i = 0; i < 3; i++){
    var res = fakeRes();
    await places(req("fermo", "Bearer stesso"), res);
    assert.equal(res.code, 200);
  }
  assert.equal(auth, 1);
});

test("places: errore di Google (chiave o quota) -> 502", async function(){
  global.fetch = async function(url){
    return /googleapis/.test(url) ? response(403, { error: {} }) : response(200, {});
  };
  var res = fakeRes();
  await places(req("fermo"), res);
  assert.equal(res.code, 502);
  assert.match(res.body.error, /403/);
});

test("places: senza filtro dei campi, Google restituisce tutta la previsione", async function(){
  var headers;
  global.fetch = async function(url, opts){
    if(/googleapis/.test(url)){ headers = opts.headers; return response(200, {}); }
    return response(200, {});
  };
  var res = fakeRes();
  await places(req("fermo"), res);
  assert.equal(res.code, 200);
  assert.deepEqual(res.body.places, []);
  assert.ok(!("X-Goog-FieldMask" in headers));
});
