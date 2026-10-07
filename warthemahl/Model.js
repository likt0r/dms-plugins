// Pure helpers for the WartheMahl bar plugin: no QML types, no side effects,
// so they can be exercised with `node --test` from tests/.
//
// Dish ordering is the site's own convention -- line 1 is the meat/fish dish,
// line 2 the vegetarian one -- and it is the only signal the page offers, so
// the icons key on position, with a fish override for the obvious cases.
//
// Icons are Material Symbols names (rendered via DankIcon); the Omarchy
// original used Nerd Font glyphs here. This is the only change in this file.

var ICON_MAIN = "restaurant"
var ICON_VEG = "eco"
var ICON_FISH = "set_meal"

var FISH_PATTERN = /fisch|lachs|forelle|kabeljau|dorsch|hering|seelachs|scholle|garnele/i

function emptyMenu() {
  return { days: [], pdfUrl: "", weekLabel: "", sourceUrl: "", fetchedAt: 0, stale: false, error: "" }
}

// The helper always prints one JSON object, but a crashed interpreter or a
// killed process still yields junk -- treat anything unparseable as "no data"
// rather than letting it throw inside a property binding.
function parsePayload(raw) {
  try {
    var value = JSON.parse(String(raw || ""))
    if (!value || typeof value !== "object" || !(value.days instanceof Array)) return null
    var menu = emptyMenu()
    menu.days = value.days
    menu.pdfUrl = String(value.pdfUrl || "")
    menu.weekLabel = String(value.weekLabel || "")
    menu.sourceUrl = String(value.sourceUrl || "")
    menu.fetchedAt = Number(value.fetchedAt) || 0
    menu.stale = value.stale === true
    menu.error = String(value.error || "")
    return menu
  } catch (e) {
    return null
  }
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function isoDate(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function daysBetween(isoA, isoB) {
  var a = new Date(isoA + "T00:00:00")
  var b = new Date(isoB + "T00:00:00")
  return Math.round((b.getTime() - a.getTime()) / 86400000)
}

function todayIndex(days, now) {
  var today = isoDate(now)
  for (var i = 0; i < days.length; i++) {
    if (days[i] && days[i].date === today) return i
  }
  return -1
}

function dishIcon(index, text) {
  if (index === 0 && FISH_PATTERN.test(String(text || ""))) return ICON_FISH
  return index === 0 ? ICON_MAIN : ICON_VEG
}

// Second line is the vegetarian option; anything past line 2 is an extra the
// site occasionally adds, and gets no claim either way.
function dishLabel(index) {
  if (index === 0) return "Tagesgericht"
  if (index === 1) return "Vegetarisch"
  return "Zusatz"
}

// Which dishes a day should render. Filtering to vegetarian keeps each dish's
// original line number, because the icon is picked from that position -- drop it
// and the surviving dish would be drawn as though it were the meat option.
function visibleDishes(day, vegetarianOnly) {
  var dishes = (day && day.dishes) || []
  var rows = []
  for (var i = 0; i < dishes.length; i++) rows.push({ text: dishes[i], index: i })
  if (!vegetarianOnly) return rows
  var veg = []
  for (var j = 0; j < rows.length; j++) if (rows[j].index >= 1) veg.push(rows[j])
  return veg
}

function truncate(text, max) {
  var s = String(text || "")
  if (!(max > 0) || s.length <= max) return s
  return s.substring(0, Math.max(1, max - 1)).replace(/[\s,;.]+$/, "") + "…"
}

function relativeAge(fetchedAt, now) {
  if (!(fetchedAt > 0)) return ""
  var seconds = Math.floor(now.getTime() / 1000) - fetchedAt
  if (seconds < 0) seconds = 0
  if (seconds < 90) return "gerade eben"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return "vor " + minutes + " Min."
  var hours = Math.round(minutes / 60)
  if (hours < 24) return "vor " + hours + (hours === 1 ? " Stunde" : " Stunden")
  var days = Math.round(hours / 24)
  return "vor " + days + (days === 1 ? " Tag" : " Tagen")
}

function statusLine(menu, now, loading) {
  if (loading) return "Speisekarte wird geladen…"
  if (menu.error !== "" && menu.days.length === 0) return menu.error
  if (menu.days.length === 0) return "Keine Speisekarte gefunden"
  var age = relativeAge(menu.fetchedAt, now)
  if (menu.stale) return age === "" ? "Offline" : "Offline · Stand " + age
  if (age === "gerade eben") return "Gerade aktualisiert"
  return age === "" ? "Aktuell" : "Aktualisiert " + age
}

// A note above the days when the published week is not the one we are in --
// the kitchen posts the new card during the week, so a stale card is normal
// on weekends and worth saying out loud rather than showing silently.
function weekNote(menu, now) {
  var days = menu.days || []
  var dated = []
  for (var i = 0; i < days.length; i++) {
    if (days[i] && days[i].date) dated.push(days[i])
  }
  if (!dated.length) return ""
  var today = isoDate(now)
  for (var j = 0; j < dated.length; j++) {
    if (dated[j].date === today) return ""
  }
  var first = dated[0].date
  var last = dated[dated.length - 1].date
  if (today < first) return "Karte der kommenden Woche"
  if (today > last) {
    var gap = daysBetween(last, today)
    if (gap <= 2) return "Wochenende · neue Karte ab Montag"
    return "Nicht mehr aktuell · Karte vom " + (menu.weekLabel || last)
  }
  return "Heute keine Ausgabe"
}

// Bar pill text when the user opts into showing today's dish inline.
function barLabel(menu, now, maxChars) {
  var index = todayIndex(menu.days || [], now)
  if (index < 0) return ""
  var dishes = menu.days[index].dishes || []
  if (!dishes.length) return ""
  return truncate(dishes[0], maxChars)
}

function tooltipText(menu, now, vegetarianOnly) {
  if (menu.days.length === 0) return "WartheMahl · Speisekarte"
  var index = todayIndex(menu.days, now)
  if (index < 0) {
    var note = weekNote(menu, now)
    return note !== "" ? "WartheMahl · " + note : "WartheMahl · " + menu.weekLabel
  }
  var day = menu.days[index]
  var rows = visibleDishes(day, vegetarianOnly === true)
  if (!rows.length) return day.weekday + " · keine vegetarische Option"
  var parts = []
  for (var i = 0; i < rows.length; i++) parts.push(truncate(rows[i].text, 60))
  return day.weekday + " · " + parts.join("  │  ")
}

if (typeof module !== "undefined") {
  module.exports = {
    ICON_MAIN: ICON_MAIN,
    ICON_VEG: ICON_VEG,
    ICON_FISH: ICON_FISH,
    emptyMenu: emptyMenu,
    parsePayload: parsePayload,
    isoDate: isoDate,
    daysBetween: daysBetween,
    todayIndex: todayIndex,
    dishIcon: dishIcon,
    dishLabel: dishLabel,
    truncate: truncate,
    visibleDishes: visibleDishes,
    relativeAge: relativeAge,
    statusLine: statusLine,
    weekNote: weekNote,
    barLabel: barLabel,
    tooltipText: tooltipText
  }
}
