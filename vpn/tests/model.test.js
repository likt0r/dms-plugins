// Model.js ist pur gebaut, also lassen sich die Entscheidungen des Widgets hier
// prüfen statt durch Starren auf eine laufende Bar: was als verbunden gilt,
// welche Zeilen das Popout zeigt, welches protonvpn-Kommando ein Klick auslöst
// und wie Fehlermeldungen der CLI beim Nutzer ankommen.

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const root = path.join(__dirname, "..")
const Model = require(path.join(root, "Model.js"))
const manifest = require(path.join(root, "plugin.json"))

// --- Manifest -------------------------------------------------------------

test("manifest declares a widget whose components exist", () => {
  assert.match(manifest.id, /^[a-zA-Z][a-zA-Z0-9]*$/)
  assert.equal(manifest.type, "widget")
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/)
  for (const key of ["component", "settings"]) {
    assert.match(manifest[key], /^\.\/.*\.qml$/)
    assert.ok(fs.existsSync(path.join(root, manifest[key])), `${key} missing`)
  }
  assert.ok(manifest.permissions.includes("settings_write"), "settings UI needs settings_write")
})

test("QML files and the IPC target use the manifest id", () => {
  const settings = fs.readFileSync(path.join(root, "Settings.qml"), "utf8")
  const widget = fs.readFileSync(path.join(root, "VpnWidget.qml"), "utf8")
  assert.match(settings, new RegExp(`pluginId: "${manifest.id}"`))
  assert.match(widget, new RegExp(`target: "${manifest.id}"`))
})

// Inline components inside popoutContent are silently ignored by DMS.
test("inline components live in the root object", () => {
  const widget = fs.readFileSync(path.join(root, "VpnWidget.qml"), "utf8")
  for (const match of widget.matchAll(/^( *)component \w+:/gm)) {
    assert.equal(match[1].length, 4, "inline component must be indented one level")
  }
})

test("the helper script is executable", () => {
  fs.accessSync(path.join(root, "bin", "proton-locations"), fs.constants.X_OK)
})

// --- Zustand aus DMSNetworkService ----------------------------------------

// So liefert das DMS-Backend network.vpn.active (gekürzt, echte Form).
const active = [
  { name: "wg_config", uuid: "fefc3594", device: "wg_config", state: "activated", type: "wireguard" },
  { name: "correctiv-10", uuid: "079b3936", state: "activating", type: "vpn", serviceType: "org.freedesktop.NetworkManager.openvpn" },
]

test("connections are found by name or by uuid", () => {
  assert.equal(Model.findActive(active, "wg_config").uuid, "fefc3594")
  assert.equal(Model.findActive(active, "079b3936").name, "correctiv-10")
  assert.equal(Model.findActive(active, "wg"), null, "no prefix matching")
  assert.equal(Model.findActive(null, "wg_config"), null)
})

test("only an activated connection counts as connected", () => {
  assert.equal(Model.connectionState(active, "wg_config"), "on")
  assert.equal(Model.connectionState(active, "correctiv-10"), "busy")
  assert.equal(Model.connectionState(active, "heimnetz"), "off")
  assert.equal(Model.anyConnected(active), true)
  assert.equal(Model.anyConnected([active[1]]), false, "activating is not connected yet")
})

// DMS clears its busy flag only once the pending UUID shows up as active.
test("toggling through DMS uses the uuid when the profile is known", () => {
  const profiles = [{ name: "wg_config", uuid: "fefc3594" }]
  assert.equal(Model.uuidFor(profiles, "wg_config"), "fefc3594")
  assert.equal(Model.uuidFor(profiles, "unknown"), "unknown", "falls back to the name")
})

test("profile types read like DMS names them", () => {
  assert.equal(Model.typeLabel({ type: "wireguard" }), "WireGuard")
  assert.equal(Model.typeLabel({ type: "vpn", serviceType: "org.freedesktop.NetworkManager.openvpn" }), "OpenVPN")
  assert.equal(Model.typeLabel({}), "VPN")
})

// --- Zeilen im Popout -------------------------------------------------------

