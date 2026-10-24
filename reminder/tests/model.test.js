// Model.js ist pur gebaut: das Zeitformat, der Countdown und das Lesen von
// `dms-reminder show --json` lassen sich hier prüfen statt in einer laufenden
// Bar. Dazu ein Abgleich, dass bin/dms-reminder dieselben Formate versteht.

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const root = path.join(__dirname, "..")
const Model = require(path.join(root, "Model.js"))
const manifest = require(path.join(root, "plugin.json"))
const helper = path.join(root, "bin", "dms-reminder")

// --- Manifest -------------------------------------------------------------

test("manifest declares a widget whose components exist", () => {
  assert.match(manifest.id, /^[a-zA-Z][a-zA-Z0-9]*$/)
  assert.equal(manifest.type, "widget")
  for (const key of ["component", "settings"]) {
    assert.ok(fs.existsSync(path.join(root, manifest[key])), `${key} missing`)
  }
  assert.ok(manifest.permissions.includes("settings_write"))
})

test("QML, IPC target and the helper's refresh call use the manifest id", () => {
  const widget = fs.readFileSync(path.join(root, "ReminderWidget.qml"), "utf8")
  const settings = fs.readFileSync(path.join(root, "Settings.qml"), "utf8")
  const script = fs.readFileSync(helper, "utf8")
  assert.match(widget, new RegExp(`target: "${manifest.id}"`))
  assert.match(settings, new RegExp(`pluginId: "${manifest.id}"`))
  assert.match(script, new RegExp(`dms ipc call ${manifest.id} refresh`))
})

// DMS-eigene Widget-Ids gewinnen in der Bar, ein Plugin mit derselben Id
// erschiene nie (siehe vpn/: "vpn" -> "vpnHub").
test("the id is not one of DMS's built-in bar widgets", () => {
  const builtin = ["clock", "battery", "vpn", "clipboard", "music", "weather", "systemTray", "notificationButton"]
  assert.ok(!builtin.includes(manifest.id))
})

test("inline components live in the root object", () => {
  const widget = fs.readFileSync(path.join(root, "ReminderWidget.qml"), "utf8")
  for (const match of widget.matchAll(/^( *)component \w+:/gm)) {
    assert.equal(match[1].length, 4)
  }
})

test("the helper is executable and valid bash", () => {
  fs.accessSync(helper, fs.constants.X_OK)
  execFileSync("bash", ["-n", helper])
})

