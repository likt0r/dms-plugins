// Reine Helfer für das Timer-Widget: keine QML-Typen, keine Nebenwirkungen,
// damit sie mit `node --test` aus tests/ geprüft werden können.
//
// Vorbild ist Omarchys ReminderFlowModel.js (validMinutes/reminderArgs). Neu
// ist das flexible Zeitformat: parseDuration versteht dieselben Formen wie
// parse_when in bin/dms-reminder; das Widget übergibt dem Skript aber nur
// fertige Sekunden.

var UNIT_SECONDS = { h: 3600, m: 60, s: 1 }
var UNIT_ORDER = ["h", "m", "s"]
var DEFAULT_PRESETS = "5m, 10m, 15m, 25m, 45m, 1h"

function normalizeUnit(unit) {
  var u = String(unit || "m").toLowerCase().charAt(0)
  return UNIT_SECONDS[u] ? u : "m"
}

// Sekunden bis zum Ablauf, oder null.
//   "25"        -> 25 in bareUnit (Standard Minuten, einstellbar h/m/s)
//   "3h30m4s", "90m", "90min", "45s", "2h"
//   "1h30"      -> die Zahl am Ende zählt in der nächstkleineren Einheit
//                  (1 h 30 min; "5m30" = 5 min 30 s)
//   "14:30", "14.30" -> bis zum nächsten 14:30, heute oder morgen
function parseDuration(text, now, bareUnit) {
  var spec = String(text || "").replace(/\s+/g, "").toLowerCase()
  if (!spec) return null
  var m

  if ((m = spec.match(/^(\d{1,2})[:.](\d{2})$/))) {
    var h = parseInt(m[1], 10)
    var min = parseInt(m[2], 10)
    if (h > 23 || min > 59) return null
    var base = now instanceof Date ? now : new Date(now === undefined || now === null ? Date.now() : now)
    var target = new Date(base.getTime())
    target.setHours(h, min, 0, 0)
    if (target.getTime() <= base.getTime()) target.setDate(target.getDate() + 1)
    return Math.round((target.getTime() - base.getTime()) / 1000)
  }

  if (/^\d+$/.test(spec)) {
    var n = parseInt(spec, 10) * UNIT_SECONDS[normalizeUnit(bareUnit)]
    return n > 0 ? n : null
  }

  // Folge aus Zahl+Einheit, Einheiten absteigend, jede höchstens einmal.
  var re = /(\d+)(min|h|m|s)?/g
  var total = 0
  var last = -1        // Index in UNIT_ORDER der zuletzt gelesenen Einheit
  var pos = 0
  while ((m = re.exec(spec)) !== null) {
    if (m.index !== pos) return null
    pos = re.lastIndex
    var unit = m[2] === "min" ? "m" : m[2]
    var idx
    if (unit) {
      idx = UNIT_ORDER.indexOf(unit)
    } else {
      // Zahl ohne Einheit nur am Ende und nur nach einer Einheit.
      if (pos !== spec.length || last < 0 || last >= UNIT_ORDER.length - 1) return null
      idx = last + 1
    }
    if (idx <= last) return null
    total += parseInt(m[1], 10) * UNIT_SECONDS[UNIT_ORDER[idx]]
    last = idx
  }
  if (pos !== spec.length || last < 0) return null
  return total > 0 ? total : null
}

// "3 h 30 min 4 s", "15 min", "45 s" -- Vorschau, Kopfzeile, Meldung.
function describeDuration(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var r = s % 60
  var parts = []
  if (h > 0) parts.push(h + " h")
  if (m > 0) parts.push(m + " min")
  if (r > 0 || parts.length === 0) parts.push(r + " s")
  return parts.join(" ")
}

