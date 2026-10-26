/* Test di api/_lib/ics.js: node --test tests/ */
"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var ics = require("../api/_lib/ics");

function cal(body){
  return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + body.trim().split("\n").map(function(l){ return l.trim(); }).join("\r\n") + "\r\nEND:VCALENDAR\r\n";
}
function parse(body, from, to){ return ics.parseIcs(cal(body), from || "2026-01-01", to || "2027-12-31"); }
function dates(list){ return list.map(function(e){ return e.date + (e.start ? " " + e.start : ""); }); }

/* ------------------------------------------------------------------ */
/* lettura: orari e fusi */

test("evento con TZID Europe/Rome resta all'ora indicata", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:a
    DTSTART;TZID=Europe/Rome:20261027T100000
    DTEND;TZID=Europe/Rome:20261027T113000
    SUMMARY:Dentista
    END:VEVENT`);
  assert.equal(out.length, 1);
  assert.deepEqual([out[0].date, out[0].start, out[0].end, out[0].allDay], ["2026-10-27", "10:00", "11:30", false]);
});

test("orari UTC convertiti in ora di Roma, estate e inverno", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:s
    DTSTART:20260715T080000Z
    DTEND:20260715T090000Z
    SUMMARY:Estate
    END:VEVENT
    BEGIN:VEVENT
    UID:w
    DTSTART:20261215T080000Z
    DTEND:20261215T090000Z
    SUMMARY:Inverno
    END:VEVENT`);
  assert.deepEqual(dates(out), ["2026-07-15 10:00", "2026-12-15 09:00"]);
});

test("altro fuso (New York) convertito in ora di Roma", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:ny
    DTSTART;TZID=America/New_York:20260310T090000
    DTEND;TZID=America/New_York:20260310T100000
    SUMMARY:Call
    END:VEVENT`);
  // 10 marzo: New York gia' in ora legale (UTC-4), Roma ancora no (UTC+1)
  assert.deepEqual([out[0].start, out[0].end], ["14:00", "15:00"]);
});

test("TZID sconosciuto: si assume Roma invece di fallire", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:x
    DTSTART;TZID=Fuso/Inventato:20261027T100000
    DTEND;TZID=Fuso/Inventato:20261027T110000
    SUMMARY:X
    END:VEVENT`);
  assert.equal(out[0].start, "10:00");
});

test("evento a cavallo del cambio d'ora (25 ottobre 2026)", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:dst
    DTSTART:20261025T000000Z
    DTEND:20261025T030000Z
    SUMMARY:Notte
    END:VEVENT`);
  // 00:00Z = 02:00 CEST, 03:00Z = 04:00 CET: tre ore reali
  assert.deepEqual([out[0].date, out[0].start, out[0].end], ["2026-10-25", "02:00", "04:00"]);
});

test("giornata intera su piu' giorni: DTEND esclusivo", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:v
    DTSTART;VALUE=DATE:20261102
    DTEND;VALUE=DATE:20261105
    SUMMARY:Viaggio
    END:VEVENT`);
  assert.deepEqual([out[0].date, out[0].dateEnd, out[0].allDay], ["2026-11-02", "2026-11-04", true]);
});

test("giornata intera di un giorno solo, anche senza DTEND", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:g
    DTSTART;VALUE=DATE:20261102
    SUMMARY:Festa
    END:VEVENT`);
  assert.deepEqual([out[0].date, out[0].dateEnd], ["2026-11-02", null]);
});

test("evento notturno che passa la mezzanotte: occupa due giorni", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:n
    DTSTART;TZID=Europe/Rome:20261027T220000
    DTEND;TZID=Europe/Rome:20261028T020000
    SUMMARY:Concerto
    END:VEVENT`);
  assert.deepEqual([out[0].date, out[0].dateEnd, out[0].start, out[0].end], ["2026-10-27", "2026-10-28", "22:00", "02:00"]);
});

test("evento che finisce esattamente a mezzanotte non occupa il giorno dopo", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:m
    DTSTART;TZID=Europe/Rome:20261027T200000
    DTEND;TZID=Europe/Rome:20261028T000000
    SUMMARY:Cena
    END:VEVENT`);
  assert.equal(out[0].dateEnd, null);
});

test("DURATION al posto di DTEND", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:d
    DTSTART;TZID=Europe/Rome:20261027T090000
    DURATION:PT1H30M
    SUMMARY:Corso
    END:VEVENT`);
  assert.equal(out[0].end, "10:30");
});

/* ------------------------------------------------------------------ */
/* lettura: testo e struttura */

