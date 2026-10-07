import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import qs.DankCommon.Common as DC
import "Model.js" as Model

// Scribe: markierten Text korrigieren, Ergebnis in die Zwischenablage.
// Port des Omarchy-Plugins likt0r.scribe auf DMS (Zuordnung:
// docs/omarchy-to-dms.md im dotfiles-Repo). Das `scribe`-CLI macht die Arbeit
// und ist der einzige Schreiber der History; dieses Widget liest sie ueber
// einen FileView mit Watcher.
//
// Was gegenueber dem Original anders ist:
// - PluginComponent statt Ui.Panel; das Management-Popup ist Teil der einen
//   Overlay-Flaeche (Picker-Grid, Composer, Karte) wie im Original.
// - Statt broadcast() ueber bar.moduleWidgets() synchronisiert PluginGlobalVar
//   den Lauf-Zustand ueber alle Bar-Instanzen (zwei Monitore, zwei Pills).
// - Der fokussierte Monitor kommt von CompositorService.getFocusedScreen()
//   statt Hyprland.focusedMonitor.
// - Kein Mittelklick (PluginComponent kennt nur links/rechts): correctNow
//   bleibt per IPC erreichbar.
// - Nerd-Font-Glyphen (Prompt-Icons) rendern ueber die von DMS gebuendelte
//   FiraCode Nerd Font (DC.Fonts.nerd); die UI-Icons sind Material Symbols.
PluginComponent {
    id: root

    property var popoutService: null

    // ------------------------------------------------------------- settings

    readonly property string backend: pluginData?.backend ?? "anthropic"
    readonly property string model: pluginData?.model ?? "claude-opus-5"
    readonly property string endpoint: pluginData?.endpoint ?? ""
    readonly property string effort: pluginData?.effort ?? ""
    readonly property string profile: pluginData?.profile ?? "Grammar"
    readonly property int timeoutSec: Number(pluginData?.timeoutSec ?? 30) || 30
    readonly property bool clipboardFallback: (pluginData?.clipboardFallback ?? true) === true
    readonly property bool notifyOnDone: (pluginData?.notify ?? true) === true
    readonly property bool historyEnabled: (pluginData?.historyEnabled ?? true) === true
    readonly property bool historyStoreText: (pluginData?.historyStoreText ?? true) === true
    readonly property int historyLimit: Number(pluginData?.historyLimit ?? 50)

    function updateSetting(key, value) {
        pluginService?.savePluginData(root.pluginId, key, value)
    }

    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/dms/scribe"
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/dms/scribe"

    // ------------------------------------------------------------ run state

    // Der Zustand lebt in PluginGlobalVars statt in Instanz-Properties: jede
    // Bar laedt ihr eigenes Widget, und ein Zustand, der nur auf der Instanz
    // gesetzt wuerde, die den IPC-Zuschlag bekam, liesse die Pill des anderen
    // Monitors einen alten Zustand malen (das broadcast() des Originals).
    PluginGlobalVar { id: gRunState; varName: "runState"; defaultValue: Model.STATE_IDLE }
    PluginGlobalVar { id: gLastError; varName: "lastError"; defaultValue: "" }
    PluginGlobalVar { id: gLastExit; varName: "lastExitCode"; defaultValue: 0 }
    PluginGlobalVar { id: gConfigFailed; varName: "configFailed"; defaultValue: false }

    readonly property string runState: gRunState.value
    readonly property string lastError: gLastError.value
    readonly property int lastExitCode: gLastExit.value
    readonly property bool busy: Model.isBusy(runState)
    property var lastResult: null

    function apply(event) {
        gRunState.set(Model.nextState(gRunState.value, event))
    }

    // Der Keybind fragt erst, welcher Prompt es sein soll; Skript-Pfade laufen
    // direkt -- siehe correctNow().
    function correct() {
        openPicker()
    }

    function correctNow() {
        correctWith("")
    }

    // Einmal-Anweisung statt gespeichertem Prompt. Das CLI packt sie in die
    // Regeln, die die Markierung als Daten quarantaenisieren; hier wird nur
    // eine leere frueh abgewiesen, damit UI und Skript gleich antworten.
    function correctCustom(instruction) {
        var text = String(instruction || "").trim()
        if (text === "") return
        correctWith("", text)
    }

    // `profileOverride` ist die Antwort des Pickers, leer fuer "was die
    // Einstellungen sagen". Es beruehrt die gespeicherte Einstellung nie.
    function correctWith(profileOverride, instructionOverride) {
        // Ein zweiter Druck mitten im Lauf wird bewusst ignoriert statt
        // eingereiht: zwei Adapter im Wettlauf auf wl-copy hinterlassen die
        // Zwischenablage mit dem, der zuletzt fertig wurde.
        if (busy) return
        gLastError.set("")
        apply("start")
        correctProc.command = commandFor(profileOverride, instructionOverride)
        correctProc.running = true
    }

    function cancel() {
        // Abbrechen heisst "hoer auf mit dem, was du angefangen hast", und ein
        // offener Picker ist das Erste, was zaehlt. Rechtsklick und das
        // IPC-Verb raeumen das Overlay auch dann weg, wenn drinnen etwas klemmt.
        if (pickerOpen) {
            closePicker()
            return
        }
        if (!busy) return
        correctProc.running = false
        apply("cancel")
    }

    function commandFor(profileOverride, instructionOverride) {
        var argv = [
            pluginDir + "/scribe", "run", "--json",
            "--backend", backend,
            "--model", model,
            "--profile", profileOverride ? profileOverride : profile,
            "--timeout", String(timeoutSec),
            "--history-limit", String(historyLimit)
        ]
        if (instructionOverride) argv = argv.concat(["--instruction", instructionOverride])
        if (endpoint !== "") argv = argv.concat(["--endpoint", endpoint])
        if (effort !== "") argv = argv.concat(["--effort", effort])
        if (!clipboardFallback) argv.push("--no-clipboard-fallback")
        if (!notifyOnDone) argv.push("--no-notify")
        if (!historyEnabled) argv.push("--no-history")
        else if (!historyStoreText) argv.push("--history-metadata-only")
        return argv
    }

    function succeed(result) {
        lastResult = result
        gLastExit.set(0)
        gLastError.set("")
        apply("succeed")
    }

    function fail(code, stderr) {
        gLastExit.set(code)
        gLastError.set(Model.errorMessage(code, stderr))
        apply("fail")
    }

    // Anders als "fail" kommt das im Leerlauf an -- beim Start oder wenn der
    // Watcher die Datei kippen sieht -- und muss das Icon trotzdem rot faerben.
    function misconfigured(code, message) {
        gConfigFailed.set(true)
        gLastExit.set(code)
        gLastError.set(message)
        promptsError = message
        apply("misconfigure")
    }

    // Der Config-Fehler ueberlebte sonst seine Ursache: nichts ausser einer
    // erfolgreichen Korrektur raeumte lastError weg.
    function recovered() {
        if (!gConfigFailed.value) return
        gConfigFailed.set(false)
        gLastExit.set(0)
        gLastError.set("")
        promptsError = ""
        apply("acknowledge")
    }

    // ---------------------------------------------------------- panel state

    property int tabIndex: 0            // 0 = History, 1 = Prompts, 2 = Einstellungen
    readonly property var tabNav: [
        { label: "History", icon: "history" },
        { label: "Prompts", icon: "edit_note" },
        { label: "Einstellungen", icon: "settings" }
    ]
    property int expandedIndex: -1
    property var history: []
    property var profiles: []
    property var backendNames: []
    property string doctorReport: ""

    readonly property var profileTitles: profiles.map(function(p) { return p.title || p.name })

    function profileNameForTitle(title) {
        for (var i = 0; i < profiles.length; i++)
            if ((profiles[i].title || profiles[i].name) === title) return profiles[i].name
        return title
    }

    function refresh() {
        historyFile.reload()
        profilesProc.running = true
        backendsProc.running = true
    }

    // ---------------------------------------------------------- prompt picker

    property bool pickerOpen: false
    property int pickerIndex: 0
    property string pendingProfile: ""
    property string pendingInstruction: ""
    property bool pickerWanted: false

    // "grid" waehlt einen gespeicherten Prompt, "compose" tippt eine
    // Einmal-Anweisung. lastInstruction lebt nur im Speicher.
    property string pickerMode: "grid"
    property string lastInstruction: ""

    // Eine Kachel mehr als Prompts: die letzte oeffnet den Composer.
    readonly property int pickerCount: profiles.length + 1
    readonly property int pickerColumns: Model.gridColumns(pickerCount)

    // ----------------------------------------------------------- overlay view

    // Eine Layer-Flaeche, eine Ansicht zur Zeit. `manageOpen` ersetzt das
    // `opened` der Omarchy-Basisklasse.
    property bool manageOpen: false
    readonly property string overlayView:
        pickerOpen ? pickerMode : (manageOpen ? "manage" : "")
    readonly property bool overlayVisible: overlayView !== ""

    // Der Monitor, auf dem das Overlay liegt: einmal beim Oeffnen bestimmt und
    // dann in Ruhe gelassen, damit die Flaeche nicht unter dem Nutzer den
    // Bildschirm wechselt, sobald woanders etwas den Fokus nimmt.
    property var overlayScreen: null

    function adoptOverlayScreen() {
        overlayScreen = CompositorService.getFocusedScreen()
            || root.parentScreen || null
    }

    function dismissOverlay() {
        if (pickerOpen) closePicker()
        else if (manageOpen) closeManage()
    }

    function openManage(index) {
        tabIndex = Math.max(0, Math.min(2, index))
        // Das Overlay steht schon, also behaelt es seinen Bildschirm.
        var keep = overlayScreen
        closePicker()
        openManageCard()
        overlayScreen = keep
    }

    function openManageCard() {
        if (manageOpen) return
        if (!overlayVisible) adoptOverlayScreen()
        // Die Karte zu oeffnen ist die Quittung fuer einen klebrigen Fehler.
        if (runState === Model.STATE_ERROR) apply("acknowledge")
        expandedIndex = -1
        manageOpen = true
        refresh()
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    function closeManage() {
        manageOpen = false
        tabIndex = 0
    }

    // Die Profile liest das Widget beim Start, damit der erste Tastendruck des
    // Tages ein Grid zeigt statt nichts.
    Component.onCompleted: profilesProc.running = true

    function openPicker() {
        if (busy) return
        if (profiles.length === 0) {
            pickerWanted = true
            profilesProc.running = true
            return
        }
        if (!overlayVisible) adoptOverlayScreen()
        if (manageOpen) closeManage()
        pickerMode = "grid"
        pickerIndex = Math.max(0, profiles.map(function(p) { return p.name }).indexOf(profile))
        pickerOpen = true
        Qt.callLater(function() { pickerKeys.forceActiveFocus() })
    }

    function closePicker() {
        pickerOpen = false
        pickerMode = "grid"
    }

    function movePicker(dx, dy) {
        pickerIndex = Model.moveIndex(pickerIndex, dx, dy, pickerCount, pickerColumns)
    }

    function activatePicker() {
        if (pickerIndex >= profiles.length) {
            openCompose()
            return
        }
        var chosen = profiles[pickerIndex]
        if (!chosen) return
        // Gemerkt als neuer Standard, damit "Keybind, Enter" diese Wahl
        // wiederholt.
        if (chosen.name !== profile) updateSetting("profile", chosen.name)
        pendingProfile = chosen.name
        // Erst die Flaeche weg, dann die Arbeit: eine exklusive Layer-Flaeche
        // verschluckt, was darunter passieren soll, und eine Benachrichtigung
        // hinter einem Vollbild-Overlay sieht niemand.
        pickerOpen = false
        pickerRun.restart()
    }

    function openCompose() {
        pickerMode = "compose"
        instructionArea.text = lastInstruction
        Qt.callLater(function() {
            instructionArea.forceActiveFocus()
            instructionArea.selectAll()
        })
    }

    function closeCompose() {
        pickerMode = "grid"
        Qt.callLater(function() { pickerKeys.forceActiveFocus() })
    }

    function runCustom(instruction) {
        var text = String(instruction || "").trim()
        if (text === "") return
        lastInstruction = text
        pendingInstruction = text
        pickerOpen = false
        pickerMode = "grid"
        pickerRun.restart()
    }

    Timer {
        id: pickerRun
        interval: 50
        onTriggered: {
            var chosen = root.pendingProfile
            var typed = root.pendingInstruction
            root.pendingProfile = ""
            root.pendingInstruction = ""
            if (typed !== "") root.correctCustom(typed)
            else root.correctWith(chosen)
        }
    }

    // ------------------------------------------------------------ prompt edits

    property string draftName: ""
    property string draftTitle: ""
    property string draftIcon: ""
    property string draftSystem: ""
    property string promptsError: ""

    readonly property var draftProfile: {
        for (var i = 0; i < profiles.length; i++)
            if (profiles[i].name === draftName) return profiles[i]
        return null
    }

    readonly property bool draftIsNew: draftName !== "" && draftProfile === null

    readonly property bool promptsDirty: draftName !== ""
        && (draftIsNew
            || draftTitle !== draftProfile.title
            || draftIcon !== draftProfile.icon
            || draftSystem !== draftProfile.system)

    // Die zwei Regeln, die jeder mitgelieferte Prompt traegt. Ein Prompt ohne
    // sie speichert trotzdem -- die Datei gehoert dem Nutzer -- aber der Editor
    // sagt es, weil die Markierung sonst keine quarantaenisierten Daten mehr ist.
    readonly property bool draftGuarded: draftSystem.indexOf("<text>") >= 0
        && draftSystem.toLowerCase().indexOf("nothing else") >= 0

    function selectPrompt(name) {
        draftName = name
        var found = null
        for (var i = 0; i < profiles.length; i++)
            if (profiles[i].name === name) found = profiles[i]
        loadDraft(found ? found.title : "", found ? found.icon : "", found ? found.system : "")
    }

    // Die Editoren werden beschrieben statt gebunden: ein `text:`-Binding auf
    // den Draft ueberlebt nur bis zum ersten Tastendruck.
    function loadDraft(title, icon, system) {
        draftTitle = title
        draftIcon = icon
        draftSystem = system
        promptsError = ""
        if (typeof titleField !== "undefined" && titleField) titleField.text = title
        if (typeof systemArea !== "undefined" && systemArea) systemArea.text = system
    }

    function syncDraft() {
        if (profiles.length === 0) return
        if (draftName === "" || (draftProfile === null && !promptsDirty))
            selectPrompt(profiles[0].name)
    }

    function stepPrompt(delta) {
        if (profiles.length === 0 || draftIsNew) return
        var at = -1
        for (var i = 0; i < profiles.length; i++)
            if (profiles[i].name === draftName) at = i
        var next = Math.min(Math.max(at + delta, 0), profiles.length - 1)
        if (next !== at) selectPrompt(profiles[next].name)
    }

    function newPrompt() {
        // Der Name wird einmal aus dem Titel erzeugt und dann eingefroren: er
        // ist, worauf settings.json und jede History-Zeile verweisen.
        var title = "Neuer Prompt"
        draftName = Model.profileName(title, profiles)
        // Mit dem System-Text eines bestehenden Prompts vorbesetzt, damit ein
        // neuer die zwei Schutzregeln erbt statt ohne sie anzufangen.
        loadDraft(title, "", profiles.length > 0 ? profiles[0].system : "")
        tabIndex = 1
    }

    function savePrompts() {
        if (draftName === "" || draftTitle.trim() === "" || draftSystem.trim() === "") {
            promptsError = "Ein Prompt braucht Titel und Text."
            return
        }
        var out = []
        var replaced = false
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i].name === draftName) {
                out.push({ name: draftName, title: draftTitle, icon: draftIcon, system: draftSystem })
                replaced = true
            } else {
                out.push(profiles[i])
            }
        }
        if (!replaced) out.push({ name: draftName, title: draftTitle, icon: draftIcon, system: draftSystem })
        writeProfiles(out)
    }

    function deletePrompt(name) {
        if (profiles.length <= 1) return
        var out = profiles.filter(function(p) { return p.name !== name })
        if (profile === name) updateSetting("profile", out[0].name)
        draftName = ""
        writeProfiles(out)
    }

    function writeProfiles(list) {
        saveProc.payload = JSON.stringify({ profiles: list })
        saveProc.running = true
    }

    // ------------------------------------------------------------ icon picker

    // [Glyph, Name]-Paare aus tools/generate-icons.py. Erst beim ersten Oeffnen
    // geladen: 300 KB, die die meisten Sitzungen nie ansehen.
    property var icons: []
    property bool iconPickerOpen: false
    property string iconQuery: ""
    property int iconIndex: 0

    readonly property int iconColumns:
        Math.max(6, Math.floor(card.width / 58))

    readonly property var iconMatches: Model.filterIcons(icons, iconQuery, 400)

    function openIconPicker() {
        iconQuery = ""
        iconIndex = 0
        iconPickerOpen = true
        if (icons.length === 0) iconsFile.reload()
        Qt.callLater(function() { iconSearch.forceActiveFocus() })
    }

    function closeIconPicker() {
        iconPickerOpen = false
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    function moveIconCursor(dx, dy) {
        iconIndex = Model.moveIndex(iconIndex, dx, dy, iconMatches.length, iconColumns)
    }

    function pickIcon(glyph) {
        draftIcon = glyph
        closeIconPicker()
    }

    FileView {
        id: iconsFile
        path: root.pluginDir + "/icons.json"
        printErrors: false
        onLoaded: {
            try {
                var parsed = JSON.parse(text())
                root.icons = parsed.icons || []
            } catch (e) { root.icons = [] }
        }
        onLoadFailed: root.icons = []
    }

    // Die Bestaetigungen tragen keine eigene Tastatur -- der KeyCatcher routet
    // hinein, wie bei den Erstpartei-Panels des Originals.
    readonly property var openDialog:
        confirmDelete.opened ? confirmDelete : (confirmClear.opened ? confirmClear : null)

    function dialogCancel() { if (openDialog) openDialog.canceled() }
    function dialogToggle() { if (openDialog) openDialog.selectedIndex = openDialog.selectedIndex === 0 ? 1 : 0 }
    function dialogActivate() {
        if (!openDialog) return
        if (openDialog.selectedIndex === 0) openDialog.canceled()
        else openDialog.confirmed()
    }

    function copyEntry(entry) {
        if (!Model.hasText(entry)) return
        copyProc.text = entry.corrected
        copyProc.running = true
    }

    // ------------------------------------------------------------- plumbing

    // Nur "done" verfaellt von selbst; "error" wartet auf die Quittung. Der
    // Timer ist deklarativ an den globalen Zustand gebunden, damit jede
    // Instanz ihn laufen laesst und settle idempotent doppelt feuern darf.
    Timer {
        interval: Model.DONE_HOLD_MS
        running: root.runState === Model.STATE_DONE
        onTriggered: root.apply("settle")
    }

    Process {
        id: correctProc
        running: false
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0) {
                var result = null
                try { result = JSON.parse(stdout.text) } catch (e) { result = null }
                root.succeed(result)
            } else {
                root.fail(exitCode, stderr.text)
            }
            historyFile.reload()
        }
    }

    Process {
        id: copyProc
        property string text: ""
        running: false
        command: ["wl-copy", "--", copyProc.text]
    }

    Process {
        id: clearProc
        running: false
        command: [root.pluginDir + "/scribe", "history", "clear"]
        onExited: historyFile.reload()
    }

    Process {
        id: profilesProc
        running: false
        command: [root.pluginDir + "/scribe", "profiles", "--json"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.adoptProfiles(text)
        }
        stderr: StdioCollector { waitForEnd: true }
        // Eine profiles.json, die das CLI abweist, liesse das Grid sonst leer
        // und sagte nichts dazu. Die Prompts sind das Produkt; sie nicht lesen
        // zu koennen ist das rote Icon wert.
        onExited: function(exitCode) {
            if (exitCode === 0) {
                root.recovered()
                return
            }
            root.pickerWanted = false
            root.misconfigured(exitCode, Model.plainError(stderr.text))
        }
    }

    function adoptProfiles(payload) {
        var parsed = null
        try { parsed = JSON.parse(payload) } catch (e) { parsed = null }
        profiles = Model.normalizeProfiles(parsed)
        if (pickerIndex >= profiles.length) pickerIndex = Math.max(0, profiles.length - 1)
        syncDraft()
        if (pickerWanted && profiles.length > 0) {
            pickerWanted = false
            openPicker()
        }
    }

    // Speichern laeuft durchs CLI statt die Datei hier zu schreiben:
    // write_private haelt sie auf 0600 und den Tausch atomar.
    Process {
        id: saveProc
        property string payload: ""
        running: false
        stdinEnabled: true
        command: [root.pluginDir + "/scribe", "profiles", "save"]
        onStarted: {
            write(saveProc.payload)
            saveProc.payload = ""
            stdinEnabled = false
        }
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(exitCode) {
            if (exitCode === 0) {
                root.promptsError = ""
                root.adoptProfiles(stdout.text)
            } else {
                root.promptsError = Model.errorMessage(exitCode, stderr.text)
            }
        }
    }

    // profiles.json bleibt von Hand editierbar, und "profiles.json oeffnen"
    // laedt genau dazu ein.
    FileView {
        id: profilesFile
        path: root.configDir + "/profiles.json"
        watchChanges: true
        printErrors: false
        onFileChanged: profilesProc.running = true
    }

    Process {
        id: backendsProc
        running: false
        command: [root.pluginDir + "/scribe", "backends", "--json"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { root.backendNames = JSON.parse(text).backends || [] }
                catch (e) { root.backendNames = [] }
            }
        }
    }

    Process {
        id: doctorProc
        running: false
        command: root.endpoint === ""
            ? [root.pluginDir + "/scribe", "doctor", "--backend", root.backend]
            : [root.pluginDir + "/scribe", "doctor", "--backend", root.backend, "--endpoint", root.endpoint]
        stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.doctorReport = text }
        stderr: StdioCollector { waitForEnd: true }
    }

    Process {
        id: editProc
        running: false
        command: ["xdg-open", root.configDir + "/profiles.json"]
    }

    // Der Keybind, der den Picker oeffnet, angezeigt im Overlay. niri gibt die
    // Binds nicht per IPC heraus, also wird config.kdl gelesen und beobachtet.
    property string keybind: ""

    FileView {
        id: bindingsFile
        path: (Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/niri/config.kdl"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.keybind = Model.keybindFor(text())
        onLoadFailed: root.keybind = ""
    }

    FileView {
        id: historyFile
        path: root.stateDir + "/history.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                var parsed = JSON.parse(text())
                root.history = parsed.entries || []
            } catch (e) { root.history = [] }
        }
        onLoadFailed: root.history = []
    }

    // Steuerung von aussen (Keybind in niri/config.kdl):
    //   dms ipc call scribe correct
    // Fallen wie beim warthemahl-Port: bei zwei Monitoren antwortet die zuerst
    // registrierte Instanz, und nach "plugins reload" haengt der Target an der
    // alten (quickshell#898) -- dann Shell-Neustart.
    IpcHandler {
        target: "scribe"

        function correct(): void { root.correct() }
        function correctNow(): void { root.correctNow() }
        function correctWith(profile: string): void { root.correctWith(profile) }
        function correctCustom(instruction: string): void { root.correctCustom(instruction) }
        function cancel(): void { root.cancel() }
        function open(): void { root.openManageCard() }
        function close(): void { root.closeManage() }
        function toggle(): void { root.manageOpen ? root.closeManage() : root.openManageCard() }
        function status(): string { return root.runState }
        function lastError(): string { return root.lastError }
        function lastExit(): string { return String(root.lastExitCode) }
        function command(): string { return root.commandFor().join(" ") }
    }

    // ----------------------------------------------------------- bar button

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    readonly property color markColor: runState === Model.STATE_ERROR ? Theme.error
        : runState === Model.STATE_DONE ? Theme.primary
        : Theme.widgetTextColor

    // Linksklick oeffnet, was der Keybind oeffnet: das Grid. Rechtsklick
    // raeumt das Overlay weg oder bricht einen laufenden Abruf ab.
    pillClickAction: () => {
        if (root.overlayVisible) root.dismissOverlay()
        else root.correct()
    }
    pillRightClickAction: () => root.cancel()

    // Gezeichnet statt als Glyphe gesetzt: "Aa" ueber einer Linie ist in jeder
    // Schrift lesbar, und die Linie ist zugleich die Fortschrittsanzeige --
    // fegend im Lauf, Akzent bei Erfolg, rot und bleibend bei Fehler.
    component PillIcon: Item {
        property bool compact: false
        implicitWidth: root.barIconPx + 6
        implicitHeight: root.barIconPx + 6

        Column {
            anchors.centerIn: parent
            spacing: 2

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: compact ? "A" : "Aa"
                color: root.runState === Model.STATE_ERROR ? Theme.error : Theme.widgetTextColor
                font.pixelSize: root.barIconPx - 4
                font.weight: Font.DemiBold
                opacity: root.busy ? 0.55 : 1.0
                Behavior on opacity { NumberAnimation { duration: 150 } }
            }

            Item {
                id: rule
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.barIconPx * 0.9
                height: 2

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: root.markColor
                    opacity: root.busy ? 0.2 : 1.0
                    Behavior on color { ColorAnimation { duration: 160 } }
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                }

                Rectangle {
                    id: sweep
                    visible: root.busy
                    width: parent.width * 0.4
                    height: parent.height
                    radius: height / 2
                    color: Theme.primary

                    XAnimator on x {
                        running: root.busy && root.surfaceLive
                        loops: Animation.Infinite
                        from: 0
                        to: rule.width - sweep.width
                        duration: 700
                        easing.type: Easing.InOutSine
                    }
                }
            }
        }
    }

    horizontalBarPill: Component {
        PillIcon { compact: false }
    }

    verticalBarPill: Component {
        PillIcon { compact: true }
    }

    // ----------------------------------------------- shared overlay elements

    component SectionLabel: StyledText {
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall - 1
        font.weight: Font.DemiBold
        font.letterSpacing: 1
    }

    component HairRule: Rectangle {
        height: 1
        color: Theme.withAlpha(Theme.surfaceText, 0.12)
    }

    // Ein kleiner Bestaetigungs-Dialog ueber der Karte; Omarchys ConfirmDialog
    // gibt es in DMS nicht. Tastatur kommt vom KeyCatcher (dialog* oben).
    component ConfirmBox: Rectangle {
        id: box
        property bool opened: false
        property string message: ""
        property string confirmText: "Loeschen"
        property int selectedIndex: 0
        signal confirmed()
        signal canceled()

        visible: opened
        onOpenedChanged: if (opened) selectedIndex = 0
        color: Theme.withAlpha(Theme.background, 0.7)
        radius: Theme.cornerRadius

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - 40)
            height: boxBody.implicitHeight + 40
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh
            border.color: Theme.withAlpha(Theme.surfaceText, 0.15)
            border.width: 1

            Column {
                id: boxBody
                anchors.centerIn: parent
                width: parent.width - 40
                spacing: Theme.spacingM

                StyledText {
                    width: parent.width
                    text: box.message
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingM

                    Rectangle {
                        width: cancelText.implicitWidth + 28; height: 32
                        radius: Theme.cornerRadius
                        color: box.selectedIndex === 0 ? Theme.primaryContainer : Theme.surfaceContainer
                        border.color: box.selectedIndex === 0 ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.2)
                        border.width: 1
                        StyledText { id: cancelText; anchors.centerIn: parent; text: "Abbrechen"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeSmall }
                        MouseArea { anchors.fill: parent; onClicked: box.canceled() }
                    }

                    Rectangle {
                        width: okText.implicitWidth + 28; height: 32
                        radius: Theme.cornerRadius
                        color: box.selectedIndex === 1 ? Theme.error : Theme.surfaceContainer
                        border.color: box.selectedIndex === 1 ? Theme.error : Theme.withAlpha(Theme.surfaceText, 0.2)
                        border.width: 1
                        StyledText { id: okText; anchors.centerIn: parent; text: box.confirmText; color: box.selectedIndex === 1 ? Theme.primaryText : Theme.surfaceText; font.pixelSize: Theme.fontSizeSmall }
                        MouseArea { anchors.fill: parent; onClicked: box.confirmed() }
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "←→ waehlen · Enter bestaetigen · Esc abbrechen"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall - 1
                }
            }
        }
    }

    // --------------------------------------------------------------- overlay

    PanelWindow {
        id: picker

        visible: root.overlayVisible
        screen: root.overlayScreen
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        WlrLayershell.namespace: "dms:plugins:scribe-overlay"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.overlayVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore

        readonly property int gap: 12
        readonly property int tileSize: Math.max(120,
            Math.min(200, Math.floor((picker.width * 0.6 - (root.pickerColumns - 1) * picker.gap) / root.pickerColumns)))
        readonly property int gridWidth:
            root.pickerColumns * tileSize + (root.pickerColumns - 1) * gap

        Rectangle {
            anchors.fill: parent
            // Wie viel Desktop durchscheint. Absichtlich ein Literal -- an eine
            // Property dieses Fensters gebunden wertete es vor dem Initializer
            // zu 0 aus, und ein Scrim mit Alpha 0 ist stumm nicht da.
            color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.85)
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.dismissOverlay()
        }

        Item {
            id: pickerKeys
            anchors.fill: parent
            // Zwei Key-Catcher teilen sich dieses Fenster; beide binden ihren
            // Fokus an die eigene Ansicht, sonst haelt der zuletzt
            // initialisierte die Tastatur, egal welche Ansicht steht.
            focus: root.pickerOpen && root.pickerMode === "grid"
            visible: root.pickerOpen

            Keys.onEscapePressed: root.closePicker()
            Keys.onLeftPressed: root.movePicker(-1, 0)
            Keys.onRightPressed: root.movePicker(1, 0)
            Keys.onUpPressed: root.movePicker(0, -1)
            Keys.onDownPressed: root.movePicker(0, 1)
            Keys.onTabPressed: root.movePicker(1, 0)
            Keys.onBacktabPressed: root.movePicker(-1, 0)
            Keys.onReturnPressed: root.activatePicker()
            Keys.onEnterPressed: root.activatePicker()
            Keys.onPressed: function(event) {
                if (event.text >= "1" && event.text <= "9") {
                    var wanted = event.text.charCodeAt(0) - 49
                    if (wanted < root.pickerCount) {
                        root.pickerIndex = wanted
                        root.activatePicker()
                    }
                    event.accepted = true
                } else if ("hjkl".indexOf(event.text) >= 0 && event.text !== "") {
                    root.movePicker(event.text === "l" ? 1 : event.text === "h" ? -1 : 0,
                                    event.text === "j" ? 1 : event.text === "k" ? -1 : 0)
                    event.accepted = true
                } else if (event.text === "s" || event.text === "S") {
                    root.openManage(2)
                    event.accepted = true
                } else if (event.text === "p" || event.text === "P") {
                    root.openManage(1)
                    event.accepted = true
                }
            }

            Column {
                anchors.centerIn: parent
                width: picker.gridWidth
                spacing: 16
                visible: root.pickerMode === "grid"

                Row {
                    width: parent.width
                    spacing: 8

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - gearButton.width - parent.spacing
                        text: "Korrigieren mit"
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeXLarge
                        elide: Text.ElideRight
                    }

                    DankButton {
                        id: gearButton
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Einstellungen"
                        iconName: "settings"
                        buttonHeight: 32
                        onClicked: root.openManage(2)
                    }
                }

                // Kachel-Reihen statt GridView, wegen der Index-Navigation von
                // Model.moveIndex: n ist hoechstens ein Dutzend.
                Column {
                    spacing: picker.gap

                    Repeater {
                        model: Math.ceil(root.pickerCount / root.pickerColumns)

                        Row {
                            id: tileRow
                            required property int index
                            spacing: picker.gap

                            Repeater {
                                model: Math.min(root.pickerColumns,
                                                root.pickerCount - tileRow.index * root.pickerColumns)

                                Rectangle {
                                    id: tile
                                    required property int index

                                    readonly property int slot: tileRow.index * root.pickerColumns + tile.index
                                    readonly property var entry: root.profiles[tile.slot] || null
                                    readonly property bool chosen: tile.slot === root.pickerIndex
                                    readonly property bool custom: tile.slot === root.profiles.length

                                    width: picker.tileSize
                                    height: picker.tileSize
                                    radius: Theme.cornerRadius
                                    // Deckend wie die Erstpartei-Karten: ein
                                    // 4%-Tint ueber halbtransparentem Scrim
                                    // waere Tapete mit Text darauf.
                                    color: Theme.surfaceContainer
                                    border.color: tile.chosen ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.18)
                                    border.width: tile.chosen ? 2 : 1

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: parent.radius
                                        color: Theme.withAlpha(Theme.primary, 0.1)
                                        opacity: tile.chosen ? 1.0 : 0.0
                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                    }

                                    // Die Ziffer ist keine Deko: sie nennt die
                                    // Taste, die diese Kachel direkt waehlt.
                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.margins: 10
                                        visible: tile.slot < 9
                                        text: String(tile.slot + 1)
                                        color: tile.chosen ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.55)
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    // Welchen Prompt der Keybind allein benutzt
                                    // haette. Nie die Custom-Kachel.
                                    StyledText {
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: 10
                                        visible: tile.entry !== null && tile.entry.name === root.profile
                                        text: "●"
                                        color: Theme.primary
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    Column {
                                        anchors.centerIn: parent
                                        width: parent.width - 20
                                        spacing: 4

                                        // Nerd-Font-Glyphe des Prompts bzw. der
                                        // Composer-Stift, ueber die von DMS
                                        // gebuendelte Schrift gerendert.
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            visible: tile.custom || (tile.entry !== null && Model.hasIcon(tile.entry))
                                            text: tile.custom ? "✎" : (tile.entry ? tile.entry.icon : "")
                                            color: Theme.surfaceText
                                            font.family: DC.Fonts.nerd
                                            font.pixelSize: 28
                                        }

                                        StyledText {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            text: tile.custom ? "Eigene…"
                                                : (tile.entry ? (tile.entry.title || tile.entry.name) : "")
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeLarge
                                            wrapMode: Text.WordWrap
                                            maximumLineCount: 3
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            visible: tile.custom
                                            text: "Anweisung eintippen"
                                            color: Theme.withAlpha(Theme.surfaceText, 0.55)
                                            font.pixelSize: Theme.fontSizeSmall
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        // Bewegung, nicht blosse Anwesenheit:
                                        // onEntered feuerte sofort unter dem
                                        // ruhenden Zeiger und wuerfe die
                                        // Vorauswahl weg.
                                        onPositionChanged: root.pickerIndex = tile.slot
                                        onClicked: root.activatePicker()
                                    }
                                }
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: "↑↓←→ waehlen · 1-9 direkt · Enter korrigieren · s Einstellungen · p Prompts · Esc abbrechen"
                    color: Theme.withAlpha(Theme.surfaceText, 0.65)
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    width: parent.width
                    visible: root.keybind !== ""
                    text: "Tastenkombination: " + root.keybind
                    color: Theme.withAlpha(Theme.surfaceText, 0.65)
                    font.pixelSize: Theme.fontSizeSmall
                }
            }

            // Composer: das Grid wird ersetzt, nicht ueberdeckt, und der Block
            // behaelt die Grid-Breite, damit nichts springt.
            Column {
                anchors.centerIn: parent
                width: picker.gridWidth
                spacing: 16
                visible: root.pickerMode === "compose"

                StyledText {
                    width: parent.width
                    text: "Eigene Anweisung"
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeXLarge
                }

                Rectangle {
                    width: parent.width
                    height: 120
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainer
                    border.color: Theme.primary
                    border.width: 2

                    Flickable {
                        anchors.fill: parent
                        anchors.margins: 8
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        TextArea.flickable: TextArea {
                            id: instructionArea
                            wrapMode: TextArea.Wrap
                            placeholderText: "z.B. kuerze das auf einen Satz"
                            placeholderTextColor: Theme.withAlpha(Theme.surfaceText, 0.45)
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            selectionColor: Theme.withAlpha(Theme.primary, 0.4)
                            selectedTextColor: Theme.surfaceText
                            background: null

                            // Enter fuehrt aus; Shift+Enter macht die zweite
                            // Zeile. Ein Enter, das nur umbricht, kostete den
                            // haeufigen Fall die Maus.
                            Keys.onReturnPressed: function(event) {
                                if (event.modifiers & Qt.ShiftModifier) event.accepted = false
                                else { root.runCustom(instructionArea.text); event.accepted = true }
                            }
                            Keys.onEnterPressed: function(event) {
                                if (event.modifiers & Qt.ShiftModifier) event.accepted = false
                                else { root.runCustom(instructionArea.text); event.accepted = true }
                            }
                            Keys.onEscapePressed: function(event) {
                                root.closeCompose()
                                event.accepted = true
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: "Enter korrigieren · Shift+Enter neue Zeile · Esc zurueck"
                    color: Theme.withAlpha(Theme.surfaceText, 0.65)
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }

        // ----------------------------------------------------------- die Karte

        // Alles, was das Bar-Popup des Originals hielt, auf der Flaeche, die
        // schon existiert: eine zweite Layer-Flaeche mit exklusiver Tastatur
        // waere ein Kampf, den keine gewinnt.
        Rectangle {
            id: card

            visible: root.overlayView === "manage"
            anchors.centerIn: parent
            width: Math.min(1180, Math.round(picker.width * 0.92))
            height: Math.min(820, Math.round(picker.height * 0.88))
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.color: Theme.withAlpha(Theme.surfaceText, 0.15)
            border.width: 1

            readonly property int inset: 20

            // Ein Klick auf die Karte ist kein Klick daneben.
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            Item {
                id: keyCatcher
                anchors.fill: parent
                anchors.margins: card.inset
                focus: root.overlayView === "manage"

                // Tasten, die beim Tippen in die Felder nicht feuern duerfen:
                // die Felder akzeptieren ihre Zeichen selbst, und nur nicht
                // akzeptierte Events steigen bis hierher auf. Escape in einem
                // Feld faengt das Feld selbst (unfokussieren statt schliessen).
                Keys.onEscapePressed: {
                    if (root.iconPickerOpen) root.closeIconPicker()
                    else if (root.openDialog) root.dialogCancel()
                    else root.closeManage()
                }
                Keys.onReturnPressed: function(event) {
                    if (root.openDialog) { root.dialogActivate(); return }
                    if (root.tabIndex === 1 && root.draftName !== "") systemArea.forceActiveFocus()
                }
                Keys.onTabPressed: {
                    if (root.openDialog) root.dialogToggle()
                    else root.tabIndex = (root.tabIndex + 1) % 3
                }
                Keys.onBacktabPressed: {
                    if (root.openDialog) root.dialogToggle()
                    else root.tabIndex = (root.tabIndex + 2) % 3
                }
                Keys.onLeftPressed: {
                    if (root.openDialog) root.dialogToggle()
                    else root.tabIndex = Math.max(0, root.tabIndex - 1)
                }
                Keys.onRightPressed: {
                    if (root.openDialog) root.dialogToggle()
                    else root.tabIndex = Math.min(2, root.tabIndex + 1)
                }
                Keys.onUpPressed: if (!root.openDialog && root.tabIndex === 1) root.stepPrompt(-1)
                Keys.onDownPressed: if (!root.openDialog && root.tabIndex === 1) root.stepPrompt(1)
                Keys.onPressed: function(event) {
                    if (root.openDialog || root.iconPickerOpen) return
                    var t = event.text
                    if (t === "c" || t === "C") { root.correct(); event.accepted = true }
                    else if (t === "H") { root.tabIndex = 0; event.accepted = true }
                    else if (t === "p" || t === "P") { root.tabIndex = 1; event.accepted = true }
                    else if (t === "s" || t === "S") { root.tabIndex = 2; event.accepted = true }
                    else if ((t === "n" || t === "N") && root.tabIndex === 1) { root.newPrompt(); event.accepted = true }
                    else if ((t === "i" || t === "I") && root.tabIndex === 1 && root.draftName !== "") { root.openIconPicker(); event.accepted = true }
                    else if ((t === "x" || t === "X") && root.tabIndex === 1 && root.draftProfile !== null && root.profiles.length > 1) { confirmDelete.opened = true; event.accepted = true }
                    else if (t === "d" || t === "D") { root.tabIndex = 2; doctorProc.running = true; event.accepted = true }
                }

                // ----------------------------------------------------- header

                Column {
                    id: cardHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 8

                    Item {
                        width: parent.width
                        height: 36

                        StyledText {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Scribe"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeXLarge + 4
                            font.weight: Font.Bold
                        }

                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: 110
                            anchors.right: closeButton.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.busy ? "Korrigiert…"
                                : root.runState === Model.STATE_ERROR ? "Letzter Lauf schlug fehl"
                                : root.history.length > 0 ? Model.summarize(root.profile + " · " + root.model, 60)
                                : "Text markieren, dann den Keybind druecken"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                            elide: Text.ElideRight
                        }

                        DankButton {
                            id: closeButton
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Schliessen"
                            iconName: "close"
                            buttonHeight: 32
                            onClicked: root.closeManage()
                        }
                    }

                    // Der Fehler steht ganz oben, weil die Karte zu oeffnen
                    // meist die Reaktion aufs rote Icon ist.
                    StyledText {
                        visible: root.lastError !== ""
                        width: parent.width
                        text: root.lastError
                        color: Theme.error
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        visible: root.keybind !== ""
                        width: parent.width
                        text: "Tastenkombination: " + root.keybind
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    HairRule { width: parent.width }
                }

                // ------------------------------------------------- navigation

                Column {
                    id: cardNav
                    anchors.top: cardHeader.bottom
                    anchors.topMargin: 12
                    anchors.left: parent.left
                    width: 160
                    spacing: 4

                    Repeater {
                        model: root.tabNav

                        Rectangle {
                            id: navRow
                            required property var modelData
                            required property int index

                            width: parent.width
                            height: 34
                            radius: Theme.cornerRadius
                            color: navRow.index === root.tabIndex
                                ? Theme.withAlpha(Theme.primary, 0.12)
                                : (navMouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")

                            MouseArea {
                                id: navMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.tabIndex = navRow.index
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: navRow.modelData.icon
                                    color: navRow.index === root.tabIndex ? Theme.primary : Theme.surfaceText
                                    size: Theme.iconSize - 6
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: navRow.modelData.label
                                    color: navRow.index === root.tabIndex ? Theme.primary : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        topPadding: 10
                        text: "←→ Bereich\n↑↓ Prompt\n⏎ bearbeiten\nc korrigieren\nEsc schliessen"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall - 1
                        lineHeight: 1.4
                    }
                }

                Rectangle {
                    anchors.top: cardNav.top
                    anchors.bottom: parent.bottom
                    anchors.left: cardNav.right
                    anchors.leftMargin: 14
                    width: 1
                    color: Theme.withAlpha(Theme.surfaceText, 0.12)
                }

                // ------------------------------------------------------- body

                Item {
                    id: cardBody
                    anchors.top: cardNav.top
                    anchors.bottom: parent.bottom
                    anchors.left: cardNav.right
                    anchors.leftMargin: 29
                    anchors.right: parent.right

                    // ------------------------------------------------ history

                    Item {
                        anchors.fill: parent
                        visible: root.tabIndex === 0

                        StyledText {
                            visible: root.history.length === 0
                            anchors.centerIn: parent
                            width: parent.width
                            text: root.historyEnabled
                                ? "Noch keine Korrekturen."
                                : "Die History ist ausgeschaltet."
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Item {
                            id: historyFooter
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: clearButton.height

                            DankButton {
                                id: clearButton
                                visible: root.history.length > 0
                                text: "History leeren"
                                iconName: "delete_sweep"
                                buttonHeight: 32
                                onClicked: confirmClear.opened = true
                            }
                        }

                        DankFlickable {
                            id: historyFlick
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: historyFooter.top
                            anchors.bottomMargin: 10
                            contentHeight: historyRows.implicitHeight
                            clip: true

                            Column {
                                id: historyRows
                                width: historyFlick.width
                                spacing: 6

                                Repeater {
                                    model: root.history
                                    HistoryRow {
                                        required property var modelData
                                        required property int index
                                        width: parent.width
                                        entry: modelData
                                        rowIndex: index
                                    }
                                }
                            }
                        }
                    }

                    // ------------------------------------------------ prompts

                    Item {
                        anchors.fill: parent
                        visible: root.tabIndex === 1

                        Item {
                            id: promptPane
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            width: Math.round(parent.width * 0.32)

                            Item {
                                id: promptPaneFooter
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: promptPaneButtons.implicitHeight

                                Column {
                                    id: promptPaneButtons
                                    width: parent.width
                                    spacing: 6

                                    Row {
                                        width: parent.width
                                        spacing: 6

                                        DankButton {
                                            text: "Neu"
                                            iconName: "add"
                                            buttonHeight: 32
                                            onClicked: root.newPrompt()
                                        }

                                        DankButton {
                                            text: "Standard"
                                            iconName: "star"
                                            buttonHeight: 32
                                            enabled: root.draftName !== "" && root.draftName !== root.profile
                                                && !root.draftIsNew
                                            opacity: enabled ? 1.0 : 0.45
                                            onClicked: root.updateSetting("profile", root.draftName)
                                        }
                                    }

                                    DankButton {
                                        text: "Loeschen"
                                        iconName: "delete"
                                        buttonHeight: 32
                                        enabled: root.profiles.length > 1 && root.draftProfile !== null
                                        opacity: enabled ? 1.0 : 0.45
                                        onClicked: confirmDelete.opened = true
                                    }
                                }
                            }

                            DankFlickable {
                                id: promptFlick
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: promptPaneFooter.top
                                anchors.bottomMargin: 10
                                contentHeight: promptRows.implicitHeight
                                clip: true

                                Column {
                                    id: promptRows
                                    width: promptFlick.width
                                    spacing: 4

                                    Repeater {
                                        model: root.profiles

                                        Rectangle {
                                            id: promptRow
                                            required property var modelData

                                            width: parent.width
                                            implicitHeight: promptText.implicitHeight + 14
                                            radius: Theme.cornerRadius
                                            color: promptRow.modelData.name === root.draftName
                                                ? Theme.withAlpha(Theme.primary, 0.12)
                                                : (promptMouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")

                                            MouseArea {
                                                id: promptMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.selectPrompt(promptRow.modelData.name)
                                            }

                                            Column {
                                                id: promptText
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 10
                                                anchors.rightMargin: 10
                                                spacing: 2

                                                Row {
                                                    spacing: 6

                                                    Text {
                                                        visible: Model.hasIcon(promptRow.modelData)
                                                        text: promptRow.modelData.icon
                                                        color: Theme.surfaceText
                                                        font.family: DC.Fonts.nerd
                                                        font.pixelSize: Theme.fontSizeMedium
                                                    }

                                                    StyledText {
                                                        text: promptRow.modelData.title || promptRow.modelData.name
                                                        color: Theme.surfaceText
                                                        font.pixelSize: Theme.fontSizeMedium
                                                    }

                                                    StyledText {
                                                        visible: promptRow.modelData.name === root.profile
                                                        text: "Standard"
                                                        color: Theme.primary
                                                        font.pixelSize: Theme.fontSizeSmall - 1
                                                    }
                                                }

                                                StyledText {
                                                    width: promptText.width
                                                    text: Model.summarize(promptRow.modelData.system, 40)
                                                    color: Theme.surfaceVariantText
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Der Editor.
                        Item {
                            id: editorPane
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.left: promptPane.right
                            anchors.leftMargin: 16
                            anchors.right: parent.right

                            StyledText {
                                visible: root.draftName === ""
                                anchors.centerIn: parent
                                width: parent.width
                                text: "Einen Prompt waehlen, um ihn zu bearbeiten."
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeMedium
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Column {
                                id: editorHead
                                visible: root.draftName !== ""
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                spacing: 6

                                Row {
                                    width: parent.width
                                    spacing: 16

                                    Column {
                                        width: Math.round((parent.width - parent.spacing) * 0.62)
                                        spacing: 6

                                        SectionLabel { text: "TITEL" }

                                        DankTextField {
                                            id: titleField
                                            width: parent.width
                                            placeholderText: "Was auf der Kachel steht"
                                            onTextEdited: root.draftTitle = text
                                            Keys.onEscapePressed: function(event) {
                                                keyCatcher.forceActiveFocus()
                                                event.accepted = true
                                            }
                                        }
                                    }

                                    Column {
                                        spacing: 6

                                        SectionLabel { text: "ICON" }

                                        Row {
                                            spacing: 8

                                            Rectangle {
                                                width: 30; height: 30
                                                radius: Theme.cornerRadius
                                                color: root.draftIcon !== "" ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                                                border.color: Theme.withAlpha(Theme.surfaceText, 0.2)
                                                border.width: 1

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: root.draftIcon === "" ? "—" : root.draftIcon
                                                    color: root.draftIcon === "" ? Theme.surfaceVariantText : Theme.surfaceText
                                                    font.family: DC.Fonts.nerd
                                                    font.pixelSize: Theme.fontSizeLarge
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.openIconPicker()
                                                }
                                            }

                                            DankButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "Waehlen…"
                                                buttonHeight: 30
                                                onClicked: root.openIconPicker()
                                            }

                                            DankButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "Leeren"
                                                buttonHeight: 30
                                                enabled: root.draftIcon !== ""
                                                opacity: enabled ? 1.0 : 0.45
                                                onClicked: root.draftIcon = ""
                                            }
                                        }
                                    }
                                }

                                Item { width: 1; height: 6 }

                                SectionLabel { text: "PROMPT" }
                            }

                            Column {
                                id: editorFoot
                                visible: root.draftName !== ""
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                spacing: 6

                                StyledText {
                                    visible: !root.draftGuarded
                                    width: parent.width
                                    text: "Ohne <text> und \"nothing else\" verliert dieser Prompt den Injektionsschutz."
                                    color: Theme.error
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    wrapMode: Text.WordWrap
                                }

                                StyledText {
                                    visible: root.promptsError !== ""
                                    width: parent.width
                                    text: root.promptsError
                                    color: Theme.error
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    wrapMode: Text.WordWrap
                                }

                                Row {
                                    width: parent.width
                                    spacing: 8

                                    DankButton {
                                        text: "Speichern"
                                        iconName: "save"
                                        buttonHeight: 32
                                        enabled: root.promptsDirty
                                        opacity: enabled ? 1.0 : 0.45
                                        onClicked: root.savePrompts()
                                    }

                                    DankButton {
                                        text: "Verwerfen"
                                        iconName: "undo"
                                        buttonHeight: 32
                                        enabled: root.promptsDirty && !root.draftIsNew
                                        opacity: enabled ? 1.0 : 0.45
                                        onClicked: root.selectPrompt(root.draftName)
                                    }

                                    DankButton {
                                        text: "profiles.json oeffnen"
                                        buttonHeight: 32
                                        onClicked: editProc.running = true
                                    }

                                    StyledText {
                                        visible: root.promptsDirty
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Ungespeichert"
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                    }
                                }
                            }

                            // Wofuer der Umbau war: der Prompt-Text bekommt,
                            // was zwischen Kopf und Fuss uebrig ist.
                            Flickable {
                                id: systemFlick
                                visible: root.draftName !== ""
                                anchors.top: editorHead.bottom
                                anchors.topMargin: 6
                                anchors.bottom: editorFoot.top
                                anchors.bottomMargin: 10
                                anchors.left: parent.left
                                anchors.right: parent.right
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                TextArea.flickable: TextArea {
                                    id: systemArea
                                    wrapMode: TextArea.Wrap
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    selectionColor: Theme.withAlpha(Theme.primary, 0.4)
                                    selectedTextColor: Theme.surfaceText
                                    padding: 10
                                    onTextChanged: root.draftSystem = text

                                    background: Rectangle {
                                        radius: Theme.cornerRadius
                                        color: Theme.surfaceContainerHigh
                                        border.color: systemArea.activeFocus ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.15)
                                        border.width: 1
                                    }

                                    Keys.onEscapePressed: function(event) {
                                        keyCatcher.forceActiveFocus()
                                        event.accepted = true
                                    }
                                }
                            }
                        }
                    }

                    // ----------------------------------------------- settings

                    DankFlickable {
                        id: settingsFlick
                        anchors.fill: parent
                        visible: root.tabIndex === 2
                        contentHeight: settingsRow.implicitHeight
                        clip: true

                        // Zwei Spalten: die Karte ist breit, und eine Spalte
                        // Regler darueber waere eine Reihe sehr langer Dropdowns.
                        Row {
                            id: settingsRow
                            width: settingsFlick.width
                            spacing: 24

                            Column {
                                width: Math.floor((settingsRow.width - settingsRow.spacing) / 2)
                                spacing: 10

                                DankDropdown {
                                    width: parent.width
                                    text: "Backend"
                                    currentValue: root.backend
                                    options: root.backendNames
                                    onValueChanged: value => root.updateSetting("backend", value)
                                }

                                DankDropdown {
                                    width: parent.width
                                    text: "Standard-Prompt"
                                    currentValue: Model.profileTitle(root.profiles, root.profile)
                                    options: root.profileTitles
                                    onValueChanged: value => root.updateSetting("profile", root.profileNameForTitle(value))
                                }

                                Column {
                                    width: parent.width
                                    spacing: 6

                                    SectionLabel { text: "MODELL" }

                                    DankTextField {
                                        width: parent.width
                                        text: root.model
                                        onEditingFinished: if (text !== root.model) root.updateSetting("model", text)
                                        Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: "Wird dem Backend woertlich durchgereicht. claude-haiku-4-5 ist die guenstigere, schnellere Wahl."
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                Column {
                                    width: parent.width
                                    spacing: 6

                                    SectionLabel { text: "EFFORT" }

                                    DankTextField {
                                        width: parent.width
                                        text: root.effort
                                        onEditingFinished: if (text !== root.effort) root.updateSetting("effort", text)
                                        Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: "Leer laesst das Backend entscheiden. Auf einem Thinking-Modell hinter ollama schaltet \"none\" das Nachdenken ab — rund sechsmal schneller bei gleicher Qualitaet."
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                // Nur das openai-Backend nimmt einen Endpoint.
                                Column {
                                    visible: root.backend === "openai"
                                    width: parent.width
                                    spacing: 6

                                    SectionLabel { text: "ENDPOINT" }

                                    DankTextField {
                                        width: parent.width
                                        text: root.endpoint
                                        onEditingFinished: if (text !== root.endpoint) root.updateSetting("endpoint", text)
                                        Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: "OpenAI-kompatible Basis-URL, z.B. http://gpu-box.local:11434/v1 fuer ein entferntes ollama. Leer heisst api.openai.com."
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }

                            Column {
                                width: Math.floor((settingsRow.width - settingsRow.spacing) / 2)
                                spacing: 10

                                DankToggle {
                                    width: parent.width
                                    text: "Auf die Zwischenablage ausweichen"
                                    description: "Ist nichts markiert, wird korrigiert, was in der Zwischenablage liegt."
                                    checked: root.clipboardFallback
                                    onToggled: checked => root.updateSetting("clipboardFallback", checked)
                                }

                                DankToggle {
                                    width: parent.width
                                    text: "Benachrichtigen, wenn fertig"
                                    checked: root.notifyOnDone
                                    onToggled: checked => root.updateSetting("notify", checked)
                                }

                                DankToggle {
                                    width: parent.width
                                    text: "History fuehren"
                                    description: "Korrekturen landen in " + root.stateDir + "."
                                    checked: root.historyEnabled
                                    onToggled: checked => root.updateSetting("historyEnabled", checked)
                                }

                                DankToggle {
                                    width: parent.width
                                    enabled: root.historyEnabled
                                    opacity: root.historyEnabled ? 1.0 : 0.5
                                    text: "Text in der History speichern"
                                    description: "Aus haelt fest, dass korrigiert wurde, ohne den Text auf die Platte zu schreiben."
                                    checked: root.historyStoreText
                                    onToggled: checked => root.updateSetting("historyStoreText", checked)
                                }

                                HairRule { width: parent.width }

                                DankButton {
                                    text: "Setup pruefen"
                                    iconName: "troubleshoot"
                                    buttonHeight: 32
                                    onClicked: doctorProc.running = true
                                }

                                StyledText {
                                    visible: root.doctorReport !== ""
                                    width: parent.width
                                    text: root.doctorReport
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }

            ConfirmBox {
                id: confirmClear
                anchors.fill: parent
                anchors.margins: 2
                message: "Jede gespeicherte Korrektur loeschen?"
                confirmText: "Leeren"
                onConfirmed: { clearProc.running = true; opened = false }
                onCanceled: opened = false
            }

            ConfirmBox {
                id: confirmDelete
                anchors.fill: parent
                anchors.margins: 2
                message: "Den Prompt „" + root.draftTitle + "“ loeschen?"
                confirmText: "Loeschen"
                onConfirmed: { root.deletePrompt(root.draftName); opened = false }
                onCanceled: opened = false
            }

            // Der Icon-Picker als Modal ueber der ganzen Karte: zehntausend
            // Glyphen brauchen den Platz, und die Suche braucht die Tastatur.
            Rectangle {
                id: iconPicker
                anchors.fill: parent
                anchors.margins: 2
                visible: root.iconPickerOpen
                color: Theme.surfaceContainer
                radius: Theme.cornerRadius

                MouseArea { anchors.fill: parent }

                Column {
                    anchors.fill: parent
                    anchors.margins: card.inset
                    spacing: 8

                    Item {
                        width: parent.width
                        height: iconClose.height

                        Row {
                            anchors.left: parent.left
                            anchors.right: iconClose.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Icon"
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeXLarge
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.iconMatches.length + (root.iconMatches.length === 400 ? "+" : "")
                                    + " von " + root.icons.length
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall - 1
                            }

                            Item { width: 4; height: 1 }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.iconMatches[root.iconIndex]
                                    ? root.iconMatches[root.iconIndex][1] : "kein Treffer"
                                color: Theme.primary
                                font.pixelSize: Theme.fontSizeSmall - 1
                            }
                        }

                        DankButton {
                            id: iconClose
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Schliessen"
                            iconName: "close"
                            buttonHeight: 32
                            onClicked: root.closeIconPicker()
                        }
                    }

                    // Ein rohes Eingabefeld statt DankTextField: das Feld
                    // behaelt die Tastatur, damit Tippen filtert, und reicht
                    // die Pfeile ans Grid weiter, statt den Cursor zu bewegen.
                    Rectangle {
                        width: parent.width
                        height: 36
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh
                        border.color: iconSearch.activeFocus ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.15)
                        border.width: 1

                        TextInput {
                            id: iconSearch
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            verticalAlignment: TextInput.AlignVCenter
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            clip: true
                            onTextEdited: { root.iconQuery = text; root.iconIndex = 0 }

                            StyledText {
                                visible: iconSearch.text === ""
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Suchen · pencil, mail, code…"
                                color: Theme.withAlpha(Theme.surfaceText, 0.45)
                                font.pixelSize: Theme.fontSizeMedium
                            }

                            Keys.onUpPressed: root.moveIconCursor(0, -1)
                            Keys.onDownPressed: root.moveIconCursor(0, 1)
                            Keys.onLeftPressed: function(event) {
                                if (iconSearch.text === "") { root.moveIconCursor(-1, 0); event.accepted = true }
                                else event.accepted = false
                            }
                            Keys.onRightPressed: function(event) {
                                if (iconSearch.text === "") { root.moveIconCursor(1, 0); event.accepted = true }
                                else event.accepted = false
                            }
                            Keys.onReturnPressed: function(event) {
                                var hit = root.iconMatches[root.iconIndex]
                                if (hit) root.pickIcon(hit[0])
                                event.accepted = true
                            }
                            Keys.onEscapePressed: function(event) {
                                root.closeIconPicker()
                                event.accepted = true
                            }
                        }
                    }

                    GridView {
                        id: iconGrid
                        width: parent.width
                        height: parent.height - y
                        clip: true
                        cellWidth: Math.floor(width / root.iconColumns)
                        cellHeight: cellWidth
                        model: root.iconMatches
                        currentIndex: root.iconIndex
                        onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)

                        delegate: Rectangle {
                            id: iconCell
                            required property var modelData
                            required property int index

                            width: iconGrid.cellWidth - 2
                            height: iconGrid.cellHeight - 2
                            radius: Theme.cornerRadius
                            color: iconCell.index === root.iconIndex
                                ? Theme.withAlpha(Theme.primary, 0.12)
                                : "transparent"
                            border.color: iconCell.index === root.iconIndex ? Theme.primary : "transparent"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: iconCell.modelData ? iconCell.modelData[0] : ""
                                color: Theme.surfaceText
                                font.family: DC.Fonts.nerd
                                font.pixelSize: Theme.fontSizeLarge
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPositionChanged: root.iconIndex = iconCell.index
                                onClicked: root.pickIcon(iconCell.modelData[0])
                            }
                        }
                    }
                }
            }
        }
    }

    // --------------------------------------------------------- history row

    component HistoryRow: Rectangle {
        id: row
        property var entry: null
        property int rowIndex: 0

        readonly property bool expanded: root.expandedIndex === rowIndex
        readonly property bool textual: Model.hasText(entry)

        radius: Theme.cornerRadius
        color: rowMouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"
        implicitHeight: rowContent.implicitHeight + 14

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: row.textual ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.expandedIndex = row.expanded ? -1 : row.rowIndex
        }

        ColumnLayout {
            id: rowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 3

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                StyledText {
                    Layout.fillWidth: true
                    text: row.textual
                        ? Model.summarize(row.entry.corrected, 110)
                        : (row.entry && row.entry.changed ? "Korrigiert" : "Keine Aenderung") +
                          " · " + (row.entry ? row.entry.correctedLength : 0) + " Zeichen"
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    elide: Text.ElideRight
                }

                DankActionButton {
                    visible: row.textual
                    iconName: "content_copy"
                    tooltipText: "In die Zwischenablage"
                    onClicked: root.copyEntry(row.entry)
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: {
                    if (!row.entry) return ""
                    var bits = [Qt.formatDateTime(new Date(row.entry.ts * 1000), "d. MMM HH:mm")]
                    if (row.entry.profile) bits.push(row.entry.profile)
                    if (row.entry.model) bits.push(row.entry.model)
                    var d = Model.formatDuration(row.entry.ms)
                    if (d) bits.push(d)
                    var u = Model.formatUsage(row.entry.usage)
                    if (u) bits.push(u)
                    if (!row.entry.changed) bits.push("unveraendert")
                    return bits.join(" · ")
                }
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall - 1
                elide: Text.ElideRight
            }

            // Beide Fassungen, damit die Karte "was wurde geaendert?" ohne
            // einen Diff-Algorithmus beantwortet.
            Column {
                visible: row.expanded && row.textual
                Layout.fillWidth: true
                spacing: 6

                StyledText {
                    width: parent.width
                    text: row.entry ? row.entry.original : ""
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    text: row.entry ? row.entry.corrected : ""
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
