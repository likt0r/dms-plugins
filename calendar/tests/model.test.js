const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

// Ereignisse in der Form, die CalendarService liefert: Date-Objekte, pro Tag
// zugeschnitten, mit Farbe und Kalendername dekoriert.
function ev(o) {
  const day = o.day || "2026-10-08"
  const [y, m, d] = day.split("-").map(Number)
  return {
    id: o.id || (o.title || "x") + "@" + day,
    title: o.title || "Termin",
    allDay: o.allDay === true,
    start: new Date(y, m - 1, d, o.fromH ?? 0, o.fromM ?? 0),
    end: new Date(y, m - 1, d, o.toH ?? ((o.fromH ?? 0) + 1), o.toM ?? 0),
    color: o.color || "#1badf8",
    calendar: o.calendar || "Correctiv",
    location: o.location || "",
    meetingUrl: o.meetingUrl || "",
    attendees: o.attendees || [],
  }
}

test("das Monatsraster hat immer sechs Reihen zu sieben Tagen", () => {
  for (const [y, m] of [[2026, 0], [2026, 1], [2026, 9], [2024, 1]]) {
    const weeks = Model.monthGrid(y, m, 1, "")
    assert.equal(weeks.length, 6, `${y}-${m + 1}`)
    for (const w of weeks) assert.equal(w.days.length, 7)
  }
})

test("das Raster beginnt am eingestellten Wochentag", () => {
  assert.equal(Model.monthGrid(2026, 9, 1, "")[0].days[0].weekday, 1) // Montag
  assert.equal(Model.monthGrid(2026, 9, 0, "")[0].days[0].weekday, 0) // Sonntag
})

test("heute wird genau einmal markiert", () => {
  const weeks = Model.monthGrid(2026, 9, 1, "2026-10-08")
  const marked = weeks.flatMap(w => w.days).filter(d => d.today)
  assert.equal(marked.length, 1)
  assert.equal(marked[0].day, 8)
})

test("ISO-Wochen: der Jahreswechsel gehoert zur Woche seines Donnerstags", () => {
  assert.equal(Model.isoWeek(2026, 0, 1), 1)
  assert.equal(Model.isoWeek(2024, 11, 30), 1)   // Montag der KW1/2025
  assert.equal(Model.isoWeek(2026, 9, 8), 41)
  assert.equal(Model.isoWeekLiteral(2026, 0, 5), "02")
})

test("der Formatring laeuft rund und bleibt stehen, wo er ist", () => {
  const ring = Model.clockFormatRing("HH:mm", Model.clockFormats(false))
  assert.ok(ring.length > 1)
  // Jeder Eintrag kommt genau einmal vor, sonst pendelt das Umschalten.
  assert.equal(new Set(ring).size, ring.length)
  // Einmal ganz herum landet wieder am Anfang.
  let cur = ring[0]
  for (let i = 0; i < ring.length; i++) cur = Model.nextClockFormat(ring, cur)
  assert.equal(cur, ring[0])
})

test("ein von Hand eingetragenes Format steht im Ring und geht nicht verloren", () => {
  const ring = Model.clockFormatRing("'KW'ww", Model.clockFormats(false))
  assert.ok(ring.includes("'KW'ww"))
})

test("vergangen und laufend an den Tagesgrenzen", () => {
  const now = new Date(2026, 9, 8, 14, 30)
  const key = "2026-10-08"
  const vorbei = ev({ fromH: 9, toH: 10 })
  const laeuft = ev({ fromH: 14, fromM: 0, toH: 15 })
  const kommt = ev({ fromH: 16, toH: 17 })

  assert.equal(Model.isPast(vorbei, key, now), true)
  assert.equal(Model.isPast(laeuft, key, now), false)
  assert.equal(Model.isPast(kommt, key, now), false)

  assert.equal(Model.isOngoing(laeuft, key, now), true)
  assert.equal(Model.isOngoing(vorbei, key, now), false)

  // Ein frueherer Tag ist ganz vorbei, ein spaeterer gar nicht.
  assert.equal(Model.isPast(vorbei, "2026-10-07", now), true)
  assert.equal(Model.isPast(kommt, "2026-10-09", now), false)
})

test("ganztaegige Termine gelten am laufenden Tag nicht als vergangen", () => {
  const now = new Date(2026, 9, 8, 23, 50)
  assert.equal(Model.isPast(ev({ allDay: true }), "2026-10-08", now), false)
  assert.equal(Model.isPast(ev({ allDay: true }), "2026-10-07", now), true)
})