test("testo: virgole, punti e virgola, a capo e righe spezzate", function(){
  var out = ics.parseIcs("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:t\r\nDTSTART:20261027T080000Z\r\n" +
    "SUMMARY:Riunione\\, budget\\; anno\\nsecondo rigo con un testo lun\r\n go spezzato\r\nEND:VEVENT\r\nEND:VCALENDAR",
    "2026-01-01", "2027-01-01");
  assert.equal(out[0].title, "Riunione, budget; anno\nsecondo rigo con un testo lungo spezzato");
});

test("righe con solo \\n e parametri tra virgolette con i due punti", function(){
  var out = ics.parseIcs("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:q\nDTSTART;X-PARAM=\"a:b\";TZID=Europe/Rome:20261027T090000\nSUMMARY:Ok\nEND:VEVENT\nEND:VCALENDAR",
    "2026-01-01", "2027-01-01");
  assert.equal(out[0].start, "09:00");
});

test("gli allarmi dentro l'evento non ne sporcano i campi", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:al
    DTSTART;TZID=Europe/Rome:20261027T090000
    SUMMARY:Vero titolo
    BEGIN:VALARM
    TRIGGER:-PT15M
    SUMMARY:Titolo allarme
    DESCRIPTION:x
    END:VALARM
    END:VEVENT`);
  assert.equal(out[0].title, "Vero titolo");
});

test("annullati esclusi, provvisori segnalati", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:c
    DTSTART:20261027T080000Z
    STATUS:CANCELLED
    SUMMARY:No
    END:VEVENT
    BEGIN:VEVENT
    UID:t
    DTSTART:20261027T090000Z
    STATUS:TENTATIVE
    SUMMARY:Forse
    END:VEVENT`);
  assert.equal(out.length, 1);
  assert.equal(out[0].tentative, true);
});

test("evento senza titolo e senza UID non rompe niente", function(){
  var out = parse(`
    BEGIN:VEVENT
    DTSTART:20261027T080000Z
    END:VEVENT`);
  assert.equal(out.length, 1);
  assert.equal(out[0].title, "Impegno");
  assert.ok(out[0].key);
});

test("evento senza DTSTART ignorato", function(){
  assert.equal(parse(`
    BEGIN:VEVENT
    UID:z
    SUMMARY:Rotto
    END:VEVENT`).length, 0);
});

test("finestra: fuori dal periodo non entra, a cavallo si'", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:old
    DTSTART;VALUE=DATE:20250101
    SUMMARY:Vecchio
    END:VEVENT
    BEGIN:VEVENT
    UID:span
    DTSTART;VALUE=DATE:20261230
    DTEND;VALUE=DATE:20270105
    SUMMARY:Ponte
    END:VEVENT`, "2027-01-01", "2027-02-01");
  assert.deepEqual(out.map(function(e){ return e.uid; }), ["span"]);
});

/* ------------------------------------------------------------------ */
/* ricorrenze */

test("settimanale su piu' giorni con UNTIL, EXDATE e un'occorrenza spostata", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:r
    DTSTART;TZID=Europe/Rome:20261020T090000
    DTEND;TZID=Europe/Rome:20261020T100000
    RRULE:FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261105T235959Z
    EXDATE;TZID=Europe/Rome:20261029T090000
    SUMMARY:Palestra
    END:VEVENT
    BEGIN:VEVENT
    UID:r
    RECURRENCE-ID;TZID=Europe/Rome:20261103T090000
    DTSTART;TZID=Europe/Rome:20261103T180000
    DTEND;TZID=Europe/Rome:20261103T190000
    SUMMARY:Palestra (sera)
    END:VEVENT`);
  assert.deepEqual(dates(out), [
    "2026-10-20 09:00", "2026-10-22 09:00", "2026-10-27 09:00",
    "2026-11-03 18:00", "2026-11-05 09:00"
  ]);
});

test("settimanale ogni 2 settimane con COUNT", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:b
    DTSTART;TZID=Europe/Rome:20261005T090000
    RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=3
    SUMMARY:Quindicinale
    END:VEVENT`);
  assert.deepEqual(dates(out), ["2026-10-05 09:00", "2026-10-19 09:00", "2026-11-02 09:00"]);
});

test("COUNT conta anche le occorrenze prima della finestra", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:c
    DTSTART;TZID=Europe/Rome:20261001T090000
    RRULE:FREQ=DAILY;COUNT=5
    SUMMARY:Cinque giorni
    END:VEVENT`, "2026-10-04", "2026-12-31");
  assert.deepEqual(dates(out), ["2026-10-04 09:00", "2026-10-05 09:00"]);
});

