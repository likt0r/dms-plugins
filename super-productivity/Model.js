// Reine Datenlogik fuer das Todo-Slideout: API-Antworten lesen, "Heute"
// bestimmen, Tasks nach Projekt gruppieren, Bodies fuer neue Tasks bauen.
//
// Qt-frei, damit `node --test tests/` sie pruefen kann. Die Tasks kommen so,
// wie die lokale REST-API von Super Productivity sie liefert (GET /tasks):
// flach, Unteraufgaben als eigene Eintraege mit parentId, der Elternteil
// listet sie in subTaskIds.

var INBOX_ID = "INBOX_PROJECT"
var FILTER_TODAY = "today"
var FILTER_ALL = "all"

// ---- API

// Jede Antwort von bin/sp-api ist {"ok":true,"data":...} oder
// {"ok":false,"error":{code,message}}. Alles andere (leere Ausgabe,
// abgebrochener Prozess) wird zu einem Fehler mit Code PARSE.
function parseResponse(text) {
  var parsed
  try {
    parsed = JSON.parse(String(text || "").trim())
  } catch (e) {
    return { ok: false, data: null, code: "PARSE", message: "Unlesbare Antwort von sp-api" }
  }
  if (!parsed || typeof parsed !== "object")
    return { ok: false, data: null, code: "PARSE", message: "Unlesbare Antwort von sp-api" }
  if (parsed.ok === true)
    return { ok: true, data: parsed.data, code: "", message: "" }
  var err = parsed.error || {}
  return { ok: false, data: null, code: String(err.code || "UNKNOWN"), message: String(err.message || "Unbekannter Fehler") }
}

// OFFLINE und NO_TOKEN heissen "SP ist nicht erreichbar" -- dafuer zeigt das
// Panel einen Startknopf statt einer Fehlermeldung.
function isUnreachable(code) {
  return code === "OFFLINE" || code === "NO_TOKEN" || code === "TIMEOUT"
}

// ---- Datum

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

// SP rechnet "heute" in lokaler Zeit als YYYY-MM-DD (dueDay).
function dayKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function startOfDayMs(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
}

// Wie SP selbst (tagId=TODAY): dueWithTime innerhalb des Tages, sonst
// dueDay gleich heute.
function isDueToday(task, now) {
  if (typeof task.dueWithTime === "number" && task.dueWithTime > 0) {
    var start = startOfDayMs(now)
    return task.dueWithTime >= start && task.dueWithTime < start + 86400000
  }
  return task.dueDay === dayKey(now)
}

// Ueberfaellig: offen und faellig vor heute. SP zeigt solche Tasks in
// "Heute" als ueberfaellig an; das Panel tut dasselbe.
function isOverdue(task, now) {
  if (task.isDone) return false
  if (typeof task.dueWithTime === "number" && task.dueWithTime > 0)
    return task.dueWithTime < startOfDayMs(now)
  return typeof task.dueDay === "string" && task.dueDay !== "" && task.dueDay < dayKey(now)
}

function isForToday(task, now) {
  return isDueToday(task, now) || isOverdue(task, now)
}

// ---- Projekte

// Sichtbare Projekte in der Reihenfolge der API, Inbox zuerst.
function visibleProjects(projects) {
  var list = (projects || []).filter(function (p) {
    return p && !p.isArchived && !p.isHiddenFromMenu
  })
  list.sort(function (a, b) {
    return (a.id === INBOX_ID ? 0 : 1) - (b.id === INBOX_ID ? 0 : 1)
  })
  return list
}

// Projekt fuer neue Tasks aus der Einstellung: ID oder Name (ohne Ruecksicht
// auf Gross-/Kleinschreibung), sonst Inbox.
function resolveProjectId(projects, nameOrId) {
  var key = String(nameOrId || "").trim()
  if (!key) return INBOX_ID
  var list = visibleProjects(projects)
  for (var i = 0; i < list.length; i++)
    if (list[i].id === key) return key
  var lower = key.toLowerCase()
  for (var j = 0; j < list.length; j++)
    if (String(list[j].title || "").toLowerCase() === lower) return list[j].id
  return INBOX_ID
}

function projectColor(project) {
  return (project && project.theme && project.theme.primary) || ""
}

// ---- Filter und Zaehlung

// Nur Tasks ohne Elternteil zaehlen: eine Unteraufgabe ist Teil ihres
// Elternteils, keine eigene Zeile in der Bar-Zahl.
function openTopLevel(tasks) {
  return (tasks || []).filter(function (t) { return !t.isDone && !t.parentId })
}

function matchesFilter(task, filter, now) {
  if (filter === FILTER_ALL) return true
  if (filter === FILTER_TODAY) return isForToday(task, now)
  return task.projectId === filter
}

