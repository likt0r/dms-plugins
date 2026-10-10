// Reine Helfer für das VPN-Widget: keine QML-Typen, keine Nebenwirkungen,
// damit sie mit `node --test` aus tests/ geprüft werden können.
//
// Das Widget kennt zwei Arten von Verbindungen:
//   - NetworkManager-Profile (WireGuard, OpenVPN, …): Zustand und Schalten
//     über DMSNetworkService oder ein eigenes Skript.
//   - Proton VPN über die offizielle CLI (`protonvpn`). Die legt beim Verbinden
//     selbst eine NM-Verbindung "ProtonVPN <Server>" an und räumt sie beim
//     Trennen wieder ab -- der Zustand kommt deshalb ebenfalls aus DMS, nur
//     geschaltet wird über die CLI.

// Material-Symbols wie beim eingebauten VPN-Widget von DMS.
var ICON_ON = "vpn_lock"
var ICON_OFF = "vpn_key_off"

// proton/vpn/backend/networkmanager: f"ProtonVPN {server_name}", Gerät proton0.
var PROTON_PREFIX = "ProtonVPN "
var PROTON_DEVICE = "proton0"

var FEATURES = ["", "securecore", "p2p", "tor"]
var FEATURE_LABELS = { "": "Standard", securecore: "Secure Core", p2p: "P2P", tor: "Tor" }

// Ein eigenes Skript wird ohne Argumente aufgerufen und entscheidet selbst
// über die Richtung -- der Weg für alles, was NetworkManager nicht weiß, etwa
// dass ein Tunnel ins eigene Heimnetz von zu Hause aus sinnlos ist.
function hasCustomCommand(options) {
  return String((options || {}).toggleCommand || "").trim() !== ""
}

// --- Zustand aus DMSNetworkService ----------------------------------------

function findActive(vpnActive, connection) {
  var wanted = String(connection || "")
  if (!wanted || !vpnActive) return null
  for (var i = 0; i < vpnActive.length; i++) {
    var entry = vpnActive[i]
    if (entry && (entry.name === wanted || entry.uuid === wanted)) return entry
  }
  return null
}

// NetworkManager führt eine Verbindung schon während Auf- und Abbau als
// aktiv; als verbunden gilt sie erst "activated".
function entryState(entry) {
  if (!entry) return "off"
  var state = String(entry.state || "")
  return state === "" || state === "activated" ? "on" : "busy"
}

function connectionState(vpnActive, connection) {
  return entryState(findActive(vpnActive, connection))
}

// DMS schaltet lieber per UUID: seine Busy-Markierung löst sich erst, wenn die
// UUID unter den aktiven auftaucht -- mit einem Namen hinge sie bis zum
// Timeout von 30 s.
function uuidFor(profiles, connection) {
  var wanted = String(connection || "")
  if (!wanted) return ""
  for (var i = 0; i < (profiles || []).length; i++) {
    var p = profiles[i]
    if (p && (p.name === wanted || p.uuid === wanted)) return String(p.uuid || wanted)
  }
  return wanted
}

function typeLabel(profile) {
  var p = profile || {}
  if (p.typeLabel) return String(p.typeLabel)
  if (p.type === "wireguard") return "WireGuard"
  var svc = String(p.serviceType || p.vpnType || "").toLowerCase()
  if (svc.indexOf("openvpn") >= 0) return "OpenVPN"
  if (svc.indexOf("openconnect") >= 0) return "OpenConnect"
  if (svc.indexOf("wireguard") >= 0) return "WireGuard"
  return "VPN"
}

// --- Proton ----------------------------------------------------------------

function isProtonEntry(entry) {
  if (!entry) return false
  return String(entry.name || "").indexOf(PROTON_PREFIX) === 0 || entry.device === PROTON_DEVICE
}

function protonActive(vpnActive) {
  for (var i = 0; i < (vpnActive || []).length; i++) {
    if (isProtonEntry(vpnActive[i])) return vpnActive[i]
  }
  return null
}

function protonServer(entry) {
  var name = String((entry || {}).name || "")
  return name.indexOf(PROTON_PREFIX) === 0 ? name.substring(PROTON_PREFIX.length) : name
}

// "CH#42" -> "CH"; Secure Core "IS-DE#1" -> "DE" (Eingang Island, Ausgang DE).
function serverCountry(server) {
  var head = String(server || "").split("#")[0]
  var parts = head.split("-")
  return parts[parts.length - 1].toUpperCase()
}

// Ziel einer Proton-Verbindung. In den Einstellungen steht es als Text:
// leer = schnellster Server, "DE" = Land, "DE#12" = Server, sonst Stadt.
function parseTarget(text) {
  var t = String(text || "").trim()
  if (!t) return { type: "fastest", feature: "" }
  if (t.indexOf("#") >= 0) return { type: "server", server: t.toUpperCase(), feature: "" }
  if (/^[A-Za-z]{2}$/.test(t)) return { type: "country", country: t.toUpperCase(), feature: "" }
  return { type: "city", city: t, feature: "" }
}

