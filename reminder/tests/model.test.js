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

// --- Zeitformat ---------------------------------------------------------------

const morning = new Date(2026, 9, 11, 10, 39, 0)

test("a bare number means minutes, like Omarchy", () => {
  assert.equal(Model.parseDuration("15", morning), 900)
  assert.equal(Model.parseDuration("  5 ", morning), 300)
})

test("units and combinations", () => {
  assert.equal(Model.parseDuration("45s", morning), 45)
  assert.equal(Model.parseDuration("90m", morning), 5400)
  assert.equal(Model.parseDuration("90min", morning), 5400)
  assert.equal(Model.parseDuration("2h", morning), 7200)
  assert.equal(Model.parseDuration("1h30", morning), 5400)
  assert.equal(Model.parseDuration("1h 30m", morning), 5400)
  assert.equal(Model.parseDuration("1H30M", morning), 5400)
})

test("a clock time means the next such time, today or tomorrow", () => {
  assert.equal(Model.parseDuration("14:30", morning), (3 * 60 + 51) * 60)
  assert.equal(Model.parseDuration("14.30", morning), (3 * 60 + 51) * 60)
  assert.equal(Model.parseDuration("9:05", morning), (22 * 60 + 26) * 60, "already past -> tomorrow")
  assert.equal(Model.parseDuration("10:39", morning), 24 * 3600, "exactly now -> tomorrow")
})

test("nonsense, zero and impossible times are rejected", () => {
  for (const bad of ["", "0", "0m", "-5", "1.5", "soon", "25:00", "12:60", "h30", "5x"]) {
    assert.equal(Model.parseDuration(bad, morning), null, bad)
  }
})

// Script und Model.js müssen dasselbe verstehen.
test("bin/dms-reminder parses the same formats", () => {
  const parse = spec => execFileSync("bash", ["-c",
    `source <(sed -n '/^parse_when()/,/^}/p' "$0"); parse_when "$1" || echo FAIL`, helper, spec]).toString().trim()
  for (const spec of ["15", "45s", "90m", "90min", "2h", "1h30", "1h 30m"]) {
    assert.equal(Number(parse(spec)), Model.parseDuration(spec, new Date()), spec)
  }
  for (const bad of ["soon", "25:00", "1.5"]) assert.equal(parse(bad), "FAIL", bad)
})

test("the preview says when and how long, or what is wrong", () => {
  assert.deepEqual(Model.preview("15", morning), { ok: true, seconds: 900, text: "um 10:54 · in 15 min" })
  assert.equal(Model.preview("", morning).text, "")
  assert.equal(Model.preview("", morning).ok, false)
  assert.match(Model.preview("bald", morning).text, /Unbekanntes Format/)
})

test("durations and countdowns read naturally", () => {
  assert.equal(Model.describeDuration(45), "45 s")
  assert.equal(Model.describeDuration(900), "15 min")
  assert.equal(Model.describeDuration(5400), "1 h 30 min")
  assert.equal(Model.describeDuration(7200), "2 h")
  assert.equal(Model.formatCountdown(245), "4:05")
  assert.equal(Model.formatCountdown(754), "12:34")
  assert.equal(Model.formatCountdown(3900), "1:05:00")
  assert.equal(Model.formatCountdown(-3), "0:00")
  assert.equal(Model.formatCountdown(0.2), "0:01", "never shows 0:00 while still pending")
})

// --- Skript-Aufruf und Liste ----------------------------------------------------

test("the widget passes seconds, sound flag and message", () => {
  assert.deepEqual(Model.reminderArgs(900, "Tee"), ["--seconds", "900", "Tee"])
  assert.deepEqual(Model.reminderArgs(900, "  "), ["--seconds", "900"])
  assert.deepEqual(Model.reminderArgs(60, "x", true), ["--silent", "--seconds", "60", "x"])
  assert.deepEqual(Model.reminderArgs(0, "x"), [])
  assert.deepEqual(Model.reminderArgs(null, "x"), [])
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
  assert.equal(Model.label(list[1]), "Erinnerung", "no message -> generic label")
  assert.equal(Model.label(list[0]), "Tee")
})

test("the next reminder is the first one still in the future", () => {
  const list = Model.parseShowJson(shown)
  assert.equal(Model.nextReminder(list, 1000).unit, "dms-reminder-1")
  assert.equal(Model.nextReminder(list, 1600).unit, "dms-reminder-2")
  assert.equal(Model.nextReminder(list, 2000), null)
})

test("quick times come from the settings field", () => {
  assert.deepEqual(Model.quickTimes("5, 10,15;60"), [5, 10, 15, 60])
  assert.deepEqual(Model.quickTimes("x"), Model.DEFAULT_QUICK)
  assert.deepEqual(Model.quickTimes(""), Model.DEFAULT_QUICK)
  assert.equal(Model.quickLabel(15), "15 min")
  assert.equal(Model.quickLabel(120), "2 h")
  assert.equal(Model.quickLabel(90), "90 min")
})