const profiles = [
  { name: "correctiv-10", uuid: "079b3936", type: "vpn", serviceType: "org.freedesktop.NetworkManager.openvpn" },
  { name: "wg_config", uuid: "fefc3594", type: "wireguard" },
  { name: "ProtonVPN CH#42", uuid: "p1", type: "wireguard" },
]

test("rows list every NM profile except Proton's own, with overrides applied", () => {
  const rows = Model.connectionRows(profiles, active, { wg_config: { label: "Heim", toggleCommand: "/bin/wg-heim" } }, false)
  assert.deepEqual(rows.map(r => r.name), ["correctiv-10", "wg_config"])
  assert.equal(rows[1].title, "Heim")
  assert.equal(rows[1].state, "on")
  assert.equal(rows[1].toggleCommand, "/bin/wg-heim")
  assert.equal(rows[0].type, "OpenVPN")
})

test("hidden profiles disappear from the popout but not from the settings", () => {
  const overrides = { "correctiv-10": { hidden: true } }
  assert.deepEqual(Model.connectionRows(profiles, [], overrides, false).map(r => r.name), ["wg_config"])
  const all = Model.connectionRows(profiles, [], overrides, true)
  assert.equal(all.length, 2)
  assert.equal(all[0].hidden, true)
})

test("a custom command is detected without surrounding whitespace", () => {
  assert.equal(Model.hasCustomCommand({ toggleCommand: " " }), false)
  assert.equal(Model.hasCustomCommand({ toggleCommand: "/x" }), true)
})

// --- Proton ------------------------------------------------------------------

const protonOn = { name: "ProtonVPN CH#42", uuid: "p1", device: "proton0", state: "activated", type: "wireguard" }

test("Proton's connection is recognised by name or by its device", () => {
  assert.equal(Model.isProtonEntry(protonOn), true)
  assert.equal(Model.isProtonEntry({ name: "x", device: "proton0" }), true)
  assert.equal(Model.isProtonEntry(active[0]), false)
  assert.equal(Model.protonActive(active.concat([protonOn])), protonOn)
  assert.equal(Model.protonActive(active), null)
  assert.equal(Model.protonServer(protonOn), "CH#42")
})

test("the country of a server is its exit country", () => {
  assert.equal(Model.serverCountry("CH#42"), "CH")
  assert.equal(Model.serverCountry("IS-DE#1"), "DE", "Secure Core: entry IS, exit DE")
  assert.equal(Model.serverCountry("uk#3"), "UK")
})

test("the default target from the settings field", () => {
  assert.deepEqual(Model.parseTarget(""), { type: "fastest", feature: "" })
  assert.deepEqual(Model.parseTarget("de"), { type: "country", country: "DE", feature: "" })
  assert.deepEqual(Model.parseTarget("de#12"), { type: "server", server: "DE#12", feature: "" })
  assert.deepEqual(Model.parseTarget(" Berlin "), { type: "city", city: "Berlin", feature: "" })
})

test("targets become protonvpn connect arguments", () => {
  assert.deepEqual(Model.connectArgs({ type: "fastest" }), ["protonvpn", "connect"])
  assert.deepEqual(Model.connectArgs({ type: "country", country: "UK" }), ["protonvpn", "connect", "--country", "UK"])
  assert.deepEqual(Model.connectArgs({ type: "server", server: "DE#12" }), ["protonvpn", "connect", "DE#12"])
  assert.deepEqual(
    Model.connectArgs({ type: "city", city: "New York", country: "US", feature: "p2p" }),
    ["protonvpn", "connect", "--city", "New York", "--p2p"],
    "the CLI takes the city alone; the country is only for display"
  )
  assert.deepEqual(Model.connectArgs({ type: "country", country: "CH", feature: "securecore" }).slice(-1), ["--securecore"])
})

const countries = [
  { code: "CH", flag: "CH", name: "Schweiz", online: 86, load: 30, features: { securecore: 4, p2p: 30, tor: 0 }, cities: [{ name: "Zurich" }] },
  { code: "UK", flag: "GB", name: "Vereinigtes Königreich", online: 50, load: 40, features: { securecore: 0, p2p: 10, tor: 2 }, cities: [{ name: "London" }, { name: "Manchester" }] },
]

