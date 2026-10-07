const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

const menu = {
  days: [
    { weekday: "Montag", date: "2026-08-24", dateLabel: "24. Aug", dishes: ["Boulette, Pfefferrahmsoße", "Gebackener Hirtenkäse"] },
    { weekday: "Dienstag", date: "2026-08-25", dateLabel: "25. Aug", dishes: ["Schnitzel (Hähnchen)", "Spinat-Kichererbsen-Curry"] },
    { weekday: "Mittwoch", date: "2026-08-26", dateLabel: "26. Aug", dishes: ["Gulasch (Rind)", "Blumenkohl-Schawarma"] },
    { weekday: "Donnerstag", date: "2026-08-27", dateLabel: "27. Aug", dishes: ["Moussaka", "Brokkoli-Parmesan-Nuggets"] },
    { weekday: "Freitag", date: "2026-08-28", dateLabel: "28. Aug", dishes: ["Fisch der Woche, Grüne Soße", "Parmesan-Zucchini"] },
  ],
  pdfUrl: "https://warthemahl.de/x.pdf",
  weekLabel: "24.–28. Aug 2026",
  sourceUrl: "https://warthemahl.de/speisekarte/",
  fetchedAt: 1787824333,
  stale: false,
  error: "",
}

test("a payload that is not the helper's JSON never reaches a binding as a throw", () => {
  assert.equal(Model.parsePayload(""), null)
  assert.equal(Model.parsePayload("Traceback (most recent call last):"), null)
  assert.equal(Model.parsePayload('{"days":"nope"}'), null)
  assert.deepEqual(Model.parsePayload(JSON.stringify(menu)).days.length, 5)
})

test("today is matched by calendar date, not by weekday name", () => {
  assert.equal(Model.todayIndex(menu.days, new Date(2026, 7, 24, 12, 0)), 0)
  assert.equal(Model.todayIndex(menu.days, new Date(2026, 7, 28, 12, 0)), 4)
  // Same weekday, a week later: not today.
  assert.equal(Model.todayIndex(menu.days, new Date(2026, 7, 31, 12, 0)), -1)
})

test("dish icons follow the site's line order, with fish called out", () => {
  assert.equal(Model.dishIcon(0, "Boulette, Pfefferrahmsoße"), Model.ICON_MAIN)
  assert.equal(Model.dishIcon(1, "Gebackener Hirtenkäse"), Model.ICON_VEG)
  assert.equal(Model.dishIcon(0, "Fisch der Woche"), Model.ICON_FISH)
  // The vegetarian line stays vegetarian even when it names a fishy word.
  assert.equal(Model.dishIcon(1, "Fischersalat"), Model.ICON_VEG)
})

test("the week note explains every way the published card can miss today", () => {
  assert.equal(Model.weekNote(menu, new Date(2026, 7, 26, 12, 0)), "")
  assert.equal(Model.weekNote(menu, new Date(2026, 7, 29, 12, 0)), "Wochenende · neue Karte ab Montag")
  assert.match(Model.weekNote(menu, new Date(2026, 8, 3, 12, 0)), /Nicht mehr aktuell/)
  assert.equal(Model.weekNote(menu, new Date(2026, 7, 21, 12, 0)), "Karte der kommenden Woche")
})

test("a day the kitchen skipped inside the published week says so rather than staying silent", () => {
  const holidayWeek = { ...menu, days: menu.days.filter((d) => d.date !== "2026-08-26") }
  assert.equal(Model.weekNote(holidayWeek, new Date(2026, 7, 26, 12, 0)), "Heute keine Ausgabe")
  assert.equal(Model.todayIndex(holidayWeek.days, new Date(2026, 7, 26, 12, 0)), -1)
})

test("status distinguishes loading, offline, and fresh", () => {
  const now = new Date(1787824333 * 1000 + 3 * 60 * 1000)
  assert.match(Model.statusLine(menu, now, true), /geladen/)
  assert.equal(Model.statusLine(menu, now, false), "Aktualisiert vor 3 Min.")
  assert.match(Model.statusLine({ ...menu, stale: true }, now, false), /^Offline/)
  assert.equal(Model.statusLine({ ...Model.emptyMenu(), error: "boom" }, now, false), "boom")
})

test("truncation trims trailing punctuation instead of leaving ', …'", () => {
  assert.equal(Model.truncate("Boulette, Pfefferrahmsoße", 11), "Boulette…")
  assert.equal(Model.truncate("kurz", 40), "kurz")
})

test("the tooltip shows today's dishes and otherwise says why it cannot", () => {
  assert.match(Model.tooltipText(menu, new Date(2026, 7, 24, 12, 0)), /^Montag · Boulette/)
  assert.match(Model.tooltipText(menu, new Date(2026, 7, 29, 12, 0)), /Wochenende/)
})

