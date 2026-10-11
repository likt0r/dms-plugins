const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

// Fester Zeitpunkt: Samstag, 10.10.2026, 15:00 lokal.
const NOW = new Date(2026, 9, 10, 15, 0)

// Tasks in der Form von GET /tasks.
function task(o) {
  return {
    id: o.id,
    title: o.title || o.id,
    isDone: o.isDone === true,
    projectId: o.projectId || "INBOX_PROJECT",
    tagIds: [],
    subTaskIds: o.subTaskIds || [],
    parentId: o.parentId,
    dueDay: o.dueDay,
    dueWithTime: o.dueWithTime,
    doneOn: o.doneOn,
    created: o.created || 0,
    timeSpent: o.timeSpent || 0,
  }
}

const PROJECTS = [
  { id: "privat", title: "Privat", taskIds: ["b", "a"], theme: { primary: "#29b6f6" } },
  { id: "INBOX_PROJECT", title: "Inbox", taskIds: [] },
  { id: "alt", title: "Alt", isArchived: true, taskIds: [] },
  { id: "versteckt", title: "Versteckt", isHiddenFromMenu: true, taskIds: [] },
]

test("parseResponse liest Erfolg und Fehler von sp-api", () => {
  const ok = Model.parseResponse('{"ok":true,"data":[1,2]}\n')
  assert.equal(ok.ok, true)
  assert.deepEqual(ok.data, [1, 2])

  const err = Model.parseResponse('{"ok":false,"error":{"code":"OFFLINE","message":"weg"}}')
  assert.equal(err.ok, false)
  assert.equal(err.code, "OFFLINE")
  assert.equal(err.message, "weg")

  assert.equal(Model.parseResponse("").code, "PARSE")
  assert.equal(Model.parseResponse("Segfault").code, "PARSE")
  assert.equal(Model.parseResponse("null").code, "PARSE")
})

test("nicht erreichbar heisst: SP aus, API aus oder haengt", () => {
  for (const c of ["OFFLINE", "NO_TOKEN", "TIMEOUT"]) assert.ok(Model.isUnreachable(c), c)
  assert.ok(!Model.isUnreachable("TASK_NOT_FOUND"))
})

test("heute faellig ueber dueDay oder dueWithTime", () => {
  assert.equal(Model.dayKey(NOW), "2026-10-10")
  assert.ok(Model.isDueToday(task({ id: "x", dueDay: "2026-10-10" }), NOW))
  assert.ok(!Model.isDueToday(task({ id: "x", dueDay: "2026-10-11" }), NOW))
  assert.ok(Model.isDueToday(task({ id: "x", dueWithTime: new Date(2026, 9, 10, 23, 30).getTime() }), NOW))
  assert.ok(!Model.isDueToday(task({ id: "x", dueWithTime: new Date(2026, 9, 11, 0, 0).getTime() }), NOW))
  // dueWithTime schlaegt ein (veraltetes) dueDay, wie in SP.
  assert.ok(!Model.isDueToday(task({ id: "x", dueDay: "2026-10-10", dueWithTime: new Date(2026, 9, 12).getTime() }), NOW))
})

test("ueberfaellig nur, wenn offen und vor heute", () => {
  assert.ok(Model.isOverdue(task({ id: "x", dueDay: "2026-10-09" }), NOW))
  assert.ok(!Model.isOverdue(task({ id: "x", dueDay: "2026-10-09", isDone: true }), NOW))
  assert.ok(!Model.isOverdue(task({ id: "x", dueDay: "2026-10-10" }), NOW))
  assert.ok(!Model.isOverdue(task({ id: "x" }), NOW))
  assert.ok(Model.isOverdue(task({ id: "x", dueWithTime: new Date(2026, 9, 9, 18).getTime() }), NOW))
  assert.ok(Model.isForToday(task({ id: "x", dueDay: "2026-09-01" }), NOW))
})

test("sichtbare Projekte: ohne archivierte und versteckte, Inbox zuerst", () => {
  assert.deepEqual(Model.visibleProjects(PROJECTS).map(p => p.id), ["INBOX_PROJECT", "privat"])
})

test("Standardprojekt per Name oder ID, sonst Inbox", () => {
  assert.equal(Model.resolveProjectId(PROJECTS, ""), "INBOX_PROJECT")
  assert.equal(Model.resolveProjectId(PROJECTS, "privat"), "privat")
  assert.equal(Model.resolveProjectId(PROJECTS, " PRIVAT "), "privat")
  assert.equal(Model.resolveProjectId(PROJECTS, "Alt"), "INBOX_PROJECT")
  assert.equal(Model.resolveProjectId(PROJECTS, "gibtsnicht"), "INBOX_PROJECT")
})