test("die Jetzt-Linie steht vor dem ersten noch kommenden Termin", () => {
  const now = new Date(2026, 9, 8, 14, 30)
  const list = [ev({ fromH: 9 }), ev({ fromH: 13 }), ev({ fromH: 16 }), ev({ fromH: 18 })]
  assert.equal(Model.nowMarkerIndex(list, "2026-10-08", now), 2)
  // An einem anderen Tag gibt es keine Linie.
  assert.equal(Model.nowMarkerIndex(list, "2026-10-09", now), -1)
  // Ist der Tag durch, auch nicht.
  assert.equal(Model.nowMarkerIndex([ev({ fromH: 9 })], "2026-10-08", now), -1)
})

test("ganztaegige Termine stehen oben, der Rest nach Uhrzeit", () => {
  const list = [ev({ fromH: 16, title: "spaet" }), ev({ allDay: true, title: "ganz" }), ev({ fromH: 9, title: "frueh" })]
  const out = Model.visibleForDay(list, "2026-10-08", {})
  assert.deepEqual(out.map(e => e.title), ["ganz", "frueh", "spaet"])
})

test("hidePast wirft nur Vergangenes weg", () => {
  const now = new Date(2026, 9, 8, 14, 30)
  const list = [ev({ fromH: 9, title: "vorbei" }), ev({ fromH: 16, title: "kommt" })]
  const out = Model.visibleForDay(list, "2026-10-08", { hidePast: true, now })
  assert.deepEqual(out.map(e => e.title), ["kommt"])
})

test("ein Punkt je Kalenderfarbe, hoechstens drei, danach der Mehr-Marker", () => {
  const vier = [
    ev({ color: "#111" }), ev({ color: "#222" }),
    ev({ color: "#333" }), ev({ color: "#444" }),
  ]
  assert.deepEqual(Model.dotColors(vier), ["#111", "#222", "#333"])
  assert.equal(Model.hasMoreThanDots(vier), true)

  // Gleiche Farbe mehrfach ergibt einen Punkt, keinen Marker.
  const doppelt = [ev({ color: "#111" }), ev({ color: "#111" })]
  assert.deepEqual(Model.dotColors(doppelt), ["#111"])
  assert.equal(Model.hasMoreThanDots(doppelt), false)
})

test("der naechste Termin ueberspringt Vergangenes und Ganztaegiges", () => {
  const now = new Date(2026, 9, 8, 14, 30)
  const map = {
    "2026-10-08": [
      ev({ fromH: 9, toH: 10, title: "vorbei" }),
      ev({ allDay: true, title: "ganztaegig" }),
      ev({ fromH: 16, toH: 17, title: "richtig" }),
    ],
    "2026-10-09": [ev({ day: "2026-10-09", fromH: 8, toH: 9, title: "morgen" })],
  }
  assert.equal(Model.nextEvent(map, now, 24).title, "richtig")
  // Ein laufender Termin zaehlt als naechster, er ist ja noch nicht vorbei.
  const laufend = { "2026-10-08": [ev({ fromH: 14, toH: 15, title: "laeuft" })] }
  assert.equal(Model.nextEvent(laufend, now, 24).title, "laeuft")
  // Jenseits des Horizonts faellt alles weg.
  assert.equal(Model.nextEvent(map, now, 1), null)
})

test("der Ort zeigt nicht denselben Link, auf den schon der Knopf zeigt", () => {
  const url = "https://meet.jit.si/abc"
  assert.equal(Model.locationLabel(ev({ location: url, meetingUrl: url })), "")
  assert.equal(Model.locationLabel(ev({ location: "Raum 3.14" })), "Raum 3.14")
  assert.equal(Model.locationLabel(ev({ location: "https://example.org/x/y" })), "example.org")
})

test("nur http(s) wird geoeffnet", () => {
  assert.equal(Model.isOpenableUrl("https://meet.jit.si/x"), true)
  assert.equal(Model.isOpenableUrl("http://x.test/y"), true)
  assert.equal(Model.isOpenableUrl("file:///etc/passwd"), false)
  assert.equal(Model.isOpenableUrl("javascript:alert(1)"), false)
  assert.equal(Model.isOpenableUrl(""), false)
  assert.equal(Model.isOpenableUrl("https://x y"), false)
})

test("Teilnehmer: Name vor Mailadresse, Status als Icon", () => {
  assert.equal(Model.attendeeName({ name: "Ada", email: "mailto:ada@x.test" }), "Ada")
  assert.equal(Model.attendeeName({ email: "mailto:ada@x.test" }), "ada@x.test")
  assert.equal(Model.attendeeIcon("ACCEPTED"), "check_circle")
  assert.equal(Model.attendeeIcon("declined"), "cancel")
  assert.equal(Model.attendeeIcon(""), "radio_button_unchecked")
  const s = Model.attendeeSummary([{ status: "accepted" }, { status: "declined" }, { status: "accepted" }])
  assert.deepEqual(s, { total: 3, accepted: 2 })
})