// Restzeit: "4:05", "12:34", "1:05:00".
function formatCountdown(seconds) {
  var s = Math.max(0, Math.ceil(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var r = s % 60
  var pad = function (n) { return n < 10 ? "0" + n : String(n) }
  return h > 0 ? h + ":" + pad(m) + ":" + pad(r) : m + ":" + pad(r)
}

function clockTime(epochSeconds) {
  var d = new Date(Number(epochSeconds) * 1000)
  var pad = function (n) { return n < 10 ? "0" + n : String(n) }
  return d.getHours() + ":" + pad(d.getMinutes())
}

// Vorschau zur Eingabe im HUD.
function preview(text, now, bareUnit) {
  if (!String(text || "").trim()) return { ok: false, text: "" }
  var seconds = parseDuration(text, now, bareUnit)
  if (seconds === null) return { ok: false, text: "Unbekanntes Format – z. B. 25, 3h30m4s oder 14:30" }
  var nowMs = now instanceof Date ? now.getTime() : (now === undefined || now === null ? Date.now() : now)
  return {
    ok: true,
    seconds: seconds,
    text: describeDuration(seconds) + " · um " + clockTime(nowMs / 1000 + seconds)
  }
}

// Vorgabe-Kacheln aus der Einstellung: "5m, 10m, 25, 1h30m".
// Getrennt wird an Komma oder Semikolon (Leerzeichen gehören zu "1h 30m").
function presets(text, bareUnit) {
  var raw = String(text === undefined || text === null || String(text).trim() === "" ? DEFAULT_PRESETS : text)
  var out = []
  var seen = {}
  var parts = raw.split(/[,;]/)
  for (var i = 0; i < parts.length; i++) {
    var label = parts[i].trim()
    if (!label || /[:.]/.test(label)) continue
    var seconds = parseDuration(label, null, bareUnit)
    if (seconds === null || seen[seconds]) continue
    seen[seconds] = true
    out.push({ label: label, seconds: seconds })
  }
  return out
}

// Argumente für bin/dms-reminder; leer, wenn die Zeit nicht taugt.
function reminderArgs(seconds, message, silent) {
  var s = Math.round(Number(seconds) || 0)
  if (!(s > 0)) return []
  var args = silent ? ["--silent"] : []
  args.push("--seconds", String(s))
  var text = String(message || "").trim()
  if (text) args.push(text)
  return args
}

// Ausgabe von `dms-reminder show --json`; nie ein Throw im Binding.
function parseShowJson(text) {
  try {
    var data = JSON.parse(String(text || ""))
    if (!data || !Array.isArray(data.reminders)) return null
    return data.reminders.filter(function (r) { return r && r.unit && Number(r.at) > 0 })
      .sort(function (a, b) { return a.at - b.at })
  } catch (e) {
    return null
  }
}

function nextReminder(list, nowSeconds) {
  for (var i = 0; i < (list || []).length; i++) {
    if (list[i].at > nowSeconds) return list[i]
  }
  return null
}

// Ein Timer ohne Notiz heißt einfach "Timer".
function title(reminder) {
  var text = String((reminder || {}).message || "").trim()
  return text || "Timer"
}

// Was die Toggle-Leiste (schalter) anzeigt.
function barState(list, nowSeconds, showCountdown) {
  var next = nextReminder(list, nowSeconds)
  return {
    active: next !== null,
    text: next !== null && showCountdown ? formatCountdown(next.at - nowSeconds) : ""
  }
}

// Pfeiltasten im HUD: Vorgabe weiterschalten, rundum.
function stepIndex(index, delta, count) {
  if (!(count > 0)) return -1
  if (index < 0) return delta > 0 ? 0 : count - 1
  return ((index + delta) % count + count) % count
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_PRESETS: DEFAULT_PRESETS,
    normalizeUnit: normalizeUnit,
    parseDuration: parseDuration,
    describeDuration: describeDuration,
    formatCountdown: formatCountdown,
    clockTime: clockTime,
    preview: preview,
    presets: presets,
    reminderArgs: reminderArgs,
    parseShowJson: parseShowJson,
    nextReminder: nextReminder,
    title: title,
    barState: barState,
    stepIndex: stepIndex
  }
}