test("Chips zaehlen offene Tasks ohne Unteraufgaben", () => {
  const tasks = [
    task({ id: "a", projectId: "privat", dueDay: "2026-10-10", subTaskIds: ["a1"] }),
    task({ id: "a1", projectId: "privat", parentId: "a" }),
    task({ id: "b", projectId: "privat" }),
    task({ id: "c", isDone: true, dueDay: "2026-10-10" }),
    task({ id: "d" }),
  ]
  const chips = Model.filterChips(tasks, PROJECTS, NOW)
  assert.deepEqual(chips.map(c => [c.value, c.label, c.count]), [
    ["today", "Heute", 1],
    ["all", "Alle", 3],
    ["INBOX_PROJECT", "Inbox", 1],
    ["privat", "Privat", 2],
  ])
})

test("ein verschwundenes Projekt als Filter faellt auf Heute zurueck", () => {
  assert.equal(Model.normalizeFilter("privat", PROJECTS), "privat")
  assert.equal(Model.normalizeFilter("alt", PROJECTS), "today")
  assert.equal(Model.normalizeFilter("gibtsnicht", PROJECTS), "today")
  assert.equal(Model.normalizeFilter("all", PROJECTS), "all")
})

test("Alle: Kopf je Projekt, Reihenfolge wie in SP, Unteraufgaben eingerueckt", () => {
  const tasks = [
    task({ id: "a", projectId: "privat", subTaskIds: ["a1", "a2"] }),
    task({ id: "a1", projectId: "privat", parentId: "a" }),
    task({ id: "a2", projectId: "privat", parentId: "a", isDone: true }),
    task({ id: "b", projectId: "privat" }),
    task({ id: "i", projectId: "INBOX_PROJECT" }),
  ]
  const rows = Model.buildRows(tasks, PROJECTS, "all", NOW)
  assert.deepEqual(rows.map(r => [r.kind, r.id, r.depth]), [
    ["header", "h:INBOX_PROJECT", undefined],
    ["task", "i", 0],
    ["header", "h:privat", undefined],
    ["task", "b", 0],
    ["task", "a", 0],
    ["task", "a1", 1],
  ])
  assert.equal(rows[2].color, "#29b6f6")
  assert.equal(rows[2].count, 2)
})

test("Projektfilter: keine Kopfzeilen", () => {
  const tasks = [task({ id: "a", projectId: "privat" }), task({ id: "i" })]
  const rows = Model.buildRows(tasks, PROJECTS, "privat", NOW)
  assert.deepEqual(rows.map(r => r.id), ["a"])
})

test("Heute: faellige und ueberfaellige, Unteraufgabe ohne faelligen Elternteil steht allein", () => {
  const tasks = [
    task({ id: "p", projectId: "privat", subTaskIds: ["s"] }),
    task({ id: "s", projectId: "privat", parentId: "p", dueDay: "2026-10-10" }),
    task({ id: "late", dueDay: "2026-10-01" }),
    task({ id: "later", dueDay: "2026-10-20" }),
  ]
  const rows = Model.buildRows(tasks, PROJECTS, "today", NOW)
  const taskRows = rows.filter(r => r.kind === "task")
  assert.deepEqual(taskRows.map(r => [r.id, r.depth, r.due]), [
    ["late", 0, "overdue"],
    ["s", 0, "today"],
  ])
})

test("Tasks aus versteckten Projekten verschwinden nicht, sondern stehen unter Sonstige", () => {
  const rows = Model.buildRows([task({ id: "v", projectId: "versteckt" })], PROJECTS, "all", NOW)
  assert.deepEqual(rows.map(r => r.id), ["h:other", "v"])
})

test("Erledigte: nur die Zahl, ausgeklappt neueste zuerst", () => {
  const tasks = [
    task({ id: "o" }),
    task({ id: "d1", isDone: true, doneOn: 100 }),
    task({ id: "d2", isDone: true, doneOn: 200 }),
  ]
  const closed = Model.buildRows(tasks, PROJECTS, "all", NOW)
  assert.deepEqual(closed.slice(-1).map(r => [r.kind, r.count]), [["doneHeader", 2]])

  const open = Model.buildRows(tasks, PROJECTS, "all", NOW, { showDone: true })
  assert.deepEqual(open.slice(-2).map(r => [r.id, r.isDone]), [["d2", true], ["d1", true]])
})