function countOpen(tasks, filter, now) {
  return openTopLevel(tasks).filter(function (t) { return matchesFilter(t, filter, now) }).length
}

// Chips oben im Panel: Heute, Alle, dann jedes sichtbare Projekt. Die Zahl
// steht nur dran, wenn sie nicht null ist (DFilterChips blendet 0 aus).
function filterChips(tasks, projects, now) {
  var chips = [
    { value: FILTER_TODAY, label: "Heute", count: countOpen(tasks, FILTER_TODAY, now) },
    { value: FILTER_ALL, label: "Alle", count: countOpen(tasks, FILTER_ALL, now) }
  ]
  visibleProjects(projects).forEach(function (p) {
    chips.push({ value: p.id, label: p.title, count: countOpen(tasks, p.id, now) })
  })
  return chips
}

// Faellt ein gespeicherter Filter weg (Projekt archiviert), zurueck auf Heute.
function normalizeFilter(filter, projects) {
  if (filter === FILTER_TODAY || filter === FILTER_ALL) return filter
  var known = visibleProjects(projects).some(function (p) { return p.id === filter })
  return known ? filter : FILTER_TODAY
}

// ---- Zeilen fuer die Liste

// Reihenfolge innerhalb eines Projekts: wie in SP (project.taskIds), was
// dort fehlt (etwa aus dem Backlog), hinten nach Anlegedatum.
function orderIn(project, tasks) {
  var order = {}
  var ids = (project && project.taskIds) || []
  for (var i = 0; i < ids.length; i++) order[ids[i]] = i
  return tasks.slice().sort(function (a, b) {
    var ia = order[a.id], ib = order[b.id]
    var ha = ia !== undefined, hb = ib !== undefined
    if (ha && hb) return ia - ib
    if (ha !== hb) return ha ? -1 : 1
    return (a.created || 0) - (b.created || 0)
  })
}

function dueBadge(task, now) {
  if (isOverdue(task, now)) return "overdue"
  if (isDueToday(task, now)) return "today"
  return ""
}

function taskRow(task, depth, now, currentId) {
  return {
    kind: "task",
    id: task.id,
    title: String(task.title || ""),
    isDone: task.isDone === true,
    depth: depth,
    due: dueBadge(task, now),
    timeSpent: Number(task.timeSpent) || 0,
    isCurrent: task.id === currentId,
    subCount: (task.subTaskIds || []).length,
    notes: notesOf(task)
  }
}

// Flache Liste fuer den ListView: Kopfzeilen je Projekt (nur bei Heute und
// Alle), darunter offene Tasks mit ihren Unteraufgaben eingerueckt. Erledigte
// Tasks landen gesammelt unter "Erledigt" am Ende, wenn showDone gesetzt ist;
// sonst steht dort nur die Zahl, damit man weiss, dass es sie gibt.
//
// Eine Unteraufgabe, deren Elternteil nicht in den Filter faellt (etwa nur
// die Unteraufgabe ist heute faellig), erscheint als eigene Zeile.
function buildRows(tasks, projects, filter, now, opts) {
  opts = opts || {}
  var currentId = opts.currentId || null
  var all = tasks || []
  var byId = {}
  all.forEach(function (t) { byId[t.id] = t })

  var open = all.filter(function (t) { return !t.isDone && matchesFilter(t, filter, now) })
  var openIds = {}
  open.forEach(function (t) { openIds[t.id] = true })

  // Wurzeln: offene Tasks ohne (sichtbaren) Elternteil.
  var roots = open.filter(function (t) { return !t.parentId || !openIds[t.parentId] })

  var grouped = filter === FILTER_ALL || filter === FILTER_TODAY
  var projectList = visibleProjects(projects)
  var projectById = {}
  ;(projects || []).forEach(function (p) { projectById[p.id] = p })

  var rows = []

  function pushTree(task) {
    rows.push(taskRow(task, task.parentId && openIds[task.parentId] ? 1 : 0, now, currentId))
    ;(task.subTaskIds || []).forEach(function (sid) {
      var sub = byId[sid]
      if (sub && openIds[sid]) rows.push(taskRow(sub, 1, now, currentId))
    })
  }

  if (grouped) {
    // Projekte in Menue-Reihenfolge, dann Tasks aus unbekannten/versteckten
    // Projekten unter "Sonstige", damit nichts still verschwindet.
    var seen = {}
    projectList.forEach(function (p) {
      seen[p.id] = true
      var mine = roots.filter(function (t) { return t.projectId === p.id })
      if (!mine.length) return
      rows.push({ kind: "header", id: "h:" + p.id, title: String(p.title || ""), color: projectColor(p), count: mine.length, notes: projectNoteCount(p) })
      orderIn(p, mine).forEach(pushTree)
    })
    var rest = roots.filter(function (t) { return !seen[t.projectId] })
    if (rest.length) {
      rows.push({ kind: "header", id: "h:other", title: "Sonstige", color: "", count: rest.length, notes: 0 })
      orderIn(null, rest).forEach(pushTree)
    }
  } else {
    orderIn(projectById[filter], roots).forEach(pushTree)
  }

  // Erledigte: nur Tasks ohne Elternteil, die in den Filter fallen. Bei
  // "Heute" zaehlt, was heute erledigt wurde -- faellig war es dann ja nicht
  // mehr unbedingt heute.
  var todayStart = startOfDayMs(now)
  var done = all.filter(function (t) {
    if (!t.isDone || t.parentId) return false
    if (filter === FILTER_TODAY) return (t.doneOn || 0) >= todayStart || isDueToday(t, now)
    return matchesFilter(t, filter, now)
  })
  done.sort(function (a, b) { return (b.doneOn || 0) - (a.doneOn || 0) })
  if (done.length) {
    rows.push({ kind: "doneHeader", id: "h:done", title: "Erledigt", count: done.length })
    if (opts.showDone) done.forEach(function (t) { rows.push(taskRow(t, 0, now, currentId)) })
  }
  return rows
}

