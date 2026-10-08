// Reine Datums-, Format- und Terminmathematik fuer das Kalender-Widget.
//
// Locale- und Qt-frei, damit `node --test tests/` sie pruefen kann; das QML
// besorgt Monats- und Wochentagsnamen ueber Qt.locale(). Grossteils aus dem
// Omarchy-Vorgaenger (likt0r/omarchy-calendar) uebernommen -- was dort auf
// die Exporter-Datei zugriff, arbeitet hier auf den Ereignissen, die
// CalendarService liefert.

var MS_PER_DAY = 86400000

// Wochentagsindizes passen sowohl zu JS Date.getDay() als auch zu QMLs
// Locale.Sunday…Locale.Saturday, man kann firstDayOfWeek direkt durchreichen.
var WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

// ---- Formate des Bar-Labels. Rechtsklick laeuft den Ring ab und schreibt
//      das Ergebnis zurueck in die Plugin-Daten, damit Anzeige und
//      gespeicherte Einstellung nie auseinanderlaufen.
//
// Jede Uhrzeit-Vorlage steht direkt vor ihrem 12-Stunden-Zwilling, damit der
// Weg von 24h zum gleichen Label in AM/PM ein einzelner Rechtsklick ist und
// keine Runde durch den ganzen Ring. Die ISO-Vorlage hat bewusst keinen:
// ISO 8601 schreibt die Zeit 24-stuendig, eine AM/PM-Fassung widerspraeche
// dem einzigen Zweck des Formats.
var CLOCK_FORMATS = [
  "ddd dd.MM. HH:mm",
  "ddd dd.MM. h:mm AP",
  "dddd HH:mm",
  "HH:mm",
  "h:mm AP",
  "d MMMM 'W'ww yyyy",
  "yyyy-MM-dd HH:mm"
]

// Senkrechte Bars haben Platz fuer ein paar gestapelte Zeilen und sonst
// nichts, deshalb bleibt der Ring kurz. AM/PM kostet eine vierte Zeile --
// darum traegt hier nur die nackte Uhrzeit eine.
var VERTICAL_CLOCK_FORMATS = [
  "HH\n—\nmm",
  "h\n—\nmm\nAP",
  "dd\nMMM\n'W'ww",
  "HH\nmm"
]

function clockFormats(vertical) {
  return vertical ? VERTICAL_CLOCK_FORMATS.slice() : CLOCK_FORMATS.slice()
}

// Die Vorlagen in fester Reihenfolge, dazu das konfigurierte Format, falls es
// etwas anderes ist. Die Reihenfolge darf NICHT davon abhaengen, welcher
// Eintrag gerade aktiv ist: das Umschalten schreibt zurueck, und ein Ring,
// der sich um den aktuellen Wert herum neu sortiert, pendelt zwischen zwei
// Eintraegen statt zu laufen.
function clockFormatRing(configured, presets) {
  var ring = []
  var candidates = (presets || []).concat([configured])
  for (var i = 0; i < candidates.length; i++) {
    var format = String(candidates[i] === undefined || candidates[i] === null ? "" : candidates[i])
    if (format === "" || ring.indexOf(format) !== -1) continue
    ring.push(format)
  }
  return ring.length > 0 ? ring : ["HH:mm"]
}

// Naechster Eintrag nach `current`. Ein unbekanntes Format (von Hand
// eingetragen, nicht im Ring) startet den Lauf oben.
function nextClockFormat(ring, current) {
  if (!ring || ring.length === 0) return ""
  var index = ring.indexOf(String(current === undefined || current === null ? "" : current))
  return ring[(index + 1) % ring.length]
}