test("Wochenbeginn: Namen, Zahlen und Unsinn", () => {
  assert.equal(Model.normalizedWeekStart("sunday", 1), 0)
  assert.equal(Model.normalizedWeekStart("mon", 0), 1)
  assert.equal(Model.normalizedWeekStart("", 0), 0)
  assert.equal(Model.normalizedWeekStart("quatsch", 1), 1)
  assert.equal(Model.toggledWeekStart(1), 0)
  assert.equal(Model.toggledWeekStart(0), 1)
  assert.equal(Model.toggledWeekStart(6), 1) // ein exotischer Start landet auf Montag
  assert.deepEqual(Model.weekdayOrder(1), [1, 2, 3, 4, 5, 6, 0])
})

test("Datumsmuster werden aus der Locale abgeleitet, nicht geraten", () => {
  assert.equal(Model.dayMonthFormat("dddd, d. MMMM yyyy"), "d. MMMM")
  assert.equal(Model.dayMonthFormat("dddd, MMMM d, yyyy"), "MMMM d")
  assert.equal(Model.weekdayDayMonthFormat("dddd, d. MMMM yyyy"), "dddd, d. MMMM")
  // Ungarisch: der fuehrende Punkt ist Bruch, der hintere gehoert zum Tag.
  assert.equal(Model.dayMonthFormat("yyyy. MMMM d., dddd"), "MMMM d.")
})

test("die Uhrzeit respektiert das 12-Stunden-Format", () => {
  const e = ev({ fromH: 14, fromM: 5 })
  assert.equal(Model.timeLabel(e, true), "14:05")
  assert.equal(Model.timeLabel(e, false), "2:05 PM")
  assert.equal(Model.timeLabel(ev({ fromH: 0, fromM: 30 }), false), "12:30 AM")
  assert.equal(Model.timeLabel(ev({ allDay: true }), true), "")
})

test("Konferenz-Links: dcal kennt BigBlueButton nicht, das Model schon", () => {
  // dcal fuellt meetingUrl -> der gewinnt.
  assert.equal(Model.meetingUrlFor({ meetingUrl: "https://zoom.us/j/1", location: "egal" }),
    "https://zoom.us/j/1")
  // Leer, aber der Ort ist ein BBB-Raum: genau der Fall bei Correctiv.
  assert.equal(Model.meetingUrlFor({ meetingUrl: "", location: "https://bbb.correctiv.org/rooms/cr5-91d/join" }),
    "https://bbb.correctiv.org/rooms/cr5-91d/join")
  // Im Einladungstext versteckt, mit Satzzeichen dahinter.
  assert.equal(Model.meetingUrlFor({ meetingUrl: "", location: "",
    description: "Wir treffen uns hier: https://meet.jit.si/raum-x. Bis dann!" }),
    "https://meet.jit.si/raum-x")
  // Ein gewoehnlicher Link ist keine Konferenz.
  assert.equal(Model.meetingUrlFor({ meetingUrl: "", location: "",
    description: "Agenda unter https://docs.google.com/document/d/abc/edit" }), "")
  assert.equal(Model.meetingUrlFor({ location: "Huddly Huddle" }), "")
  assert.equal(Model.meetingUrlFor(null), "")
})

test("Konferenz-Hosts werden auf Subdomains erkannt, aber nicht auf Namensvettern", () => {
  assert.equal(Model.looksLikeMeeting("https://us06web.zoom.us/j/9"), true)
  assert.equal(Model.looksLikeMeeting("https://bbb.example.org/x"), true)
  assert.equal(Model.looksLikeMeeting("https://vc.rwth-aachen.de/x"), true)
  assert.equal(Model.looksLikeMeeting("https://notzoom.us.evil.test/x"), false)
  assert.equal(Model.looksLikeMeeting("https://correctiv.org/artikel"), false)
  assert.equal(Model.looksLikeMeeting("nicht-mal-eine-url"), false)
})

test("der Ort verschwindet, wenn er nur der Konferenz-Link ist", () => {
  const bbb = "https://bbb.correctiv.org/rooms/cr5/join"
  assert.equal(Model.locationLabel({ location: bbb, meetingUrl: "" }), "")
  assert.equal(Model.locationLabel({ location: "Raum 3.14", meetingUrl: bbb }), "Raum 3.14")
})

test("Jahresfortschritt: Anfang 0 Prozent, Ende 100", () => {
  assert.equal(Model.yearProgressPercent(2026, 0, 1), 0)
  assert.equal(Model.yearProgressPercent(2026, 11, 31), 100)
  assert.equal(Model.daysInYear(2024), 366)   // Schaltjahr
  assert.equal(Model.daysInYear(2026), 365)
  assert.equal(Model.yearProgressPercent(2026, 9, 8), 77)
})