test("target labels use the German country names and flags", () => {
  assert.deepEqual(Model.targetLabel({ type: "country", country: "CH" }, countries), { title: "Schweiz", subtitle: "Schnellster Server", flag: "CH" })
  assert.deepEqual(Model.targetLabel({ type: "server", server: "UK#3", feature: "tor" }, countries), { title: "Vereinigtes Königreich", subtitle: "UK#3 · Tor", flag: "GB" })
  assert.equal(Model.targetLabel({ type: "city", city: "London", country: "UK" }, countries).subtitle, "Vereinigtes Königreich")
  assert.equal(Model.targetLabel({ type: "fastest" }, countries).title, "Schnellster Server")
  assert.equal(Model.countryName(countries, "XX"), "XX", "unknown codes stay readable")
})

test("flags are regional indicator pairs, with Proton's UK mapped to GB", () => {
  assert.equal(Model.flagEmoji("CH"), "\u{1F1E8}\u{1F1ED}")
  assert.equal(Model.flagEmoji("uk"), Model.flagEmoji("GB"))
  assert.equal(Model.flagEmoji(""), "")
  assert.equal(Model.flagEmoji("CH#1"), "")
})

test("recents keep the newest first and never duplicate", () => {
  const ch = { type: "country", country: "CH", feature: "" }
  const de = { type: "country", country: "DE", feature: "" }
  let list = Model.pushRecent([], ch, 3)
  list = Model.pushRecent(list, de, 3)
  list = Model.pushRecent(list, ch, 3)
  assert.deepEqual(list.map(t => t.country), ["CH", "DE"])
  const p2p = Object.assign({}, ch, { feature: "p2p" })
  assert.equal(Model.pushRecent(list, p2p, 3).length, 3, "same country, other feature is another target")
})

test("favorites toggle and come first in the quick list", () => {
  const ch = { type: "country", country: "CH", feature: "" }
  const de = { type: "country", country: "DE", feature: "" }
  let favs = Model.toggleFavorite([], de)
  assert.equal(Model.isFavorite(favs, de), true)
  const quick = Model.quickTargets(favs, [ch, de], 6)
  assert.deepEqual(quick.map(q => [q.target.country, q.favorite]), [["DE", true], ["CH", false]])
  favs = Model.toggleFavorite(favs, de)
  assert.equal(favs.length, 0)
})

// Captured from protonvpn 1.0.5.
test("CLI errors are read from the output, not only the exit code", () => {
  const invalid = "Server list is outdated, updating... This may take a moment.\nError: Invalid country code 'XX'. Please use a valid country code.\n\nTry 'protonvpn connect --help' for more information.\n"
  assert.equal(Model.cliError(invalid, 2), "Invalid country code 'XX'. Please use a valid country code.")
  const gui = "Error: Proton VPN desktop app is currently running\nThe CLI and GUI cannot run simultaneously. Please close the GUI application and try again.\n"
  assert.match(Model.cliError(gui, 0), /Proton-VPN-App läuft/, "the GUI refusal exits 0")
  assert.match(Model.cliError("Error: Authentication required.Please sign in with 'protonvpn signin' before connecting.", 2), /signin/)
  assert.equal(Model.cliError("Connected to CH#42 in Zurich. \nYour new IP address is 1.2.3.4.\n", 0), "")
  assert.match(Model.cliError("", 1), /Code 1/)
})

test("the country tab filters by feature and searches names, codes and cities", () => {
  assert.deepEqual(Model.filterCountries(countries, "", "").map(c => c.code), ["CH", "UK"])
  assert.deepEqual(Model.filterCountries(countries, "", "tor").map(c => c.code), ["UK"])
  assert.deepEqual(Model.filterCountries(countries, "schw", "").map(c => c.code), ["CH"])
  assert.deepEqual(Model.filterCountries(countries, "uk", "").map(c => c.code), ["UK"])
  assert.deepEqual(Model.filterCountries(countries, "manch", "").map(c => c.code), ["UK"])
})