// Zweistellige ISO-Woche, wird vor dem Formatieren in das 'ww'-Token
// eingesetzt -- Qt kennt keinen eigenen ISO-Wochen-Platzhalter.
function isoWeekLiteral(year, month, day) {
  return pad2(isoWeek(year, month, day))
}

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// Stabile "yyyy-MM-dd"-Identitaet eines Tages, damit eine Gitterzelle mit
// heute verglichen werden kann, ohne Date-Objekte durch Bindings zu schleifen.
// Gleicher Schluessel wie in CalendarService.eventsByDate.
function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function coerceWeekStart(value) {
  if (value === undefined || value === null) return null
  if (typeof value === "number")
    return isFinite(value) ? ((Math.round(value) % 7) + 7) % 7 : null

  var text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "") return null

  for (var i = 0; i < WEEKDAY_NAMES.length; i++)
    if (WEEKDAY_NAMES[i] === text || WEEKDAY_NAMES[i].substr(0, 3) === text) return i

  var parsed = parseInt(text, 10)
  return isFinite(parsed) ? ((parsed % 7) + 7) % 7 : null
}

// Konfigurierter Wochenstart, faellt auf den ersten Tag der Locale zurueck,
// wenn die Einstellung fehlt oder Unsinn ist.
function normalizedWeekStart(value, fallback) {
  var configured = coerceWeekStart(value)
  if (configured !== null) return configured
  var fallbackStart = coerceWeekStart(fallback)
  return fallbackStart === null ? 1 : fallbackStart
}

function weekStartSettingName(index) {
  return WEEKDAY_NAMES[normalizedWeekStart(index, 1)]
}

// Der Schalter wechselt zwischen den beiden Konventionen, zwischen denen
// Leute tatsaechlich umstellen. Ein auf etwas anderes (Samstag etwa)
// gesetzter Kalender wird so gezeigt, wie er ist, und landet beim ersten
// Umschalten auf Montag.
function toggledWeekStart(index) {
  return normalizedWeekStart(index, 1) === 1 ? 0 : 1
}

function weekdayOrder(weekStart) {
  var start = normalizedWeekStart(weekStart, 1)
  var out = []
  for (var i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

// ISO-8601-Wochennummer: die Woche, der der Donnerstag der montagsbasierten
// Woche dieses Datums gehoert. Entspricht dem 'ww'-Token des Bar-Labels.
function isoWeek(year, month, day) {
  var date = new Date(Date.UTC(year, month, day))
  var weekday = date.getUTCDay() || 7
  date.setUTCDate(date.getUTCDate() + 4 - weekday)
  var yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
  return Math.ceil(((date.getTime() - yearStart.getTime()) / MS_PER_DAY + 1) / 7)
}

function dayOfYear(year, month, day) {
  return Math.round((Date.UTC(year, month, day) - Date.UTC(year, 0, 1)) / MS_PER_DAY) + 1
}

function daysInYear(year) {
  return dayOfYear(year, 11, 31)
}

// Anteil des Jahres, der schon hinter dir liegt: volle Tage durch Tage im
// Jahr, sodass der 1. Januar 0 % und der 31. Dezember 100 % liest.
function yearProgress(year, month, day) {
  var total = daysInYear(year)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (dayOfYear(year, month, day) - 1) / total))
}

function yearProgressPercent(year, month, day) {
  return Math.round(yearProgress(year, month, day) * 100)
}

// Immer sechs Reihen zu sieben Tagen. Ein festes Gitter haelt das Popout in
// jedem Monat exakt gleich hoch, sodass das Blaettern durchs Jahr das Panel
// nie unter dem Zeiger springen laesst.
function monthGrid(year, month, weekStart, todayKey) {
  var start = normalizedWeekStart(weekStart, 1)
  var leading = (new Date(year, month, 1).getDay() - start + 7) % 7
  var cursor = new Date(year, month, 1 - leading)
  var today = String(todayKey || "")
  var weeks = []

  for (var w = 0; w < 6; w++) {
    var days = []
    var thursday = null
    for (var d = 0; d < 7; d++) {
      var cellYear = cursor.getFullYear()
      var cellMonth = cursor.getMonth()
      var cellDay = cursor.getDate()
      var weekday = cursor.getDay()
      var key = dateKey(cellYear, cellMonth, cellDay)
      if (weekday === 4) thursday = { year: cellYear, month: cellMonth, day: cellDay }
      days.push({
        key: key,
        year: cellYear,
        month: cellMonth,
        day: cellDay,
        weekday: weekday,
        inMonth: cellMonth === month && cellYear === year,
        weekend: weekday === 0 || weekday === 6,
        today: key === today
      })
      cursor.setDate(cursor.getDate() + 1)
    }
    // Jede Reihe traegt die ISO-Woche ihres Donnerstags. Bei Montagsstart ist
    // das die Definition selbst, und bei den anderen Starts die einzige
    // Antwort, die stabil bleibt: dort liegt eine Reihe ueber zwei ISO-Wochen,
    // teilt aber Montag bis Donnerstag vollstaendig mit einer davon.
    var anchor = thursday || days[0]
    weeks.push({
      week: isoWeek(anchor.year, anchor.month, anchor.day),
      days: days
    })
  }
  return weeks
}