function targetKey(target) {
  var t = target || {}
  return [t.type || "fastest", t.country || "", t.city || "", t.server || "", t.feature || ""].join("|")
}

function connectArgs(target) {
  var t = target || {}
  var args = ["protonvpn", "connect"]
  if (t.type === "server" && t.server) args.push(t.server)
  else if (t.type === "city" && t.city) args.push("--city", t.city)
  else if (t.type === "country" && t.country) args.push("--country", t.country)
  if (t.feature === "securecore") args.push("--securecore")
  else if (t.feature === "p2p") args.push("--p2p")
  else if (t.feature === "tor") args.push("--tor")
  return args
}

// Ländernamen kommen aus der Standortliste (bin/proton-locations).
function countryName(countries, code) {
  var c = String(code || "").toUpperCase()
  for (var i = 0; i < (countries || []).length; i++) {
    if (countries[i].code === c) return countries[i].name
  }
  return c
}

function countryFlag(countries, code) {
  var c = String(code || "").toUpperCase()
  for (var i = 0; i < (countries || []).length; i++) {
    if (countries[i].code === c) return countries[i].flag || c
  }
  return c === "UK" ? "GB" : c
}

// Flaggen als Emoji (zwei Regional-Indicator-Zeichen); Noto Color Emoji
// zeichnet sie. Alles, was kein Ländercode ist, ergibt "".
function flagEmoji(code) {
  var c = String(code || "").toUpperCase()
  if (c === "UK") c = "GB"
  if (!/^[A-Z]{2}$/.test(c)) return ""
  return String.fromCodePoint(0x1F1E6 + c.charCodeAt(0) - 65, 0x1F1E6 + c.charCodeAt(1) - 65)
}

function targetLabel(target, countries) {
  var t = target || {}
  var feature = t.feature ? FEATURE_LABELS[t.feature] : ""
  var title, subtitle, flag = ""
  if (t.type === "server") {
    var code = serverCountry(t.server)
    title = countryName(countries, code)
    subtitle = t.server
    flag = countryFlag(countries, code)
  } else if (t.type === "city") {
    title = t.city
    subtitle = t.country ? countryName(countries, t.country) : "Stadt"
    flag = t.country ? countryFlag(countries, t.country) : ""
  } else if (t.type === "country") {
    title = countryName(countries, t.country)
    subtitle = "Schnellster Server"
    flag = countryFlag(countries, t.country)
  } else {
    title = "Schnellster Server"
    subtitle = "weltweit"
  }
  if (feature) subtitle += " · " + feature
  return { title: title, subtitle: subtitle, flag: flag }
}

// Zuletzt benutzte Ziele, das neueste vorn, ohne Dubletten.
function pushRecent(list, target, max) {
  var key = targetKey(target)
  var out = [target]
  for (var i = 0; i < (list || []).length; i++) {
    if (targetKey(list[i]) !== key) out.push(list[i])
  }
  return out.slice(0, max || 6)
}

function isFavorite(list, target) {
  var key = targetKey(target)
  for (var i = 0; i < (list || []).length; i++) {
    if (targetKey(list[i]) === key) return true
  }
  return false
}

function toggleFavorite(list, target) {
  var key = targetKey(target)
  var out = []
  for (var i = 0; i < (list || []).length; i++) {
    if (targetKey(list[i]) !== key) out.push(list[i])
  }
  if (out.length === (list || []).length) out.push(target)
  return out
}

// Favoriten zuerst, dann Zuletzt ohne die schon gezeigten Favoriten.
function quickTargets(favorites, recents, max) {
  var out = []
  var seen = {}
  var add = function (t, fav) {
    var key = targetKey(t)
    if (seen[key]) return
    seen[key] = true
    out.push({ target: t, favorite: fav })
  }
  for (var i = 0; i < (favorites || []).length; i++) add(favorites[i], true)
  for (var j = 0; j < (recents || []).length; j++) add(recents[j], false)
  return out.slice(0, max || 6)
}

// Die CLI meldet Fehler als "Error: …" (Exit 2). Läuft die Proton-App,
// verweigert sie sich mit Exit 0 -- deshalb wird die Ausgabe gelesen, nicht
// nur der Exit-Code.
function cliError(output, exitCode) {
  var text = String(output || "")
  if (text.indexOf("desktop app is currently running") >= 0)
    return "Die Proton-VPN-App läuft – die CLI arbeitet nicht parallel. App schließen und erneut versuchen."
  if (text.indexOf("Authentication required") >= 0 || text.indexOf("Please sign in") >= 0)
    return "Nicht bei Proton angemeldet: im Terminal 'protonvpn signin <benutzer>' ausführen."
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line.indexOf("Error:") === 0) return line.substring(6).trim()
  }
  if (exitCode !== undefined && exitCode !== 0) return "protonvpn beendete sich mit Code " + exitCode
  return ""
}

// --- Liste im Popout ---------------------------------------------------------

