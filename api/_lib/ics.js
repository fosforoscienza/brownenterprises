/* Brown Enterprises · iCalendar (RFC 5545) per "Chi fa cosa".
 *
 * Due direzioni:
 *  - parseIcs(): legge il calendario pubblico iCloud di una persona e lo
 *    appiattisce in occorrenze con data e ora di Roma, ricorrenze comprese;
 *  - buildIcs(): scrive gli impegni di Mario nel formato a cui Apple
 *    Calendar si abbona.
 *
 * Il team lavora in Italia: tutto viene ricondotto all'ora di Roma.
 * I file con l'underscore dentro api/ non diventano funzioni su Vercel. */

"use strict";

var ROME = "Europe/Rome";
var DAY_MS = 86400000;
var WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

/* ------------------------------------------------------------------ */
/* utilità di data: le date "di calendario" sono Date in UTC a mezzanotte,
   cosi' l'aritmetica dei giorni non risente dell'ora legale. */

function pad(n){ return n < 10 ? "0" + n : "" + n; }
function ymd(d){ return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()); }
function hm(d){ return pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()); }
function dayOnly(d){ return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())); }

/* Ora "da muro" in un fuso -> istante reale (ms). Due passaggi bastano
   anche a cavallo del cambio d'ora. */
function tzOffsetMs(tz, instant){
  var f = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit"
  });
  var p = {};
  f.formatToParts(new Date(instant)).forEach(function(x){ p[x.type] = x.value; });
  var asUtc = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute, +p.second);
  return asUtc - instant;
}
function wallToInstant(wallMs, tz){
  var guess = wallMs - tzOffsetMs(tz, wallMs);
  return wallMs - tzOffsetMs(tz, guess);
}
function instantToWall(instant, tz){
  return instant + tzOffsetMs(tz, instant);
}
function validTz(tz){
  if(!tz) return false;
  try { new Intl.DateTimeFormat("en-US", { timeZone: tz }); return true; }
  catch(_){ return false; }
}

/* ------------------------------------------------------------------ */
/* lettura */

function unfold(text){
  return String(text || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n[ \t]/g, "");
}

function parseLine(line){
  var colon = -1, inQuote = false;
  for(var i = 0; i < line.length; i++){
    var c = line[i];
    if(c === '"') inQuote = !inQuote;
    else if(c === ":" && !inQuote){ colon = i; break; }
  }
  if(colon < 0) return null;
  var head = line.slice(0, colon).split(";");
  var params = {};
  head.slice(1).forEach(function(p){
    var eq = p.indexOf("=");
    if(eq > 0) params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1).replace(/^"|"$/g, "");
  });
  return { name: head[0].toUpperCase(), params: params, value: line.slice(colon + 1) };
}

function unescapeText(v){
  return String(v || "")
    .replace(/\\n/gi, "\n")
    .replace(/\\([,;\\])/g, "$1");
}

/* Valore DATE o DATE-TIME -> { wall: ms "da muro", allDay, tz } */
function parseDateValue(prop){
  if(!prop) return null;
  var v = String(prop.value || "").trim().split(",")[0];
  var m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$/.exec(v);
  if(!m) return null;
  if(!m[4] || prop.params.VALUE === "DATE"){
    return { wall: Date.UTC(+m[1], +m[2] - 1, +m[3]), allDay: true, tz: null };
  }
  var wall = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0));
  if(m[7]) return { wall: instantToWall(wall, ROME), allDay: false, tz: ROME, utc: true };
  var tz = validTz(prop.params.TZID) ? prop.params.TZID : ROME;
  return { wall: wall, allDay: false, tz: tz };
}

/* Ogni valore di EXDATE/RDATE (anche separati da virgola) -> chiavi giorno */
function parseDateList(props, tz){
  var out = [];
  (props || []).forEach(function(p){
    String(p.value || "").split(",").forEach(function(v){
      var d = parseDateValue({ value: v, params: p.params });
      if(!d) return;
      var wall = d.wall;
      if(d.utc && tz && tz !== ROME) wall = instantToWall(wallToInstant(wall, ROME), tz);
      out.push(ymd(new Date(wall)));
    });
  });
  return out;
}