// Welche Locale die Daten benennt. Eine ausdrueckliche Einstellung gewinnt,
// sonst die des Systems -- das ist ja der Sinn davon, nichts konfigurieren zu
// muessen. Englisch als Rueckfall statt Qts C-Locale, deren Daten nackte
// Zahlen sind.
function localeName(configured, systemName) {
  var chosen = String(configured === undefined || configured === null
                      ? "" : configured).replace(/^\s+|\s+$/g, "")
  if (chosen !== "") return chosen
  var system = String(systemName === undefined || systemName === null
                      ? "" : systemName).replace(/^\s+|\s+$/g, "")
  if (system === "" || system === "C" || system === "POSIX") return "en_US"
  return system
}

// ---- Datumsmuster aus der Locale abgeleitet statt ausgeschrieben.
//      Ein fest verdrahtetes "MMMM d" liest sich im Deutschen als
//      "August 27", wo die Sprache "27. August" will -- die Reihenfolge kommt
//      darum aus dem langen Format der Locale ("dddd, MMMM d, yyyy" in en_US,
//      "dddd, d. MMMM yyyy" in de_DE), aus dem die ueberfluessigen Teile
//      herausgenommen werden.

// Laengste zuerst, damit "dddd" weg ist, bevor "ddd" darin treffen kann.
var YEAR_TOKENS = ["yyyy", "yy"]
var WEEKDAY_TOKENS = ["dddd", "ddd"]

// Trennzeichen, die nach dem Entfernen eines Tokens allein zurueckbleiben.
// Die beiden Enden werden bewusst ungleich behandelt: ein Punkt kann ein
// Datumsformat niemals rechtmaessig eroeffnen, ein fuehrender ist also
// Bruch (ungarisch "yyyy. MMMM d., dddd" laesst ". MMMM d." uebrig, sobald
// das Jahr geht). Am anderen Ende gehoert er zum Tag -- "d." im Deutschen
// wie im Ungarischen -- und muss ueberleben.
function tidyFormat(pattern) {
  return String(pattern === undefined || pattern === null ? "" : pattern)
    .replace(/\s+/g, " ")
    .replace(/(,\s*){2,}/g, ", ")
    .replace(/^[\s,.]+/, "")
    .replace(/[\s,]+$/, "")
}

function stripFormatTokens(pattern, tokens) {
  var out = String(pattern === undefined || pattern === null ? "" : pattern)
  for (var i = 0; i < tokens.length; i++) out = out.split(tokens[i]).join("")
  return tidyFormat(out)
}

// "27. August" / "August 27" -- die Ueberschrift, unter der ohnehin schon
// steht, welches Jahr gemeint ist.
function dayMonthFormat(longFormat) {
  return stripFormatTokens(longFormat, WEEKDAY_TOKENS.concat(YEAR_TOKENS))
    || "MMMM d"
}

// "Donnerstag, 27. August" / "Thursday, August 27" -- Agenda-Ueberschrift und
// Detailbereich, wo der Wochentag der Punkt ist.
function weekdayDayMonthFormat(longFormat) {
  return stripFormatTokens(longFormat, YEAR_TOKENS) || "dddd, MMMM d"
}

function stepMonth(year, month, delta) {
  var target = new Date(year, Number(month) + Number(delta), 1)
  return { year: target.getFullYear(), month: target.getMonth() }
}

// ---- Termine. Die Ereignisse kommen aus CalendarService und tragen bereits
//      Date-Objekte (start/end, pro Tag zugeschnitten), Farbe, Kalendername
//      und allDay. Alles hier arbeitet nur darauf, nie auf dem Backend.