test("giornaliera: resta alla stessa ora anche dopo il cambio d'ora", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:d
    DTSTART;TZID=Europe/Rome:20261023T090000
    RRULE:FREQ=DAILY;COUNT=4
    SUMMARY:Ogni giorno
    END:VEVENT`);
  assert.deepEqual(dates(out), ["2026-10-23 09:00", "2026-10-24 09:00", "2026-10-25 09:00", "2026-10-26 09:00"]);
});

test("mensile: primo lunedi', ultimo venerdi', giorno del mese", function(){
  var first = parse(`
    BEGIN:VEVENT
    UID:m1
    DTSTART;TZID=Europe/Rome:20260105T183000
    RRULE:FREQ=MONTHLY;BYDAY=1MO;COUNT=3
    SUMMARY:Primo lunedi
    END:VEVENT`);
  assert.deepEqual(dates(first), ["2026-01-05 18:30", "2026-02-02 18:30", "2026-03-02 18:30"]);
  var last = parse(`
    BEGIN:VEVENT
    UID:m2
    DTSTART;TZID=Europe/Rome:20260130T090000
    RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3
    SUMMARY:Ultimo venerdi
    END:VEVENT`);
  assert.deepEqual(dates(last), ["2026-01-30 09:00", "2026-02-27 09:00", "2026-03-27 09:00"]);
  var day = parse(`
    BEGIN:VEVENT
    UID:m3
    DTSTART;VALUE=DATE:20260115
    RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=2
    SUMMARY:Il 15
    END:VEVENT`);
  assert.deepEqual(dates(day), ["2026-01-15", "2026-02-15"]);
});

test("annuale (compleanno) e RDATE aggiuntive", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:y
    DTSTART;VALUE=DATE:20240310
    RRULE:FREQ=YEARLY
    RDATE;VALUE=DATE:20260601
    SUMMARY:Compleanno
    END:VEVENT`, "2026-01-01", "2027-12-31");
  assert.deepEqual(dates(out), ["2026-03-10", "2026-06-01", "2027-03-10"]);
});

test("ricorrenza senza fine limitata alla finestra (niente cicli infiniti)", function(){
  var t0 = Date.now();
  var out = parse(`
    BEGIN:VEVENT
    UID:inf
    DTSTART;TZID=Europe/Rome:20000101T090000
    RRULE:FREQ=DAILY
    SUMMARY:Da sempre
    END:VEVENT`, "2026-10-01", "2026-10-31");
  assert.equal(out.length, 31);
  assert.ok(Date.now() - t0 < 2000);
});

test("chiavi uniche per ogni occorrenza", function(){
  var out = parse(`
    BEGIN:VEVENT
    UID:k
    DTSTART;TZID=Europe/Rome:20261020T090000
    RRULE:FREQ=DAILY;COUNT=30
    SUMMARY:K
    END:VEVENT`);
  assert.equal(new Set(out.map(function(e){ return e.key; })).size, 30);
});

/* ------------------------------------------------------------------ */
/* scrittura */

function row(o){
  return Object.assign({ id: "e1", date: "2026-10-27", date_end: null, half: "am", start_time: null, end_time: null,
    title: "Lab", persons: ["Alessandro"], kind: "lavoro", status: "confermato", project_name: null, notes: null,
    updated_at: "2026-10-26T10:00:00Z" }, o);
}
function vevents(text){ return text.split("BEGIN:VEVENT").slice(1); }

test("il file e' valido: CRLF, intestazioni, fuso, righe <= 75 byte", function(){
  var out = ics.buildIcs([row({ title: "Un titolo lunghissimo con accenti àèìòù e ancora testo per superare il limite della riga" })]);
  assert.ok(out.startsWith("BEGIN:VCALENDAR\r\n"));
  assert.ok(out.endsWith("END:VCALENDAR\r\n"));
  assert.ok(/\r\nBEGIN:VTIMEZONE\r\nTZID:Europe\/Rome\r\n/.test(out));
  assert.ok(!/[^\r]\n/.test(out), "solo CRLF");
  out.split("\r\n").forEach(function(l){ assert.ok(Buffer.byteLength(l) <= 75, "riga troppo lunga: " + l); });
});

test("mezza giornata senza orario: 9-13 e 14.30-18.30", function(){
  var out = ics.buildIcs([row({ id: "a", half: "am" }), row({ id: "p", half: "pm" })]);
  var ev = vevents(out);
  assert.ok(ev[0].includes("DTSTART;TZID=Europe/Rome:20261027T090000"));
  assert.ok(ev[0].includes("DTEND;TZID=Europe/Rome:20261027T130000"));
  assert.ok(ev[1].includes("DTSTART;TZID=Europe/Rome:20261027T143000"));
  assert.ok(ev[1].includes("DTEND;TZID=Europe/Rome:20261027T183000"));
});

