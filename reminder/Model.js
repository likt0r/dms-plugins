// Reine Helfer für das Erinnerungs-Widget: keine QML-Typen, keine
// Nebenwirkungen, damit sie mit `node --test` aus tests/ geprüft werden können.
//
// Vorbild ist Omarchys ReminderFlowModel.js (validMinutes/reminderArgs). Neu
// ist das flexible Zeitformat: parseDuration versteht dieselben Formen wie
// parse_when in bin/dms-reminder, das Widget übergibt dem Skript aber nur noch
// fertige Sekunden.

var DEFAULT_QUICK = [5, 10, 15, 30, 60]

// Sekunden bis zum Termin, oder null.
//   "15" -> 15 min (wie Omarchy)   "90m", "45s", "2h", "1h30", "1h 30m"
//   "14:30" / "14.30" -> nächstes 14:30, heute oder morgen
function parseDuration(text, now) {
  var spec = String(text || "").replace(/\s+/g, "").toLowerCase()
  if (!spec) return null
  var m

  if ((m = spec.match(/^(\d{1,2})[:.](\d{2})$/))) {
    var h = parseInt(m[1], 10)
    var min = parseInt(m[2], 10)
    if (h > 23 || min > 59) return null
    var base = now instanceof Date ? now : new Date(now === undefined ? Date.now() : now)
    var target = new Date(base.getTime())
    target.setHours(h, min, 0, 0)
    if (target.getTime() <= base.getTime()) target.setDate(target.getDate() + 1)
    return Math.round((target.getTime() - base.getTime()) / 1000)
  }

  var seconds = null
  if ((m = spec.match(/^(\d+)$/))) seconds = parseInt(m[1], 10) * 60
  else if ((m = spec.match(/^(\d+)s$/))) seconds = parseInt(m[1], 10)
  else if ((m = spec.match(/^(\d+)m(in)?$/))) seconds = parseInt(m[1], 10) * 60
  else if ((m = spec.match(/^(\d+)h((\d+)(m|min)?)?$/))) seconds = parseInt(m[1], 10) * 3600 + parseInt(m[3] || "0", 10) * 60
  return seconds > 0 ? seconds : null
}

// "1 h 30 min", "15 min", "45 s" -- für Vorschau und Bestätigung.
function describeDuration(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (h > 0) return m > 0 ? h + " h " + m + " min" : h + " h"
  if (m > 0) return m + " min"
  return s + " s"
}

// Countdown für die Bar: "4:05", "12:34", "1:05:00".
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

// Vorschau unter dem Zeitfeld.
function preview(text, now) {
  if (!String(text || "").trim()) return { ok: false, text: "" }
  var seconds = parseDuration(text, now)
  if (seconds === null) return { ok: false, text: "Unbekanntes Format – z. B. 15, 1h30, 45s oder 14:30" }
  var nowMs = now instanceof Date ? now.getTime() : (now === undefined ? Date.now() : now)
  return { ok: true, seconds: seconds, text: "um " + clockTime(nowMs / 1000 + seconds) + " · in " + describeDuration(seconds) }
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

function label(reminder) {
  var text = String((reminder || {}).message || "").trim()
  return text || "Erinnerung"
}

// Schnellwahl aus den Einstellungen: "5,10,15" -> [5, 10, 15].
function quickTimes(text) {
  var parts = String(text === undefined || text === null ? "" : text).split(/[,;\s]+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var n = parseInt(parts[i], 10)
    if (n > 0 && out.indexOf(n) < 0) out.push(n)
  }
  return out.length ? out : DEFAULT_QUICK.slice()
}

function quickLabel(minutes) {
  return minutes >= 60 && minutes % 60 === 0 ? (minutes / 60) + " h" : minutes + " min"
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_QUICK: DEFAULT_QUICK,
    parseDuration: parseDuration,
    describeDuration: describeDuration,
    formatCountdown: formatCountdown,
    clockTime: clockTime,
    preview: preview,
    reminderArgs: reminderArgs,
    parseShowJson: parseShowJson,
    nextReminder: nextReminder,
    label: label,
    quickTimes: quickTimes,
    quickLabel: quickLabel
  }
}