test("schalter knows the timer and reads this plugin's anchor", () => {
  const schalter = fs.readFileSync(path.join(root, "..", "schalter", "SchalterWidget.qml"), "utf8")
  const widget = fs.readFileSync(path.join(root, "ReminderWidget.qml"), "utf8")
  assert.match(schalter, /"timer"/)
  assert.match(schalter, /getGlobalVar\("reminder",\s*\n?\s*"anker:"/)
  assert.match(widget, /setGlobalVar\("reminder", "anker:"/)
  assert.match(widget, /function popoutAnkern\(/)
  assert.match(widget, /readonly property var leiste:/)
})

// Eine Instanz je Bildschirm, IPC erreicht nur die erste: die Liste muss
// geteilt sein, sonst sieht die Leiste einen per Tastenkürzel gestellten Timer
// erst beim Abgleich jede Minute.
test("the timer list is shared between the per-screen instances", () => {
  const widget = fs.readFileSync(path.join(root, "ReminderWidget.qml"), "utf8")
  assert.match(widget, /PluginGlobalVar \{[\s\S]*?varName: "liste"/)
  assert.match(widget, /readonly property var reminders: geteilt\.value/)
  assert.doesNotMatch(widget, /root\.reminders = /, "no instance-local writes")
})

// --- Zeitformat ---------------------------------------------------------------

const morning = new Date(2026, 9, 11, 10, 39, 0)

test("a bare number counts in the configured unit", () => {
  assert.equal(Model.parseDuration("25", morning), 1500, "default: minutes, like Omarchy")
  assert.equal(Model.parseDuration("25", morning, "m"), 1500)
  assert.equal(Model.parseDuration("2", morning, "h"), 7200)
  assert.equal(Model.parseDuration("90", morning, "s"), 90)
  assert.equal(Model.parseDuration("25", morning, "x"), 1500, "unknown unit falls back to minutes")
})

test("unit sequences, the user's 3h30m4s included", () => {
  assert.equal(Model.parseDuration("3h30m4s", morning), 3 * 3600 + 30 * 60 + 4)
  assert.equal(Model.parseDuration("3h 30m 4s", morning), 3 * 3600 + 30 * 60 + 4)
  assert.equal(Model.parseDuration("45s", morning), 45)
  assert.equal(Model.parseDuration("90m", morning), 5400)
  assert.equal(Model.parseDuration("90min", morning), 5400)
  assert.equal(Model.parseDuration("2h", morning), 7200)
  assert.equal(Model.parseDuration("1H30M", morning), 5400)
  assert.equal(Model.parseDuration("1h4s", morning), 3604, "units may be skipped")
})

test("a trailing bare number counts in the next smaller unit", () => {
  assert.equal(Model.parseDuration("1h30", morning, "s"), 5400, "independent of the bare unit")
  assert.equal(Model.parseDuration("5m30", morning), 330)
})

test("a clock time means the next such time, today or tomorrow", () => {
  assert.equal(Model.parseDuration("14:30", morning), (3 * 60 + 51) * 60)
  assert.equal(Model.parseDuration("14.30", morning), (3 * 60 + 51) * 60)
  assert.equal(Model.parseDuration("9:05", morning), (22 * 60 + 26) * 60, "already past -> tomorrow")
  assert.equal(Model.parseDuration("10:39", morning), 24 * 3600, "exactly now -> tomorrow")
})

test("nonsense, zero, wrong order and impossible times are rejected", () => {
  for (const bad of ["", "0", "0m", "-5", "1.5", "soon", "25:00", "12:60", "h30", "5x",
    "4s30", "30m2h", "5m5m", "m5", "1h2h"]) {
    assert.equal(Model.parseDuration(bad, morning), null, bad)
  }
})

// Skript und Model.js müssen dasselbe verstehen.
test("bin/dms-reminder parses the same formats", () => {
  const parse = (spec, unit) => execFileSync("bash", ["-c",
    `source <(sed -n '/^parse_when()/,/^}/p' "$0"); parse_when "$1" "$2" || echo FAIL`, helper, spec, unit || "m"]).toString().trim()
  for (const spec of ["25", "45s", "90m", "90min", "2h", "1h30", "1h 30m", "3h30m4s", "5m30", "1h4s"]) {
    assert.equal(Number(parse(spec)), Model.parseDuration(spec, new Date()), spec)
  }
  assert.equal(Number(parse("2", "h")), 7200)
  assert.equal(Number(parse("90", "s")), 90)
  for (const bad of ["soon", "25:00", "1.5", "4s30", "30m2h", "0"]) assert.equal(parse(bad), "FAIL", bad)
})

test("the HUD preview says how long and when, or what is wrong", () => {
  assert.deepEqual(Model.preview("25", morning), { ok: true, seconds: 1500, text: "25 min · um 11:04" })
  assert.equal(Model.preview("3h30m4s", morning).text, "3 h 30 min 4 s · um 14:09")
  assert.equal(Model.preview("", morning).ok, false)
  assert.equal(Model.preview("", morning).text, "")
  assert.match(Model.preview("bald", morning).text, /Unbekanntes Format/)
})

test("presets come from the settings field", () => {
  assert.deepEqual(Model.presets("", "m").map(p => p.label), ["5m", "10m", "15m", "25m", "45m", "1h"])
  assert.deepEqual(Model.presets("5m, 1h 30m; 90", "s").map(p => [p.label, p.seconds]),
    [["5m", 300], ["1h 30m", 5400], ["90", 90]])
  assert.deepEqual(Model.presets("10m, 600s, quatsch, 14:30", "m").map(p => p.label), ["10m"],
    "duplicates, nonsense and clock times are dropped")
})

test("arrow keys cycle through the presets", () => {
  assert.equal(Model.stepIndex(-1, 1, 6), 0, "first press right selects the first")
  assert.equal(Model.stepIndex(-1, -1, 6), 5, "first press left selects the last")
  assert.equal(Model.stepIndex(5, 1, 6), 0)
  assert.equal(Model.stepIndex(0, -1, 6), 5)
  assert.equal(Model.stepIndex(0, 1, 0), -1, "no presets, nothing to select")
})

test("durations and countdowns read naturally", () => {
  assert.equal(Model.describeDuration(45), "45 s")
  assert.equal(Model.describeDuration(900), "15 min")
  assert.equal(Model.describeDuration(5400), "1 h 30 min")
  assert.equal(Model.describeDuration(12604), "3 h 30 min 4 s")
  assert.equal(Model.describeDuration(7200), "2 h")
  assert.equal(Model.formatCountdown(245), "4:05")
  assert.equal(Model.formatCountdown(3900), "1:05:00")
  assert.equal(Model.formatCountdown(-3), "0:00")
  assert.equal(Model.formatCountdown(0.2), "0:01", "never shows 0:00 while still pending")
})

// --- Skript-Aufruf, Liste, Toggle-Leiste ----------------------------------------

test("the widget passes seconds, sound flag and the optional note", () => {
  assert.deepEqual(Model.reminderArgs(900, "Tee"), ["--seconds", "900", "Tee"])
  assert.deepEqual(Model.reminderArgs(900, "  "), ["--seconds", "900"], "no note: a timer without a name")
  assert.deepEqual(Model.reminderArgs(60, "x", true), ["--silent", "--seconds", "60", "x"])
  assert.deepEqual(Model.reminderArgs(0, "x"), [])
})

// Form wie von `dms-reminder show --json`.
const shown = JSON.stringify({ now: 1000, count: 2, reminders: [
  { unit: "dms-reminder-2", message: "", at: 2000, atTime: "10:50" },
  { unit: "dms-reminder-1", message: "Tee", at: 1500, atTime: "10:40" },
] })

test("the list is read sorted and never throws", () => {
  const list = Model.parseShowJson(shown)
  assert.deepEqual(list.map(r => r.unit), ["dms-reminder-1", "dms-reminder-2"])
  assert.equal(Model.parseShowJson(""), null)
  assert.equal(Model.parseShowJson("Traceback"), null)
  assert.deepEqual(Model.parseShowJson('{"reminders":[{"unit":""},{"at":5}]}'), [])
  assert.equal(Model.title(list[1]), "Timer", "no note -> just a timer")
  assert.equal(Model.title(list[0]), "Tee")
})

test("the toggle bar shows the icon while a timer runs, the countdown only if wanted", () => {
  const list = Model.parseShowJson(shown)
  assert.deepEqual(Model.barState(list, 1000, false), { active: true, text: "" })
  assert.deepEqual(Model.barState(list, 1000, true), { active: true, text: "8:20" })
  assert.deepEqual(Model.barState(list, 1600, true), { active: true, text: "6:40" })
  assert.deepEqual(Model.barState(list, 2000, true), { active: false, text: "" })
  assert.deepEqual(Model.barState([], 0, true), { active: false, text: "" })
})