var MAX_DOTS = 3

function minutesOf(date) {
  return date.getHours() * 60 + date.getMinutes()
}

// "14:30" bzw. "2:30 PM"; ganztaegige Termine haben keine Uhrzeit.
function timeLabel(event, use24Hour) {
  if (!event || event.allDay) return ""
  var d = event.start
  if (!d || typeof d.getHours !== "function") return ""
  if (use24Hour === false) {
    var h = d.getHours()
    var suffix = h < 12 ? "AM" : "PM"
    var h12 = h % 12
    if (h12 === 0) h12 = 12
    return h12 + ":" + pad2(d.getMinutes()) + " " + suffix
  }
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function endTimeLabel(event, use24Hour) {
  if (!event || event.allDay || !event.end) return ""
  return timeLabel({ start: event.end, allDay: false }, use24Hour)
}

// Ob der Termin an diesem Tag schon vorbei ist. Ganztaegige gelten erst am
// Folgetag als vergangen, nicht ab Mitternacht.
function isPast(event, dayKey, now) {
  if (!event || !now) return false
  var todayKey = keyForDate(now)
  if (dayKey > todayKey) return false
  if (dayKey < todayKey) return true
  if (event.allDay) return false
  if (!event.end) return false
  return minutesOf(event.end) <= minutesOf(now)
}

// Laeuft gerade: nur am heutigen Tag und nur bei Terminen mit Uhrzeit.
function isOngoing(event, dayKey, now) {
  if (!event || !now || event.allDay) return false
  if (dayKey !== keyForDate(now)) return false
  if (!event.start || !event.end) return false
  var m = minutesOf(now)
  return minutesOf(event.start) <= m && m < minutesOf(event.end)
}

// Vor welchem Listeneintrag die "Jetzt"-Linie steht. -1 heisst: keine Linie
// (anderer Tag, oder der Tag ist schon ganz vorbei).
function nowMarkerIndex(events, dayKey, now) {
  if (!events || !now) return -1
  if (dayKey !== keyForDate(now)) return -1
  var m = minutesOf(now)
  for (var i = 0; i < events.length; i++) {
    var e = events[i]
    if (e.allDay || !e.start) continue
    if (minutesOf(e.start) > m) return i
  }
  return -1
}

// Was an einem Tag gezeigt wird: ganztaegige zuerst, dann nach Beginn
// sortiert; vergangene auf Wunsch raus.
function visibleForDay(events, dayKey, opts) {
  var list = (events || []).slice()
  var o = opts || {}
  if (o.hidePast === true && o.now)
    list = list.filter(function (e) { return !isPast(e, dayKey, o.now) })
  list.sort(function (a, b) {
    if (a.allDay !== b.allDay) return a.allDay ? -1 : 1
    var at = a.start ? a.start.getTime() : 0
    var bt = b.start ? b.start.getTime() : 0
    if (at !== bt) return at - bt
    return String(a.title || "").localeCompare(String(b.title || ""))
  })
  return list
}

// Ein Punkt je beteiligtem Kalender in dessen Farbe, hoechstens MAX_DOTS.
function dotColors(events, max) {
  var limit = max === undefined ? MAX_DOTS : max
  var seen = []
  for (var i = 0; i < (events || []).length; i++) {
    var color = String(events[i].color || "")
    if (color === "" || seen.indexOf(color) !== -1) continue
    seen.push(color)
    if (seen.length >= limit) break
  }
  return seen
}

function hasMoreThanDots(events, max) {
  var limit = max === undefined ? MAX_DOTS : max
  var seen = []
  for (var i = 0; i < (events || []).length; i++) {
    var color = String(events[i].color || "")
    if (color !== "" && seen.indexOf(color) === -1) seen.push(color)
  }
  return seen.length > limit
}

// ---- Der naechste Termin fuer die Bar-Pille.

// Der naechste noch nicht beendete Termin mit Uhrzeit ab jetzt, hoechstens
// `withinHours` voraus. Ganztaegige bleiben aussen vor: sie haben keine
// Uhrzeit, auf die man zusteuern koennte.
function nextEvent(eventsByDate, now, withinHours) {
  if (!eventsByDate || !now) return null
  var horizon = (withinHours === undefined ? 24 : withinHours) * 3600000
  var limit = now.getTime() + horizon
  var best = null
  var keys = Object.keys(eventsByDate)
  for (var i = 0; i < keys.length; i++) {
    var list = eventsByDate[keys[i]] || []
    for (var j = 0; j < list.length; j++) {
      var e = list[j]
      if (!e || e.allDay || !e.start || !e.end) continue
      if (e.end.getTime() <= now.getTime()) continue
      if (e.start.getTime() > limit) continue
      if (!best || e.start.getTime() < best.start.getTime()) best = e
    }
  }
  return best
}

// "jetzt", "in 5 min", "in 2 h" -- knapp genug fuer die Bar.
function untilLabel(event, now, texts) {
  var t = texts || { now: "jetzt", inMin: "in %1 min", inHour: "in %1 h" }
  if (!event || !now || !event.start) return ""
  var diff = Math.round((event.start.getTime() - now.getTime()) / 60000)
  if (diff <= 0) return t.now
  if (diff < 60) return t.inMin.replace("%1", String(diff))
  return t.inHour.replace("%1", String(Math.round(diff / 60)))
}

// ---- Ort, Link, Teilnehmer.

// ---- Videokonferenz-Links.
//
// dcal fuellt meetingUrl nur fuer die Anbieter, die es selbst kennt -- Zoom,
// Google Meet, Teams. BigBlueButton gehoert nicht dazu, und genau das steht
// bei Correctiv in den Terminen, dort als Ort. Die Hostliste stammt aus dem
// Thunderbird-Exporter des Omarchy-Vorgaengers, der dasselbe Problem hatte.
var MEETING_HOSTS = [
  "zoom.us", "zoom.com", "zoomgov.com",
  "teams.microsoft.com", "teams.live.com",
  "meet.google.com",
  "bigbluebutton.org", "whereby.com", "meet.jit.si",
  "webex.com", "gotomeeting.com", "goto.com", "chime.aws",
  "meet.nextcloud.com"
]

var MEETING_HOST_PREFIXES = ["bbb.", "meet.", "bigbluebutton.", "jitsi.", "vc.", "conf."]

function hostOf(url) {
  var m = /^https?:\/\/([^\/\s:?#]+)/i.exec(String(url || ""))
  return m ? m[1].toLowerCase() : ""
}

function looksLikeMeeting(url) {
  var host = hostOf(url)
  if (host === "") return false
  for (var i = 0; i < MEETING_HOSTS.length; i++) {
    var known = MEETING_HOSTS[i]
    if (host === known || host.slice(-(known.length + 1)) === "." + known) return true
  }
  for (var j = 0; j < MEETING_HOST_PREFIXES.length; j++)
    if (host.indexOf(MEETING_HOST_PREFIXES[j]) === 0) return true
  return false
}

// Erster Konferenz-Link in einem Text. Satzzeichen am Ende gehoeren nicht zur
// URL -- ein Link am Satzende schleppt sonst den Punkt mit.
function findMeetingUrl(text) {
  var matches = String(text || "").match(/https?:\/\/[^\s<>"')\]]+/g)
  if (!matches) return ""
  for (var i = 0; i < matches.length; i++) {
    var url = matches[i].replace(/[.,;:]+$/, "")
    if (looksLikeMeeting(url)) return url
  }
  return ""
}

// Der Link, auf den der Kamera-Knopf zeigt: was dcal erkannt hat, sonst der
// erste Konferenz-Link in Ort oder Einladungstext.
function meetingUrlFor(event) {
  if (!event) return ""
  var given = String(event.meetingUrl || "")
  if (isOpenableUrl(given)) return given
  return findMeetingUrl(event.location) || findMeetingUrl(event.description)
}

function shortUrl(url) {
  var text = String(url || "")
  var stripped = text.replace(/^https?:\/\//, "").replace(/^www\./, "")
  var slash = stripped.indexOf("/")
  return slash === -1 ? stripped : stripped.substr(0, slash)
}

// Der Ort, wie er in die zweite Zeile passt. Ist der Ort nichts als der
// Meeting-Link, zeigt stattdessen der Kamera-Knopf darauf -- dann bleibt die
// Zeile leer, statt die URL doppelt zu zeigen.
function locationLabel(event) {
  var text = collapseSpace(String((event && event.location) || ""))
  if (text === "") return ""
  if (/^https?:\/\//.test(text)) {
    var url = meetingUrlFor(event)
    if (url !== "" && text.indexOf(url) === 0) return ""
    return shortUrl(text)
  }
  return text
}

function collapseSpace(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/[\t\r ]+/g, " ")
    .replace(/^\s+|\s+$/g, "")
}

function trimSeparators(text) {
  return collapseSpace(text).replace(/^[\s,;:.\-–—]+/, "").replace(/[\s,;:.\-–—]+$/, "")
}

// Nur http(s) wird geoeffnet. Die Pruefung steht hier UND an der Aufrufstelle:
// der Knopf soll gar nicht erst erscheinen, und was trotzdem durchkommt, darf
// kein file:// oder javascript: sein.
function isOpenableUrl(url) {
  return /^https?:\/\/[^\s]+$/.test(String(url || ""))
}

// Zeichen fuer den Teilnahmestatus. Material-Symbols-Namen, nicht Glyphen.
function attendeeIcon(status) {
  switch (String(status || "").toLowerCase()) {
    case "accepted": return "check_circle"
    case "declined": return "cancel"
    case "tentative": return "help"
    case "delegated": return "forward"
    default: return "radio_button_unchecked"
  }
}

function attendeeName(attendee) {
  if (!attendee) return ""
  var name = collapseSpace(attendee.name || attendee.displayName || "")
  if (name !== "") return name
  return String(attendee.email || "").replace(/^mailto:/i, "")
}

// Wie viele zugesagt haben, fuer die Kopfzeile des Detailbereichs.
function attendeeSummary(attendees) {
  var list = attendees || []
  var accepted = 0
  for (var i = 0; i < list.length; i++)
    if (String(list[i].status || "").toLowerCase() === "accepted") accepted++
  return { total: list.length, accepted: accepted }
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_DOTS: MAX_DOTS,
    pad2: pad2,
    dateKey: dateKey,
    keyForDate: keyForDate,
    normalizedWeekStart: normalizedWeekStart,
    weekStartSettingName: weekStartSettingName,
    toggledWeekStart: toggledWeekStart,
    weekdayOrder: weekdayOrder,
    isoWeek: isoWeek,
    isoWeekLiteral: isoWeekLiteral,
    dayOfYear: dayOfYear,
    daysInYear: daysInYear,
    yearProgress: yearProgress,
    yearProgressPercent: yearProgressPercent,
    monthGrid: monthGrid,
    stepMonth: stepMonth,
    localeName: localeName,
    tidyFormat: tidyFormat,
    stripFormatTokens: stripFormatTokens,
    dayMonthFormat: dayMonthFormat,
    weekdayDayMonthFormat: weekdayDayMonthFormat,
    clockFormats: clockFormats,
    clockFormatRing: clockFormatRing,
    nextClockFormat: nextClockFormat,
    timeLabel: timeLabel,
    endTimeLabel: endTimeLabel,
    isPast: isPast,
    isOngoing: isOngoing,
    nowMarkerIndex: nowMarkerIndex,
    visibleForDay: visibleForDay,
    dotColors: dotColors,
    hasMoreThanDots: hasMoreThanDots,
    nextEvent: nextEvent,
    untilLabel: untilLabel,
    shortUrl: shortUrl,
    locationLabel: locationLabel,
    collapseSpace: collapseSpace,
    trimSeparators: trimSeparators,
    isOpenableUrl: isOpenableUrl,
    looksLikeMeeting: looksLikeMeeting,
    findMeetingUrl: findMeetingUrl,
    meetingUrlFor: meetingUrlFor,
    attendeeIcon: attendeeIcon,
    attendeeName: attendeeName,
    attendeeSummary: attendeeSummary
  }
}