// ---- Neue Tasks

// Body fuer POST /tasks. Unter "Heute" bekommt der Task dueDay = heute und
// landet im Standardprojekt; unter einem Projekt landet er dort.
function createBody(title, filter, now, defaultProjectId) {
  var t = String(title || "").trim()
  if (!t) return null
  var body = { title: t }
  if (filter === FILTER_TODAY) {
    body.dueDay = dayKey(now)
    body.projectId = defaultProjectId || INBOX_ID
  } else if (filter === FILTER_ALL) {
    body.projectId = defaultProjectId || INBOX_ID
  } else {
    body.projectId = filter
  }
  return body
}

// ---- Notizen

// SP speichert Notizen als Markdown-Text im Feld "notes". Ohne Notiz fehlt
// das Feld in der API-Antwort ganz.
function notesOf(task) {
  var n = task && task.notes
  return typeof n === "string" ? n : ""
}

function hasNotes(task) {
  return notesOf(task).trim() !== ""
}

// Projekt-Notizen: die API liefert pro Projekt nur noteIds, die Notizen
// selbst hat sie nicht (keine Route /notes). Fuer einen Marker reicht die Zahl.
function projectNoteCount(project) {
  return ((project && project.noteIds) || []).length
}

function projectById(projects, id) {
  for (var i = 0; i < (projects || []).length; i++)
    if (projects[i].id === id) return projects[i]
  return null
}

// Was gespeichert wird: Windows-Zeilenenden vereinheitlicht, Leerraum am
// Ende weg -- sonst landet jedes versehentliche Enter in SP.
function normalizeNotes(text) {
  return String(text || "").replace(/\r\n?/g, "\n").replace(/\s+$/, "")
}

// Body fuer PATCH /tasks/:id, oder null, wenn sich nichts geaendert hat.
function notesPatch(oldNotes, newText) {
  var next = normalizeNotes(newText)
  return next === normalizeNotes(oldNotes) ? null : { notes: next }
}

// ---- Anzeige

// "25 min", "1:05 h" -- leer bei null, damit Zeilen ohne erfasste Zeit
// nicht "0 min" tragen.
function durationLabel(ms) {
  var min = Math.floor((Number(ms) || 0) / 60000)
  if (min <= 0) return ""
  if (min < 60) return min + " min"
  return Math.floor(min / 60) + ":" + pad2(min % 60) + " h"
}

function truncate(text, max) {
  var s = String(text || "")
  return s.length > max ? s.substring(0, max - 1) + "…" : s
}

if (typeof module !== "undefined") {
  module.exports = {
    INBOX_ID: INBOX_ID,
    FILTER_TODAY: FILTER_TODAY,
    FILTER_ALL: FILTER_ALL,
    parseResponse: parseResponse,
    isUnreachable: isUnreachable,
    dayKey: dayKey,
    isDueToday: isDueToday,
    isOverdue: isOverdue,
    isForToday: isForToday,
    visibleProjects: visibleProjects,
    resolveProjectId: resolveProjectId,
    projectColor: projectColor,
    countOpen: countOpen,
    filterChips: filterChips,
    normalizeFilter: normalizeFilter,
    buildRows: buildRows,
    createBody: createBody,
    notesOf: notesOf,
    projectNoteCount: projectNoteCount,
    projectById: projectById,
    hasNotes: hasNotes,
    normalizeNotes: normalizeNotes,
    notesPatch: notesPatch,
    durationLabel: durationLabel,
    truncate: truncate
  }
}