test("Heute zeigt als erledigt, was heute abgehakt wurde", () => {
  const tasks = [
    task({ id: "heute", isDone: true, doneOn: new Date(2026, 9, 10, 9).getTime() }),
    task({ id: "gestern", isDone: true, doneOn: new Date(2026, 9, 9, 9).getTime() }),
  ]
  const rows = Model.buildRows(tasks, PROJECTS, "today", NOW, { showDone: true })
  assert.deepEqual(rows.filter(r => r.kind === "task").map(r => r.id), ["heute"])
})

test("der laufende Task ist markiert", () => {
  const rows = Model.buildRows([task({ id: "a" }), task({ id: "b" })], PROJECTS, "INBOX_PROJECT", NOW, { currentId: "b" })
  assert.deepEqual(rows.map(r => r.isCurrent), [false, true])
})

test("createBody: Heute setzt dueDay, Projekt setzt projectId", () => {
  assert.equal(Model.createBody("   ", "today", NOW, ""), null)
  assert.deepEqual(Model.createBody(" Milch ", "today", NOW, ""), { title: "Milch", dueDay: "2026-10-10", projectId: "INBOX_PROJECT" })
  assert.deepEqual(Model.createBody("Milch", "today", NOW, "privat"), { title: "Milch", dueDay: "2026-10-10", projectId: "privat" })
  assert.deepEqual(Model.createBody("Milch", "all", NOW, ""), { title: "Milch", projectId: "INBOX_PROJECT" })
  assert.deepEqual(Model.createBody("Milch", "privat", NOW, "x"), { title: "Milch", projectId: "privat" })
})

test("Dauer: leer bei null, Minuten, Stunden", () => {
  assert.equal(Model.durationLabel(0), "")
  assert.equal(Model.durationLabel(59000), "")
  assert.equal(Model.durationLabel(25 * 60000), "25 min")
  assert.equal(Model.durationLabel(65 * 60000), "1:05 h")
})

test("Notizen: fehlendes Feld ist leer, Patch nur bei Aenderung", () => {
  assert.equal(Model.notesOf({ id: "a" }), "")
  assert.equal(Model.notesOf({ notes: "- [x] eins" }), "- [x] eins")
  assert.equal(Model.hasNotes({ notes: "  \n " }), false)
  assert.equal(Model.hasNotes({ notes: "x" }), true)
  assert.equal(Model.normalizeNotes("a\r\nb\r\n\n  "), "a\nb")
  assert.equal(Model.notesPatch("a\nb", "a\r\nb\n"), null, "nur Zeilenenden/Leerraum am Ende: nichts zu speichern")
  assert.deepEqual(Model.notesPatch("", "neu"), { notes: "neu" })
  assert.deepEqual(Model.notesPatch("alt", ""), { notes: "" }, "Leeren ist eine Aenderung")
  assert.equal(Model.buildRows([{ id: "t", title: "T", projectId: "INBOX_PROJECT", notes: "n" }], [], Model.FILTER_ALL, NOW, {})
    .find(r => r.kind === "task").notes, "n")
})

// ---- Verdrahtung: Manifest, Settings und Widget passen zusammen.

test("Manifest, Settings und Widget sind konsistent", () => {
  const root = path.join(__dirname, "..")
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "plugin.json"), "utf8"))
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/)
  assert.match(manifest.id, /^[a-zA-Z][a-zA-Z0-9]*$/, "id must be camelCase")
  assert.equal(manifest.type, "widget")
  for (const entry of [manifest.component, manifest.settings])
    assert.ok(fs.existsSync(path.join(root, entry)), entry)

  const widget = fs.readFileSync(path.join(root, manifest.component), "utf8")
  const settings = fs.readFileSync(path.join(root, manifest.settings), "utf8")
  const read = [...widget.matchAll(/pluginData\?\.(\w+)/g)].map(m => m[1])
  const declared = [...settings.matchAll(/settingKey: "(\w+)"/g)].map(m => m[1])
  for (const key of new Set(read))
    assert.ok(declared.includes(key), `widget reads pluginData.${key} but Settings.qml never declares it`)
  assert.equal(settings.match(/pluginId: "(\w+)"/)[1], manifest.id)
  assert.match(widget, new RegExp(`target: "${manifest.id}"`), "IPC target = plugin id")
  assert.match(widget, /bin\/sp-api/)

  const helper = fs.statSync(path.join(root, "bin", "sp-api"))
  assert.ok(helper.mode & 0o100, "bin/sp-api must be executable")
})