// NM-Profile ohne die von Proton angelegten, mit den Einstellungen je Profil
// (overrides[name] = { label, toggleCommand, hidden }).
function connectionRows(profiles, vpnActive, overrides, includeHidden) {
  var rows = []
  var seen = {}
  var ov = overrides || {}
  for (var i = 0; i < (profiles || []).length; i++) {
    var p = profiles[i]
    if (!p || !p.name || seen[p.name] || isProtonEntry(p)) continue
    seen[p.name] = true
    var o = ov[p.name] || {}
    if (o.hidden && !includeHidden) continue
    rows.push({
      name: p.name,
      uuid: p.uuid || "",
      title: String(o.label || "").trim() || p.name,
      type: typeLabel(p),
      state: connectionState(vpnActive, p.name),
      toggleCommand: String(o.toggleCommand || ""),
      hidden: o.hidden === true
    })
  }
  return rows
}

function anyConnected(vpnActive) {
  for (var i = 0; i < (vpnActive || []).length; i++) {
    if (entryState(vpnActive[i]) === "on") return true
  }
  return false
}

// Länder für den Reiter: Feature-Filter und Suche über Name, Code und Städte.
function filterCountries(countries, query, feature) {
  var q = String(query || "").trim().toLowerCase()
  var out = []
  for (var i = 0; i < (countries || []).length; i++) {
    var c = countries[i]
    if (feature && !(c.features && c.features[feature] > 0)) continue
    if (q) {
      var hit = c.name.toLowerCase().indexOf(q) >= 0 || c.code.toLowerCase() === q
      for (var j = 0; !hit && j < (c.cities || []).length; j++) {
        hit = c.cities[j].name.toLowerCase().indexOf(q) >= 0
      }
      if (!hit) continue
    }
    out.push(c)
  }
  return out
}

function parseLocations(text) {
  try {
    var data = JSON.parse(String(text || ""))
    if (!data || !Array.isArray(data.countries)) return null
    return data
  } catch (e) {
    return null
  }
}

// --- Traffic -----------------------------------------------------------------

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

function formatBytes(bytes) {
  var b = Math.max(0, Number(bytes) || 0)
  if (b < 1024) return Math.round(b) + " B"
  var units = ["KiB", "MiB", "GiB", "TiB"]
  var i = -1
  do { b /= 1024; i++ } while (b >= 1024 && i < units.length - 1)
  return b.toFixed(b < 10 ? 1 : 0) + " " + units[i]
}

// Zähler aus /sys/class/net/<dev>/statistics. Ein Neustart des Interfaces
// setzt sie zurück -- dann lieber eine Null als ein negativer Ausschlag.
function rate(prevBytes, curBytes, dtMs) {
  if (!(dtMs > 0) || prevBytes === null || prevBytes === undefined) return 0
  var delta = Number(curBytes) - Number(prevBytes)
  return delta > 0 ? delta * 1000 / dtMs : 0
}

function pushSample(history, value, max) {
  var out = (history || []).slice(Math.max(0, (history || []).length - (max - 1)))
  out.push(value)
  return out
}

// Obergrenze der Graph-Skala in Bytes/s: 1, 2 oder 5 × (1, 10, 100) der
// Einheit, in der formatRate sie anzeigt (KiB, MiB, …) -- sonst stünde dort
// "9.5 MiB/s". Mindestens 64 KiB/s, damit Leerlauf nicht als Rauschen den
// ganzen Graphen füllt.
function niceScale(maxValue) {
  var v = Math.max(64 * 1024, Number(maxValue) || 0)
  var unit = Math.pow(1024, Math.floor(Math.log(v) / Math.log(1024)))
  var steps = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]
  for (var i = 0; i < steps.length; i++) {
    if (v <= steps[i] * unit) return steps[i] * unit
  }
  return 1024 * unit
}

// --- Anzeige -----------------------------------------------------------------

function icon(options) {
  return (options || {}).connected ? ICON_ON : ICON_OFF
}

if (typeof module !== "undefined") {
  module.exports = {
    ICON_ON: ICON_ON,
    ICON_OFF: ICON_OFF,
    PROTON_PREFIX: PROTON_PREFIX,
    FEATURES: FEATURES,
    FEATURE_LABELS: FEATURE_LABELS,
    hasCustomCommand: hasCustomCommand,
    findActive: findActive,
    entryState: entryState,
    connectionState: connectionState,
    uuidFor: uuidFor,
    typeLabel: typeLabel,
    isProtonEntry: isProtonEntry,
    protonActive: protonActive,
    protonServer: protonServer,
    serverCountry: serverCountry,
    parseTarget: parseTarget,
    targetKey: targetKey,
    connectArgs: connectArgs,
    countryName: countryName,
    countryFlag: countryFlag,
    flagEmoji: flagEmoji,
    targetLabel: targetLabel,
    pushRecent: pushRecent,
    isFavorite: isFavorite,
    toggleFavorite: toggleFavorite,
    quickTargets: quickTargets,
    cliError: cliError,
    connectionRows: connectionRows,
    anyConnected: anyConnected,
    filterCountries: filterCountries,
    parseLocations: parseLocations,
    formatRate: formatRate,
    formatBytes: formatBytes,
    rate: rate,
    pushSample: pushSample,
    niceScale: niceScale,
    icon: icon
  }
}