test("orario solo d'inizio: un'ora di durata", function(){
  var ev = vevents(ics.buildIcs([row({ start_time: "15:30" })]))[0];
  assert.ok(ev.includes("DTEND;TZID=Europe/Rome:20261027T163000"));
});

test("tutto il giorno e ferie su piu' giorni: date con fine esclusiva", function(){
  var out = ics.buildIcs([
    row({ id: "d", half: "day" }),
    row({ id: "f", kind: "ferie", title: "Ferie", half: "day", date: "2026-12-24", date_end: "2027-01-06" })
  ]);
  var ev = vevents(out);
  assert.ok(ev[0].includes("DTSTART;VALUE=DATE:20261027") && ev[0].includes("DTEND;VALUE=DATE:20261028"));
  assert.ok(ev[1].includes("DTSTART;VALUE=DATE:20261224") && ev[1].includes("DTEND;VALUE=DATE:20270107"));
  assert.ok(ev[1].includes("SUMMARY:Ferie\r\n"));
});

test("da confermare: STATUS TENTATIVE e punti interrogativi", function(){
  var ev = vevents(ics.buildIcs([row({ status: "da_confermare" })]))[0];
  assert.ok(ev.includes("STATUS:TENTATIVE"));
  assert.ok(ev.includes("SUMMARY:? Lab ?"));
});

test("extra fosforo e progetto nella descrizione, testo con escape", function(){
  var out = ics.buildIcs([
    row({ id: "x", kind: "extra", title: "Dentista" }),
    row({ id: "l", title: "Riunione, budget; ok", project_name: "Galilei", persons: ["Alessandro", "Luca"], notes: "riga1\nriga2" })
  ]);
  var ev = vevents(out);
  assert.ok(ev[0].includes("SUMMARY:Extra fosforo · Dentista"));
  var unfolded = ev[1].replace(/\r\n /g, "");
  assert.ok(unfolded.includes("SUMMARY:Riunione\\, budget\\; ok"));
  assert.ok(unfolded.includes("DESCRIPTION:Progetto: Galilei\\nCon: Alessandro\\, Luca\\nriga1\\nriga2"));
  assert.ok(unfolded.includes("CATEGORIES:Galilei"));
});

test("UID stabili e unici, DTSTAMP in UTC", function(){
  var ev = vevents(ics.buildIcs([row({ id: "abc" }), row({ id: "def", updated_at: null })]));
  assert.ok(ev[0].includes("UID:abc@brownenterprises.it"));
  assert.ok(/DTSTAMP:20261026T100000Z/.test(ev[0]));
  assert.ok(/DTSTAMP:\d{8}T\d{6}Z/.test(ev[1]));
});

test("calendario vuoto e' comunque valido", function(){
  var out = ics.buildIcs([]);
  assert.ok(out.includes("BEGIN:VCALENDAR") && out.includes("END:VCALENDAR"));
  assert.equal(vevents(out).length, 0);
});

/* ------------------------------------------------------------------ */
/* andata e ritorno: quello che Mario scrive, Mario lo rilegge uguale */

test("andata e ritorno: orari, giornate intere, stato", function(){
  var rows = [
    row({ id: "1", start_time: "10:00", end_time: "11:30" }),
    row({ id: "2", half: "pm" }),
    row({ id: "3", half: "day", date: "2026-11-02", date_end: "2026-11-04" }),
    row({ id: "4", status: "da_confermare", start_time: "09:15", end_time: "09:45" }),
    row({ id: "5", date: "2026-03-29", start_time: "01:30", end_time: "03:30" })   // notte del cambio d'ora
  ];
  var back = ics.parseIcs(ics.buildIcs(rows), "2026-01-01", "2027-01-01");
  var byUid = {};
  back.forEach(function(e){ byUid[e.uid.split("@")[0]] = e; });
  assert.deepEqual([byUid["1"].start, byUid["1"].end], ["10:00", "11:30"]);
  assert.deepEqual([byUid["2"].start, byUid["2"].end], ["14:30", "18:30"]);
  assert.deepEqual([byUid["3"].date, byUid["3"].dateEnd, byUid["3"].allDay], ["2026-11-02", "2026-11-04", true]);
  assert.equal(byUid["4"].tentative, true);
  assert.equal(byUid["4"].title, "? Lab ?");
  assert.equal(byUid["5"].date, "2026-03-29");
});