test("the widget wires the helper and the cache-respecting refresh", () => {
  const qml = fs.readFileSync(path.join(__dirname, "..", "WarthemahlWidget.qml"), "utf8")
  assert.match(qml, /bin\/warthemahl-menu/)
  assert.match(qml, /"--max-age", String\(root\.refreshIntervalSec\)/)
  // Right-click and the refresh button must force a real fetch, not a cache read.
  assert.match(qml, /root\.refresh\(true\)/)
  // A failed helper must not blank out a menu that is already on screen.
  assert.match(qml, /function failWith\(message\) \{\s*\n\s*\/\/[^\n]*\n\s*\/\/[^\n]*\n\s*if \(root\.hasDays\) return/)
})

// CI has no DMS to load the plugin with, so the checks that decide whether a
// fresh install works are mirrored here against the manifest rules from
// plugin-schema.json. A manifest that fails these fails on someone else's bar.
test("the manifest satisfies what DMS demands of a plugin", () => {
  const root = path.join(__dirname, "..")
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "plugin.json"), "utf8"))

  assert.match(manifest.version, /^\d+\.\d+\.\d+$/)
  assert.match(manifest.id, /^[a-zA-Z][a-zA-Z0-9]*$/, "id must be camelCase")
  assert.equal(manifest.type, "widget")

  for (const entry of [manifest.component, manifest.settings]) {
    assert.ok(entry, "component and settings must be declared")
    assert.match(entry, /^\.\/.*\.qml$/, "component paths start with ./ and end in .qml")
    assert.ok(!entry.includes(".."), "entry point must stay inside the plugin")
    assert.ok(fs.existsSync(path.join(root, entry)), `entry point ${entry} is missing`)
  }

  // A settings UI without settings_write renders as an error box.
  assert.ok(manifest.permissions.includes("settings_write"), "settings need the settings_write permission")

  // Every pluginData key the widget reads must exist as a settingKey in
  // Settings.qml (or be written by the widget itself), or it is dead weight
  // the settings UI never offers.
  const widget = fs.readFileSync(path.join(root, manifest.component), "utf8")
  const settings = fs.readFileSync(path.join(root, manifest.settings), "utf8")
  const read = [...widget.matchAll(/pluginData\?\.(\w+)/g)].map((m) => m[1])
  const declared = [...settings.matchAll(/settingKey: "(\w+)"/g)].map((m) => m[1])
  for (const key of new Set(read)) {
    assert.ok(declared.includes(key), `widget reads pluginData.${key} but Settings.qml never declares it`)
  }
  assert.equal(settings.match(/pluginId: "(\w+)"/)[1], manifest.id, "PluginSettings.pluginId must match the manifest id")
})

test("the helper the panel shells out to is present and executable", () => {
  const helper = path.join(__dirname, "..", "bin", "warthemahl-menu")
  assert.ok(fs.existsSync(helper), "bin/warthemahl-menu is missing")
  // Git preserves the executable bit; losing it breaks the panel with a bare
  // non-zero exit and no output, which is miserable to debug from a screenshot.
  assert.ok(fs.statSync(helper).mode & 0o111, "bin/warthemahl-menu is not executable")
})

test("the vegetarian filter keeps each dish's line number, so icons stay honest", () => {
  const day = { weekday: "Montag", dishes: ["Boulette", "Gebackener Hirtenkäse"] }

  assert.deepEqual(Model.visibleDishes(day, false), [
    { text: "Boulette", index: 0 },
    { text: "Gebackener Hirtenkäse", index: 1 },
  ])
  // Filtered down to one dish, it must still carry index 1 -- an index of 0
  // would draw the vegetarian option with the meat icon.
  assert.deepEqual(Model.visibleDishes(day, true), [{ text: "Gebackener Hirtenkäse", index: 1 }])
  assert.equal(Model.dishIcon(Model.visibleDishes(day, true)[0].index, ""), Model.ICON_VEG)
})

test("a day with no vegetarian option filters to nothing rather than to the meat dish", () => {
  assert.deepEqual(Model.visibleDishes({ dishes: ["Gulasch"] }, true), [])
  assert.deepEqual(Model.visibleDishes({}, true), [])
  assert.deepEqual(Model.visibleDishes(null, false), [])
})

test("the bar tooltip follows the filter instead of contradicting the open panel", () => {
  const monday = new Date(2026, 7, 24, 12, 0)
  assert.match(Model.tooltipText(menu, monday, false), /Boulette/)
  assert.doesNotMatch(Model.tooltipText(menu, monday, true), /Boulette/)
  assert.match(Model.tooltipText(menu, monday, true), /Hirtenkäse/)

  const meatOnly = { ...menu, days: [{ weekday: "Montag", date: "2026-08-24", dishes: ["Gulasch"] }] }
  assert.match(Model.tooltipText(meatOnly, monday, true), /keine vegetarische Option/)
})

test("the bar line follows the vegetarian filter instead of advertising the meat dish", () => {
  const qml = fs.readFileSync(path.join(__dirname, "..", "WarthemahlWidget.qml"), "utf8")
  // The widget must build its bar text from visibleDishes (filter-aware),
  // not from Model.barLabel, which always takes line 1.
  assert.match(qml, /barText[\s\S]*?Model\.visibleDishes\(root\.menu\.days\[root\.todayIndex\], root\.vegetarianOnly\)/)
  assert.doesNotMatch(qml, /Model\.barLabel\(/)
})