test("a locations payload that is not the helper's JSON never throws", () => {
  assert.equal(Model.parseLocations(""), null)
  assert.equal(Model.parseLocations("Traceback"), null)
  assert.equal(Model.parseLocations('{"countries":"x"}'), null)
  assert.equal(Model.parseLocations('{"countries":[]}').countries.length, 0)
})

// --- Traffic -----------------------------------------------------------------

test("byte counts and rates read like the template's", () => {
  assert.equal(Model.formatBytes(512), "512 B")
  assert.equal(Model.formatBytes(3.5 * 1024 * 1024), "3.5 MiB")
  assert.equal(Model.formatBytes(477.2 * 1024 * 1024), "477 MiB")
  assert.equal(Model.formatRate(596 * 1024), "596 KiB/s")
})

test("rates never go negative when the counters reset", () => {
  assert.equal(Model.rate(1000, 3000, 2000), 1000)
  assert.equal(Model.rate(5000, 100, 2000), 0)
  assert.equal(Model.rate(null, 100, 2000), 0)
  assert.equal(Model.rate(100, 200, 0), 0)
})

test("the history keeps the last n samples", () => {
  let h = []
  for (let i = 0; i < 5; i++) h = Model.pushSample(h, i, 3)
  assert.deepEqual(h, [2, 3, 4])
})

test("the graph scale rounds up to 1, 2 or 5 of its display unit", () => {
  const KiB = 1024, MiB = 1024 * 1024
  assert.equal(Model.niceScale(0), 100 * KiB, "idle never scales below 64 KiB/s")
  assert.equal(Model.niceScale(150 * KiB), 200 * KiB)
  assert.equal(Model.niceScale(3.5 * MiB), 5 * MiB)
  assert.equal(Model.niceScale(9 * MiB), 10 * MiB)
  assert.equal(Model.formatRate(Model.niceScale(9.2 * MiB)), "10 MiB/s")
})

// --- bin/proton-locations ------------------------------------------------------

test("the helper summarizes a server list per country and city", () => {
  const tmp = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "vpn-test-"))
  const dir = path.join(tmp, "Proton", "VPN")
  fs.mkdirSync(dir, { recursive: true })
  const server = (name, country, city, features, tier, load, status) =>
    ({ Name: name, ExitCountry: country, EntryCountry: country, City: city, Features: features, Tier: tier, Load: load, Status: status })
  fs.writeFileSync(path.join(dir, "serverlist.json"), JSON.stringify({
    MaxTier: 2,
    LogicalServers: [
      server("CH#1", "CH", "Zurich", 0, 2, 20, 1),
      server("CH#2", "CH", "Zurich", 4, 2, 40, 1),
      server("CH#3", "CH", "Geneva", 0, 2, 99, 0),
      server("IS-CH#1", "CH", "Zurich", 1, 2, 10, 1),
      server("UK#1", "UK", "London", 2, 2, 30, 1),
      server("DE#9", "DE", "Berlin", 0, 3, 5, 1),
    ],
  }))
  const out = JSON.parse(execFileSync("python3", ["-B", path.join(root, "bin", "proton-locations")], {
    env: Object.assign({}, process.env, { XDG_CACHE_HOME: tmp, LANGUAGE: "de" }),
  }).toString())
  fs.rmSync(tmp, { recursive: true, force: true })

  assert.equal(out.error, "")
  assert.deepEqual(out.countries.map(c => c.code).sort(), ["CH", "UK"], "tier above MaxTier is skipped")
  const ch = out.countries.find(c => c.code === "CH")
  assert.equal(ch.servers, 4)
  assert.equal(ch.online, 3)
  assert.equal(ch.load, 23, "average over online servers")
  assert.deepEqual(ch.features, { securecore: 1, p2p: 1, tor: 0 })
  assert.deepEqual(ch.cities.map(c => [c.name, c.servers]), [["Geneva", 1], ["Zurich", 2]], "Secure Core is not a city")
  const uk = out.countries.find(c => c.code === "UK")
  assert.equal(uk.flag, "GB")
  assert.equal(uk.features.tor, 1)
})