function parseDuration(v){
  var m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(String(v || "").trim());
  if(!m) return null;
  var ms = ((+m[2] || 0) * 7 + (+m[3] || 0)) * DAY_MS +
           ((+m[4] || 0) * 3600 + (+m[5] || 0) * 60 + (+m[6] || 0)) * 1000;
  return m[1] === "-" ? -ms : ms;
}

function parseRrule(v){
  var r = {};
  String(v || "").split(";").forEach(function(part){
    var eq = part.indexOf("=");
    if(eq > 0) r[part.slice(0, eq).toUpperCase()] = part.slice(eq + 1).toUpperCase();
  });
  if(!r.FREQ) return null;
  return {
    freq: r.FREQ,
    interval: Math.max(1, parseInt(r.INTERVAL, 10) || 1),
    count: r.COUNT ? parseInt(r.COUNT, 10) : null,
    until: r.UNTIL || null,
    byday: r.BYDAY ? r.BYDAY.split(",").map(function(x){
      var mm = /^([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/.exec(x);
      return mm ? { n: mm[1] ? parseInt(mm[1], 10) : 0, wd: WEEKDAYS.indexOf(mm[2]) } : null;
    }).filter(Boolean) : null,
    bymonthday: r.BYMONTHDAY ? r.BYMONTHDAY.split(",").map(function(x){ return parseInt(x, 10); }) : null,
    bymonth: r.BYMONTH ? r.BYMONTH.split(",").map(function(x){ return parseInt(x, 10); }) : null
  };
}

function nthWeekdayMatch(d, n, wd){
  if(d.getUTCDay() !== wd) return false;
  if(n === 0) return true;
  var day = d.getUTCDate();
  if(n > 0) return Math.ceil(day / 7) === n;
  var last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  return Math.ceil((last - day + 1) / 7) === -n;
}

/* Il giorno d rispetta la regola? start = primo giorno della serie */
function ruleMatches(rule, start, d){
  var days = Math.round((d - start) / DAY_MS);
  if(days < 0) return false;
  var months = (d.getUTCFullYear() - start.getUTCFullYear()) * 12 + d.getUTCMonth() - start.getUTCMonth();
  if(rule.bymonth && rule.bymonth.indexOf(d.getUTCMonth() + 1) < 0) return false;

  if(rule.freq === "DAILY"){
    if(days % rule.interval) return false;
    if(rule.byday) return rule.byday.some(function(b){ return b.wd === d.getUTCDay(); });
    return true;
  }
  if(rule.freq === "WEEKLY"){
    var mondayStart = start - ((start.getUTCDay() + 6) % 7) * DAY_MS;
    var weeks = Math.floor((d - mondayStart) / (7 * DAY_MS));
    if(weeks % rule.interval) return false;
    if(rule.byday) return rule.byday.some(function(b){ return b.wd === d.getUTCDay(); });
    return d.getUTCDay() === start.getUTCDay();
  }
  if(rule.freq === "MONTHLY"){
    if(months % rule.interval) return false;
    if(rule.byday) return rule.byday.some(function(b){ return nthWeekdayMatch(d, b.n, b.wd); });
    if(rule.bymonthday){
      var last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
      return rule.bymonthday.some(function(md){
        return md > 0 ? d.getUTCDate() === md : d.getUTCDate() === last + md + 1;
      });
    }
    return d.getUTCDate() === start.getUTCDate();
  }
  if(rule.freq === "YEARLY"){
    var years = d.getUTCFullYear() - start.getUTCFullYear();
    if(years % rule.interval) return false;
    if(rule.byday && rule.bymonth) return rule.byday.some(function(b){ return nthWeekdayMatch(d, b.n, b.wd); });
    var month = rule.bymonth ? null : start.getUTCMonth();
    if(month !== null && d.getUTCMonth() !== month) return false;
    return d.getUTCDate() === start.getUTCDate();
  }
  return false;
}

/* Un'occorrenza (inizio "da muro" nel fuso dell'evento) -> forma di Mario */
function toOccurrence(ev, wallStart){
  var title = ev.summary || "Impegno";
  if(ev.allDay){
    var s = new Date(wallStart);
    var e = new Date(wallStart + Math.max(DAY_MS, ev.duration) - DAY_MS);
    return {
      uid: ev.uid, key: ev.uid + "|" + ymd(s),
      date: ymd(s), dateEnd: ymd(e) !== ymd(s) ? ymd(e) : null,
      start: null, end: null, allDay: true,
      title: title, tentative: ev.tentative
    };
  }
  var instant = wallToInstant(wallStart, ev.tz);
  var rs = new Date(instantToWall(instant, ROME));
  var re = new Date(instantToWall(instant + Math.max(0, ev.duration), ROME));
  /* Un impegno che finisce a mezzanotte non occupa il giorno dopo */
  var endDay = new Date(re.getTime() - (hm(re) === "00:00" && re > rs ? 1 : 0));
  return {
    uid: ev.uid, key: ev.uid + "|" + ymd(rs) + "T" + hm(rs),
    date: ymd(rs), dateEnd: ymd(endDay) !== ymd(rs) ? ymd(endDay) : null,
    start: hm(rs), end: hm(re), allDay: false,
    title: title, tentative: ev.tentative
  };
}

/* Testo .ics -> occorrenze comprese tra from e to (stringhe YYYY-MM-DD) */
function parseIcs(text, from, to){
  var lines = unfold(text).split("\n");
  var events = [];
  var cur = null, depth = 0;

  lines.forEach(function(raw){
    var line = raw.trimEnd();
    if(!line) return;
    if(line === "BEGIN:VEVENT"){ cur = { props: {} }; depth = 0; return; }
    if(!cur) return;
    if(/^BEGIN:/.test(line)){ depth++; return; }            // VALARM dentro VEVENT
    if(/^END:/.test(line) && depth > 0){ depth--; return; }
    if(line === "END:VEVENT"){ events.push(cur); cur = null; return; }
    if(depth > 0) return;
    var p = parseLine(line);
    if(!p) return;
    (cur.props[p.name] = cur.props[p.name] || []).push(p);
  });

  var winFrom = Date.parse(from + "T00:00:00Z");
  var winTo   = Date.parse(to + "T00:00:00Z");
  var overrides = {};   // uid -> giorni sostituiti da un RECURRENCE-ID
  var parsed = [];

  events.forEach(function(raw){
    var P = raw.props;
    function one(n){ return P[n] && P[n][0]; }
    var status = one("STATUS") ? one("STATUS").value.toUpperCase() : "";
    var dtstart = parseDateValue(one("DTSTART"));
    if(!dtstart) return;
    var dtend = parseDateValue(one("DTEND"));
    var duration;
    if(dtend){
      duration = dtend.allDay || !dtend.tz || dtend.tz === dtstart.tz
        ? dtend.wall - dtstart.wall
        : wallToInstant(dtend.wall, dtend.tz) - wallToInstant(dtstart.wall, dtstart.tz);
    } else {
      duration = parseDuration(one("DURATION") && one("DURATION").value);
      if(duration === null) duration = dtstart.allDay ? DAY_MS : 0;
    }
    var ev = {
      uid: (one("UID") && one("UID").value) || ("noid-" + dtstart.wall),
      summary: unescapeText(one("SUMMARY") && one("SUMMARY").value).trim(),
      allDay: dtstart.allDay,
      tz: dtstart.tz,
      start: dtstart.wall,
      duration: duration,
      cancelled: status === "CANCELLED",
      tentative: status === "TENTATIVE",
      rrule: parseRrule(one("RRULE") && one("RRULE").value),
      exdates: parseDateList(P.EXDATE, dtstart.tz),
      rdates: parseDateList(P.RDATE, dtstart.tz),
      recurrenceId: one("RECURRENCE-ID") ? parseDateList([one("RECURRENCE-ID")], dtstart.tz)[0] : null
    };
    if(ev.recurrenceId){
      (overrides[ev.uid] = overrides[ev.uid] || {})[ev.recurrenceId] = 1;
    }
    parsed.push(ev);
  });

  var out = [];
  function push(ev, wallStart){
    var occ = toOccurrence(ev, wallStart);
    var occEnd = Date.parse((occ.dateEnd || occ.date) + "T00:00:00Z");
    var occStart = Date.parse(occ.date + "T00:00:00Z");
    if(occEnd < winFrom || occStart > winTo) return;
    out.push(occ);
  }

  parsed.forEach(function(ev){
    if(ev.cancelled) return;
    if(!ev.rrule || ev.recurrenceId){
      push(ev, ev.start);
      return;
    }
    var timeOfDay = ev.start - dayOnly(new Date(ev.start)).getTime();
    var startDay = dayOnly(new Date(ev.start));
    var skip = {};
    ev.exdates.forEach(function(k){ skip[k] = 1; });
    Object.keys(overrides[ev.uid] || {}).forEach(function(k){ skip[k] = 1; });

    var untilDay = null;
    if(ev.rrule.until){
      var u = parseDateValue({ value: ev.rrule.until, params: {} });
      if(u){
        var uw = u.utc && ev.tz && ev.tz !== ROME ? instantToWall(wallToInstant(u.wall, ROME), ev.tz) : u.wall;
        untilDay = dayOnly(new Date(uw)).getTime();
      }
    }
    var limit = Math.min(winTo, untilDay === null ? Infinity : untilDay);
    var n = 0;
    for(var t = startDay.getTime(), i = 0; t <= limit && i < 20000; t += DAY_MS, i++){
      var d = new Date(t);
      if(!ruleMatches(ev.rrule, startDay, d)) continue;
      n++;
      if(ev.rrule.count !== null && n > ev.rrule.count) break;
      if(skip[ymd(d)]) continue;
      if(t + Math.max(DAY_MS, ev.duration) < winFrom - DAY_MS) continue;
      push(ev, t + timeOfDay);
    }
    ev.rdates.forEach(function(k){
      if(!skip[k]) push(ev, Date.parse(k + "T00:00:00Z") + timeOfDay);
    });
  });

  out.sort(function(a, b){ return (a.date + (a.start || "")).localeCompare(b.date + (b.start || "")); });
  return out;
}

/* ------------------------------------------------------------------ */
/* scrittura */

function escapeText(v){
  return String(v || "")
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n");
}

/* Righe oltre 75 ottetti vanno spezzate (RFC 5545 §3.1) */
function fold(line){
  var out = [], cur = "", len = 0;
  for(var ch of line){
    var b = Buffer.byteLength(ch);
    if(len + b > (out.length ? 74 : 75)){ out.push(cur); cur = ""; len = 0; }
    cur += ch; len += b;
  }
  out.push(cur);
  return out.join("\r\n ");
}

function compactDate(s){ return String(s).replace(/-/g, ""); }
function compactTime(s){ return String(s).replace(":", "") + "00"; }
function nextDay(s){
  var d = new Date(Date.parse(s + "T00:00:00Z") + DAY_MS);
  return ymd(d);
}
function utcStamp(iso){
  var d = iso ? new Date(iso) : new Date();
  if(isNaN(d)) d = new Date();
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

var VTIMEZONE_ROME = [
  "BEGIN:VTIMEZONE",
  "TZID:Europe/Rome",
  "BEGIN:DAYLIGHT",
  "TZOFFSETFROM:+0100",
  "TZOFFSETTO:+0200",
  "TZNAME:CEST",
  "DTSTART:19700329T020000",
  "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU",
  "END:DAYLIGHT",
  "BEGIN:STANDARD",
  "TZOFFSETFROM:+0200",
  "TZOFFSETTO:+0100",
  "TZNAME:CET",
  "DTSTART:19701025T030000",
  "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU",
  "END:STANDARD",
  "END:VTIMEZONE"
];

/* Mezza giornata senza orario: gli stessi orari del vecchio foglio */
var HALF_TIMES = { am: ["09:00", "13:00"], pm: ["14:30", "18:30"] };

function addHour(t){
  var p = String(t).split(":");
  var h = Math.min(23, +p[0] + 1);
  return pad(h) + ":" + p[1];
}

/* Righe di be_cal_events -> testo .ics */
function buildIcs(rows, opts){
  opts = opts || {};
  var L = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Brown Enterprises//Mario Chi fa cosa//IT",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:" + escapeText(opts.name || "Mario · Chi fa cosa"),
    "X-WR-TIMEZONE:Europe/Rome",
    "REFRESH-INTERVAL;VALUE=DURATION:PT30M",
    "X-PUBLISHED-TTL:PT30M"
  ].concat(VTIMEZONE_ROME);

  (rows || []).forEach(function(r){
    var tentative = r.status === "da_confermare";
    var prefix = tentative ? "? " : "";
    var summary;
    if(r.kind === "ferie") summary = prefix + (r.title && r.title !== "Ferie" ? "Ferie · " + r.title : "Ferie");
    else if(r.kind === "extra") summary = prefix + "Extra fosforo · " + r.title;
    else summary = prefix + r.title + (tentative ? " ?" : "");

    var desc = [];
    if(r.project_name) desc.push("Progetto: " + r.project_name);
    if(r.persons && r.persons.length > 1) desc.push("Con: " + r.persons.join(", "));
    if(tentative) desc.push("Da confermare");
    if(r.notes) desc.push(r.notes);

    L.push("BEGIN:VEVENT");
    L.push("UID:" + r.id + "@brownenterprises.it");
    L.push("DTSTAMP:" + utcStamp(r.updated_at || r.created_at));
    var lastDay = r.date_end || r.date;
    if(r.half === "day" && !r.start_time || r.date_end && !r.start_time){
      L.push("DTSTART;VALUE=DATE:" + compactDate(r.date));
      L.push("DTEND;VALUE=DATE:" + compactDate(nextDay(lastDay)));
    } else {
      var st = r.start_time || (HALF_TIMES[r.half] || HALF_TIMES.am)[0];
      var et = r.end_time || (r.start_time ? addHour(r.start_time) : (HALF_TIMES[r.half] || HALF_TIMES.am)[1]);
      var endDate = lastDay;
      if(!r.date_end && et <= st) endDate = nextDay(r.date);
      L.push("DTSTART;TZID=Europe/Rome:" + compactDate(r.date) + "T" + compactTime(st));
      L.push("DTEND;TZID=Europe/Rome:" + compactDate(endDate) + "T" + compactTime(et));
    }
    L.push("SUMMARY:" + escapeText(summary));
    if(desc.length) L.push("DESCRIPTION:" + escapeText(desc.join("\n")));
    // il luogo (sql/luogo.sql): Apple Calendar lo mostra e lo apre in Mappe
    if(r.location) L.push("LOCATION:" + escapeText(r.location));
    if(r.location && r.location_lat != null && r.location_lon != null){
      L.push("GEO:" + Number(r.location_lat).toFixed(6) + ";" + Number(r.location_lon).toFixed(6));
    }
    L.push("STATUS:" + (tentative ? "TENTATIVE" : "CONFIRMED"));
    L.push("TRANSP:OPAQUE");
    if(r.kind === "ferie") L.push("CATEGORIES:Ferie");
    else if(r.kind === "extra") L.push("CATEGORIES:Extra fosforo");
    else if(r.project_name) L.push("CATEGORIES:" + escapeText(r.project_name));
    L.push("END:VEVENT");
  });

  L.push("END:VCALENDAR");
  return L.map(fold).join("\r\n") + "\r\n";
}

module.exports = { parseIcs: parseIcs, buildIcs: buildIcs };
