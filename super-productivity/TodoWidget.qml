import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Todos aus Super Productivity: Pille in der Bar, Klick (oder Super+M) klappt
// von der Bildschirmkante ein Panel herein (DankSlideout, wie das Notepad von
// DMS). Dort werden Tasks angelegt, abgehakt, umbenannt, geloescht, mit
// Notizen versehen und die Zeiterfassung gestartet.
//
// Das Panel ist bewusst kein Popout: es meldet sich nicht beim PopoutManager
// an. Popouts (Kontrollzentrum, WLAN ...) gehen deshalb darueber auf und
// lassen es offen, statt es zu schliessen -- wie beim Notepad.
//
// Die Daten gehoeren Super Productivity: das Plugin spricht nur mit dessen
// lokaler REST-API (127.0.0.1:3876) ueber bin/sp-api und haelt nichts
// selbst vor. Der Sync zu OpenCloud (WebDAV) ist Sache der App. Laeuft sie
// nicht, zeigt das Panel einen Startknopf statt einer leeren Liste.
//
// Die API kennt keine Push-Nachrichten: das Plugin fragt nach, alle
// refreshInterval Sekunden im Hintergrund und alle 10 s, solange das Panel
// offen ist. Aenderungen aus dem Panel erscheinen sofort (optimistisch) und
// werden danach mit dem echten Stand abgeglichen.
PluginComponent {
    id: root

    // ------------------------------------------------------------ Einstellungen

    readonly property string barCount: String(pluginData?.barCount ?? "today")
    readonly property bool showCurrentInBar: pluginData?.showCurrentInBar !== false
    readonly property string startFilter: String(pluginData?.startFilter ?? "today")
    readonly property string defaultProject: String(pluginData?.defaultProject ?? "")
    readonly property real panelWidth: Math.max(320, Number(pluginData?.panelWidth ?? 420))
    readonly property string slideEdge: pluginData?.slideEdge === "left" ? "left" : "right"
    readonly property int refreshInterval: Math.max(15, Number(pluginData?.refreshInterval ?? 60))
    readonly property string launchCommand: String(pluginData?.launchCommand
        || "flatpak run com.super_productivity.SuperProductivity")

    // Neben dieser Datei aufgeloest statt ueber PATH gesucht, damit das Plugin
    // ohne Installationsschritt aus seinem eigenen Verzeichnis laeuft.
    readonly property string helperPath: {
        var url = Qt.resolvedUrl("bin/sp-api").toString()
        return url.indexOf("file://") === 0 ? url.substring(7) : url
    }

    // ------------------------------------------------------------------ Zustand

    property var tasks: []
    property var projects: []
    property string currentTaskId: ""
    property bool loaded: false
    // Leer, solange SP antwortet; sonst der Fehlercode von sp-api.
    property string errorCode: ""
    property string errorMessage: ""
    // Fehler einer einzelnen Aktion (Anlegen, Abhaken ...). Verschwindet beim
    // naechsten erfolgreichen Abgleich nicht, sondern nach ein paar Sekunden.
    property string actionError: ""

    property string filter: startFilter === "all" ? Model.FILTER_ALL : Model.FILTER_TODAY
    property bool showDone: false
    property string editingId: ""
    property string armedDeleteId: ""
    // Aufgeklapptes Todo (zeigt seine Notizen) und eines, dessen Notiz gerade
    // bearbeitet wird. Waehrend des Bearbeitens pausiert der Abgleich, sonst
    // ueberschriebe er das Feld unter dem Cursor.
    property string openId: ""
    property string notesEditingId: ""

    property date now: new Date()

    readonly property bool reachable: root.errorCode === "" || !Model.isUnreachable(root.errorCode)
    readonly property string effectiveFilter: Model.normalizeFilter(root.filter, root.projects)
    readonly property var chips: Model.filterChips(root.tasks, root.projects, root.now)
    readonly property var rows: Model.buildRows(root.tasks, root.projects, root.effectiveFilter, root.now,
        { showDone: root.showDone, currentId: root.currentTaskId })
    readonly property string defaultProjectId: Model.resolveProjectId(root.projects, root.defaultProject)

    readonly property int pillCount: root.barCount === "none" ? -1
        : Model.countOpen(root.tasks, root.barCount === "all" ? Model.FILTER_ALL : Model.FILTER_TODAY, root.now)
    readonly property var currentTask: {
        if (!root.currentTaskId) return null
        for (var i = 0; i < root.tasks.length; i++)
            if (root.tasks[i].id === root.currentTaskId) return root.tasks[i]
        return null
    }

    readonly property string targetLabel: {
        var f = root.effectiveFilter
        var pid = (f === Model.FILTER_TODAY || f === Model.FILTER_ALL) ? root.defaultProjectId : f
        var name = "Inbox"
        for (var i = 0; i < root.projects.length; i++)
            if (root.projects[i].id === pid) name = root.projects[i].title
        return f === Model.FILTER_TODAY ? name + ", heute" : name
    }

    // ----------------------------------------------------------------- Anfragen

    // Ein Prozess pro Anfrage: Abhaken und Abgleich duerfen sich ueberholen,
    // ein einzelner Process koennte immer nur eins zugleich.
    Component {
        id: requestComponent

        Process {
            id: req
            property var callback: null
            stdout: StdioCollector {
                waitForEnd: true
                onStreamFinished: {
                    var cb = req.callback
                    req.callback = null
                    if (cb) cb(Model.parseResponse(text))
                    Qt.callLater(() => req.destroy())
                }
            }
        }
    }

    function api(method, path, body, callback) {
        var args = [root.helperPath, method, path]
        if (body !== undefined && body !== null) args.push(JSON.stringify(body))
        var proc = requestComponent.createObject(root, { command: args, callback: callback || null })
        proc.running = true
    }

    property bool refreshing: false
    property bool refreshQueued: false

    // Tasks, Projekte und laufender Task parallel; uebernommen wird erst, wenn
    // alle drei da sind, damit Liste und Chips nie aus zwei Staenden stammen.
    function refresh() {
        if (root.editingId !== "" || root.notesEditingId !== "") return
        if (root.refreshing) {
            root.refreshQueued = true
            return
        }
        root.refreshing = true
        var got = {}
        var pending = 3
        var finish = function () {
            if (--pending > 0) return
            root.refreshing = false
            root.now = new Date()
            root.apply(got)
            if (root.refreshQueued) {
                root.refreshQueued = false
                root.refresh()
            }
        }
        root.api("GET", "/tasks?includeDone=true", null, r => { got.tasks = r; finish() })
        root.api("GET", "/projects", null, r => { got.projects = r; finish() })
        root.api("GET", "/task-control/current", null, r => { got.current = r; finish() })
    }

    function apply(got) {
        if (!got.tasks.ok) {
            root.errorCode = got.tasks.code
            root.errorMessage = got.tasks.message
            return
        }
        root.errorCode = ""
        root.errorMessage = ""
        root.tasks = got.tasks.data || []
        if (got.projects.ok) root.projects = got.projects.data || []
        if (got.current.ok) root.currentTaskId = got.current.data ? String(got.current.data.id || "") : ""
        root.loaded = true
    }

    function fail(r) {
        root.actionError = r.message || r.code
        actionErrorTimer.restart()
        if (Model.isUnreachable(r.code)) {
            root.errorCode = r.code
            root.errorMessage = r.message
        }
    }

    // Lokale Kopie eines Tasks aendern, damit die Liste sofort reagiert.
    function patchLocal(id, fields) {
        root.tasks = root.tasks.map(t => t.id === id ? Object.assign({}, t, fields) : t)
    }

    function taskPath(id) {
        return "/tasks/" + encodeURIComponent(id)
    }

    function addTask(title) {
        var body = Model.createBody(title, root.effectiveFilter, new Date(), root.defaultProjectId)
        if (!body) return false
        root.api("POST", "/tasks", body, r => {
            if (!r.ok) root.fail(r)
            root.refresh()
        })
        return true
    }

    function setDone(id, done) {
        root.patchLocal(id, { isDone: done, doneOn: done ? Date.now() : undefined })
        if (done && id === root.currentTaskId) root.currentTaskId = ""
        root.api("PATCH", root.taskPath(id), { isDone: done }, r => {
            if (!r.ok) root.fail(r)
            root.refresh()
        })
    }

    function rename(id, title) {
        var t = String(title || "").trim()
        root.editingId = ""
        if (!t) return
        root.patchLocal(id, { title: t })
        root.api("PATCH", root.taskPath(id), { title: t }, r => {
            if (!r.ok) root.fail(r)
            root.refresh()
        })
    }

    // Notizen speichern: nur wenn sich etwas geaendert hat (Model.notesPatch),
    // lokal sofort, dann per PATCH. SP nimmt "notes" wie "title" an.
    function saveNotes(id, oldNotes, text) {
        var body = Model.notesPatch(oldNotes, text)
        if (!body) return
        root.patchLocal(id, body)
        root.api("PATCH", root.taskPath(id), body, r => {
            if (!r.ok) root.fail(r)
            root.refresh()
        })
    }

    function toggleOpen(id) {
        root.openId = root.openId === id ? "" : id
    }

    // Links aus Notizen: ueber xdg-open, Fehler als Benachrichtigung statt
    // stumm (Konvention der Plugins: melden() loggt und benachrichtigt).
    function protokoll(text) {
        console.warn("[superProductivity] " + text)
    }

    function melden(titel, text) {
        root.protokoll(titel + ": " + text)
        Quickshell.execDetached(["notify-send", "-a", "Todos", "-i", "checkbox-checked-symbolic", titel, text])
    }

    Process {
        id: linkProc
        property string url: ""
        stderr: StdioCollector {
            id: linkErr
            waitForEnd: true
        }
        onExited: exitCode => Qt.callLater(() => {
            if (exitCode !== 0)
                root.melden("Link nicht geöffnet", linkProc.url + (linkErr.text.trim() ? " – " + linkErr.text.trim() : ""))
        })
    }

    function openLink(url) {
        if (!url || linkProc.running) return
        linkProc.url = url
        linkProc.command = ["sh", "-c", "exec xdg-open \"$0\"", url]
        linkProc.running = true
    }

    // Loeschen braucht zwei Klicks: der erste faerbt den Knopf rot, der
    // zweite loescht. Die API kennt kein Rueckgaengig.
    function requestDelete(id) {
        if (root.armedDeleteId !== id) {
            root.armedDeleteId = id
            disarmTimer.restart()
            return
        }
        root.armedDeleteId = ""
        root.tasks = root.tasks.filter(t => t.id !== id && t.parentId !== id)
        root.api("DELETE", root.taskPath(id), null, r => {
            if (!r.ok) root.fail(r)
            root.refresh()
        })
    }

    function toggleTracking(id) {
        var stopping = id === root.currentTaskId
        root.currentTaskId = stopping ? "" : id
        var done = r => {
            if (!r.ok) root.fail(r)
            root.refresh()
        }
        if (stopping) root.api("POST", "/task-control/stop", null, done)
        else root.api("POST", root.taskPath(id) + "/start", null, done)
    }

    function launchApp() {
        var cmd = root.launchCommand.trim().split(/\s+/)
        if (cmd.length && cmd[0]) Quickshell.execDetached(cmd)
        // SP braucht ein paar Sekunden, bis die API steht.
        launchRetry.count = 0
        launchRetry.restart()
    }

    // parentScreen ist in Plugin-Widgets null, das Slideout bekaeme damit
    // keine Geometrie. Deshalb waehlt jedes Oeffnen den Schirm selbst: per
    // Klick den der Pille, per IPC den fokussierten, notfalls den ersten.
    property var slideScreen: null

    function screenByName(name) {
        var list = Quickshell.screens
        for (var i = 0; i < list.length; i++)
            if (list[i].name === name) return list[i]
        return null
    }

    function toggle(screenName) {
        if (slideout.isVisible) {
            slideout.hide()
            return
        }
        root.slideScreen = root.screenByName(screenName || "")
            || root.screenByName(BarWidgetService.getFocusedScreenName() || "")
            || Quickshell.screens[0]
        Qt.callLater(() => slideout.show())
    }

    // --------------------------------------------------------------- Zeitgeber

    Timer {
        interval: slideout.isVisible ? 10000 : root.refreshInterval * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // Faelligkeit ("heute", "ueberfaellig") rollt um Mitternacht weiter, auch
    // ohne neue Daten.
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    Timer {
        id: launchRetry
        property int count: 0
        interval: 2000
        repeat: true
        onTriggered: {
            root.refresh()
            if (root.reachable && root.loaded || ++count >= 10) stop()
        }
    }

    Timer {
        id: actionErrorTimer
        interval: 6000
        onTriggered: root.actionError = ""
    }

    Timer {
        id: disarmTimer
        interval: 3000
        onTriggered: root.armedDeleteId = ""
    }

    Component.onCompleted: root.refresh()

    // -------------------------------------------------------------------- Bar

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    pillClickAction: (x, y, width, section, screen) => root.toggle(screen ? screen.name : "")
    pillRightClickAction: () => root.launchApp()

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            opacity: root.reachable ? 1 : 0.5

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.currentTask ? "timer" : "checklist"
                color: root.currentTask ? Theme.primary : Theme.widgetTextColor
                size: root.barIconPx
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.reachable && root.loaded && root.pillCount >= 0
                text: String(root.pillCount)
                color: Theme.widgetTextColor
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showCurrentInBar && root.currentTask !== null
                text: root.currentTask ? Model.truncate(root.currentTask.title, 32) : ""
                color: Theme.widgetTextColor
                opacity: 0.85
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2
            opacity: root.reachable ? 1 : 0.5

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.currentTask ? "timer" : "checklist"
                color: root.currentTask ? Theme.primary : Theme.widgetTextColor
                size: root.barIconPx
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.reachable && root.loaded && root.pillCount >= 0
                text: String(root.pillCount)
                color: Theme.widgetTextColor
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    // ------------------------------------------------------------------ Panel

    DankSlideout {
        id: slideout
        modelData: root.slideScreen
        // Ohne title: den Kopf zeichnet das Panel selbst, damit Zaehler und
        // die Knoepfe Neu laden / SP oeffnen darin Platz haben.
        title: ""
        slideoutWidth: root.panelWidth
        slideEdge: root.slideEdge
        // Im Frame-Modus legt DankSlideout sich auf den Overlay-Layer, ueber
        // alle Popouts (die liegen auf Top). Gewollt ist das Gegenteil:
        // Popouts gehen ueber dem Panel auf. Auf demselben Layer liegt, was
        // zuletzt gezeigt wurde, oben -- also das danach geoeffnete Popout.
        WlrLayershell.layer: WlrLayershell.Top
        content: Component {
            TodoPanel {}
        }
        onRevealed: root.opened()
        onAboutToHide: root.closed()
    }

    signal focusInput

    function opened() {
        root.refresh()
        // Das Eingabefeld bekommt den Fokus, sobald das Panel steht, damit
        // man nach Super+M direkt lostippen kann.
        Qt.callLater(() => root.focusInput())
    }

    // Vor dem Zuruecksetzen: eine offene Notiz noch speichern.
    signal commitNotes

    function closed() {
        root.commitNotes()
        root.editingId = ""
        root.armedDeleteId = ""
        root.notesEditingId = ""
    }

    // Inline-Komponenten gehoeren in das Wurzelobjekt der Datei, nicht in ein
    // verschachteltes Component -- dort werden sie klaglos ignoriert.

    component TodoPanel: Item {
        id: panel

        Connections {
            target: root
            function onFocusInput() {
                newTask.forceActiveFocus()
            }
        }

        Keys.onEscapePressed: slideout.hide()

        Column {
            id: top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: Theme.spacingL
            spacing: Theme.spacingM

            // Kopf: Titel, Zaehler bzw. laufender Task, Knoepfe.
            Item {
                width: parent.width
                height: Math.max(heading.implicitHeight, headButtons.height)

                Column {
                    id: heading
                    anchors.left: parent.left
                    anchors.right: headButtons.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        text: "Todos"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: !root.reachable ? "Super Productivity nicht erreichbar"
                            : root.currentTask ? "▶ " + root.currentTask.title
                            : Model.countOpen(root.tasks, Model.FILTER_TODAY, root.now) + " heute · "
                                + Model.countOpen(root.tasks, Model.FILTER_ALL, root.now) + " offen"
                        color: root.currentTask ? Theme.primary : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                    }
                }

                Row {
                    id: headButtons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    DankActionButton {
                        iconName: "refresh"
                        tooltipText: "Neu laden"
                        enabled: !root.refreshing
                        onClicked: root.refresh()
                    }

                    DankActionButton {
                        iconName: "open_in_new"
                        tooltipText: "Super Productivity öffnen"
                        onClicked: root.launchApp()
                    }

                    DankActionButton {
                        iconName: "close"
                        tooltipText: "Schließen"
                        onClicked: slideout.hide()
                    }
                }
            }

            DankFilterChips {
                width: parent.width
                visible: root.reachable
                model: root.chips
                showCheck: false
                chipHeight: 28
                currentIndex: {
                    for (var i = 0; i < root.chips.length; i++)
                        if (root.chips[i].value === root.effectiveFilter) return i
                    return 0
                }
                onSelectionChanged: index => {
                    root.filter = root.chips[index].value
                    newTask.forceActiveFocus()
                }
            }

            DankTextField {
                id: newTask
                width: parent.width
                visible: root.reachable
                leftIconName: "add"
                placeholderText: "Neuer Task → " + root.targetLabel
                hidePlaceholderOnFocus: false
                onAccepted: {
                    if (root.addTask(text)) newTask.clear()
                }
                Keys.onEscapePressed: slideout.hide()
            }

            // Unter einem Projekt-Chip gibt es keine Kopfzeile; der Marker
            // steht dann hier.
            Row {
                readonly property var project: Model.projectById(root.projects, root.effectiveFilter)
                readonly property int count: Model.projectNoteCount(project)
                visible: root.reachable && count > 0
                spacing: Theme.spacingXS

                ProjectNotesMarker {
                    anchors.verticalCenter: parent.verticalCenter
                    count: parent.count
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (parent.count === 1 ? "1 Projekt-Notiz" : parent.count + " Projekt-Notizen") + " in Super Productivity"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }

            StyledText {
                visible: root.actionError !== ""
                width: parent.width
                text: root.actionError
                color: Theme.error
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
            }

            // -------------------------------------------- SP nicht erreichbar

            Column {
                visible: !root.reachable
                width: parent.width
                topPadding: Theme.spacingL
                bottomPadding: Theme.spacingL
                spacing: Theme.spacingM

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: root.errorCode === "NO_TOKEN" ? "key_off" : "cloud_off"
                    size: 40
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.errorMessage
                    color: Theme.surfaceText
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: root.errorCode === "NO_TOKEN"
                    text: "Einstellungen → Sonstiges → „Enable local REST API“"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                DankButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: launchRetry.running ? "Startet …" : "Super Productivity starten"
                    iconName: "play_arrow"
                    enabled: !launchRetry.running
                    onClicked: root.launchApp()
                }
            }
        }

        // ----------------------------------------------------------- Liste
        // Fuellt den Rest des Panels bis zur Unterkante.

        ListView {
            id: list
            visible: root.reachable
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: top.bottom
            anchors.topMargin: Theme.spacingM
            anchors.bottom: parent.bottom
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            model: root.rows

            delegate: Loader {
                id: rowLoader
                required property var modelData
                width: ListView.view.width
                // Hoehe ausdruecklich aus dem Inhalt: ein aufklappender Task
                // waechst, und ohne diese Bindung bliebe der Loader bei der
                // Hoehe beim Laden -- die Notiz laege dann ueber der naechsten
                // Zeile.
                height: item ? item.implicitHeight : 0
                sourceComponent: modelData.kind === "task" ? taskRow
                    : modelData.kind === "header" ? headerRow : doneHeaderRow
                onLoaded: item.row = rowLoader.modelData
                onModelDataChanged: if (item) item.row = rowLoader.modelData
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                y: Theme.spacingL
                visible: root.loaded && list.count === 0
                text: root.effectiveFilter === Model.FILTER_TODAY ? "Für heute ist nichts offen." : "Nichts offen."
                color: Theme.surfaceVariantText
            }
        }

        Component {
            id: headerRow
            HeaderRow {}
        }
        Component {
            id: doneHeaderRow
            DoneHeaderRow {}
        }
        Component {
            id: taskRow
            TaskRow {}
        }
    }

    component HeaderRow: Item {
        property var row: ({})
        implicitHeight: 30

        Rectangle {
            id: dot
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            width: 8
            height: 8
            radius: 4
            color: parent.row.color || Theme.outline
        }

        StyledText {
            id: headTitle
            anchors.left: dot.right
            anchors.leftMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: parent.row.title || ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
        }

        ProjectNotesMarker {
            anchors.left: headTitle.right
            anchors.leftMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            count: parent.row.notes || 0
        }
    }

    // Marker fuer Projekt-Notizen. Lesen kann das Plugin sie nicht (die API
    // liefert nur noteIds), darum holt ein Klick SP nach vorn.
    component ProjectNotesMarker: Item {
        id: marker
        property int count: 0
        visible: count > 0
        implicitWidth: markerRow.implicitWidth
        implicitHeight: markerRow.implicitHeight

        // Die MouseArea liegt neben der Row, nicht in ihr: als Kind der Row
        // zaehlte ihre Breite (marker.width + 8) in die Breite der Row, die
        // wieder die MouseArea verbreiterte -- eine Polish-Schleife, die Qt
        // abbricht, und danach legte sich im ganzen Panel kein Positionierer
        // mehr aus (Kopf, Chips, Eingabefeld fehlten, Notizen klappten nicht
        // auf).
        Row {
            id: markerRow
            spacing: 2

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                // "comment" wie SPs Knopf fuer Projekt-Notizen.
                name: "comment"
                size: 14
                color: Theme.primary
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: marker.count > 1
                text: String(marker.count)
                color: Theme.primary
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: root.launchApp()
        }
    }

    component DoneHeaderRow: Item {
        property var row: ({})
        implicitHeight: 30

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.showDone = !root.showDone
        }

        DankIcon {
            id: chevron
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: root.showDone ? "expand_more" : "chevron_right"
            size: 18
            color: Theme.surfaceVariantText
        }

        StyledText {
            anchors.left: chevron.right
            anchors.leftMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            text: "Erledigt (" + (parent.row.count || 0) + ")"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    component TaskRow: Item {
        id: taskItem
        property var row: ({})
        readonly property bool editing: root.editingId !== "" && root.editingId === row.id
        readonly property bool armed: root.armedDeleteId !== "" && root.armedDeleteId === row.id
        readonly property bool showActions: rowHover.hovered || armed || row.isCurrent === true
        readonly property bool open: root.openId !== "" && root.openId === row.id
        readonly property bool hasNotes: String(row.notes || "").trim() !== ""
        implicitHeight: 36 + (open ? notesBox.height + Theme.spacingXS : 0)

        // Kopfzeile des Tasks; darunter klappen die Notizen auf.
        Item {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 36

            Rectangle {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: taskItem.row.isCurrent ? Theme.withAlpha(Theme.primary, 0.12)
                    : rowHover.hovered ? Theme.surfaceHover : "transparent"
            }

            // Hover fuer die ganze Zeile per HoverHandler: der bleibt auch
            // ueber den Knoepfen an. Mit hoverEnabled an der MouseArea nahm
            // der Knopf ihr den Hover weg, die Knoepfe verschwanden, die Zeile
            // bekam ihn zurueck, sie erschienen wieder -- es flackerte.
            HoverHandler {
                id: rowHover
                cursorShape: Qt.PointingHandCursor
            }

            // Die ganze Zeile: Klick klappt den Task auf (Notizen), Doppelklick
            // benennt um -- der Doppelklick klappt dabei auch auf, das stoert
            // nicht. Checkbox und Knoepfe liegen darueber und fangen ihre
            // Klicks selbst; abgehakt wird nur ueber die Checkbox.
            MouseArea {
                anchors.fill: parent
                onClicked: root.toggleOpen(taskItem.row.id)
                onDoubleClicked: root.editingId = taskItem.row.id
            }

            DankIcon {
                id: check
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingXS + (taskItem.row.depth || 0) * 22
                anchors.verticalCenter: parent.verticalCenter
                name: taskItem.row.isDone ? "check_box" : "check_box_outline_blank"
                filled: taskItem.row.isDone === true
                size: 20
                color: taskItem.row.isDone ? Theme.primary : Theme.surfaceVariantText

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setDone(taskItem.row.id, !taskItem.row.isDone)
                }
            }

            // Ueberfaellig: rotes Kalender-Icon vor dem Titel, wie SP sein
            // Datums-Icon (today) bei ueberfaelligen Tasks rot faerbt. Rechts
            // in der Meta-Spalte stand frueher "ueberfaellig" und tauschte
            // beim Ueberfahren mit den Knoepfen -- das sprang und wirkte
            // uebereinander.
            DankIcon {
                id: overdueIcon
                visible: taskItem.row.due === "overdue" && !taskItem.editing
                anchors.left: check.right
                anchors.leftMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                name: "today"
                size: 16
                color: Theme.error
            }

            StyledText {
                id: titleText
                visible: !taskItem.editing
                anchors.left: overdueIcon.visible ? overdueIcon.right : check.right
                anchors.leftMargin: overdueIcon.visible ? Theme.spacingXS : Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                // So breit wie der Titel, damit der Notiz-Marker direkt
                // dahinter sitzt; hoechstens bis vor die Meta-Spalte.
                width: Math.max(0, Math.min(implicitWidth,
                    meta.x - x - Theme.spacingS - (noteMarker.visible ? noteMarker.width + Theme.spacingXS : 0)))
                text: taskItem.row.title || ""
                elide: Text.ElideRight
                maximumLineCount: 1
                color: taskItem.row.isDone ? Theme.surfaceVariantText : Theme.surfaceText
                font.strikeout: taskItem.row.isDone === true

            }

            // Marker: der Task hat Notizen. Immer sichtbar, aufgeklappt gefuellt.
            DankIcon {
                id: noteMarker
                visible: taskItem.hasNotes && !taskItem.editing
                anchors.left: titleText.right
                anchors.leftMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                // "chat" wie SPs Notiz-Anzeige in der Task-Liste.
                name: "chat"
                filled: taskItem.open
                size: 16
                color: taskItem.row.isDone ? Theme.surfaceVariantText : Theme.primary
            }

            DankTextField {
                id: editField
                visible: taskItem.editing
                anchors.left: check.right
                anchors.leftMargin: Theme.spacingS
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: 32
                onVisibleChanged: {
                    if (!visible) return
                    text = taskItem.row.title || ""
                    forceActiveFocus()
                    selectAll()
                }
                onAccepted: root.rename(taskItem.row.id, text)
                Keys.onEscapePressed: event => {
                    root.editingId = ""
                    event.accepted = true
                }
            }

            Row {
                id: meta
                visible: !taskItem.editing
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !taskItem.showActions && Model.durationLabel(taskItem.row.timeSpent) !== ""
                    text: Model.durationLabel(taskItem.row.timeSpent)
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                DankActionButton {
                    visible: taskItem.showActions && !taskItem.row.isDone
                    buttonSize: 28
                    iconName: taskItem.row.isCurrent ? "pause" : "play_arrow"
                    iconColor: taskItem.row.isCurrent ? Theme.primary : Theme.surfaceText
                    tooltipText: taskItem.row.isCurrent ? "Zeiterfassung pausieren" : "Zeiterfassung starten"
                    onClicked: root.toggleTracking(taskItem.row.id)
                }

                DankActionButton {
                    visible: taskItem.showActions
                    buttonSize: 28
                    iconName: "delete_forever"
                    iconColor: taskItem.armed ? Theme.error : Theme.surfaceVariantText
                    tooltipText: taskItem.armed ? "Nochmal klicken zum Löschen" : "Löschen"
                    onClicked: root.requestDelete(taskItem.row.id)
                }
            }
        }

        NotesBox {
            id: notesBox
            visible: taskItem.open
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingXS + (taskItem.row.depth || 0) * 22 + 20 + Theme.spacingS
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingXS
            anchors.top: head.bottom
            anchors.topMargin: Theme.spacingXS
            taskId: taskItem.row.id || ""
            notes: taskItem.row.notes || ""
        }
    }

    // Notizen eines aufgeklappten Tasks. Sie sind in SP Markdown: angezeigt
    // formatiert (Listen, fett, Checklisten), ein Klick schaltet auf das rohe
    // Markdown zum Bearbeiten. Gespeichert wird 800 ms nach der letzten
    // Eingabe, beim Verlassen des Felds, mit Esc und beim Schliessen des
    // Panels (root.commitNotes).
    component NotesBox: Item {
        id: box
        property string taskId: ""
        property string notes: ""
        readonly property bool editing: root.notesEditingId !== "" && root.notesEditingId === taskId
        // Stand beim Beginn des Bearbeitens: dagegen prueft notesPatch.
        property string savedNotes: ""

        height: editing ? editor.height : Math.max(view.implicitHeight, 24)

        function beginEdit() {
            box.savedNotes = box.notes
            editor.text = box.notes
            root.notesEditingId = box.taskId
            Qt.callLater(() => {
                editor.forceActiveFocus()
                editor.cursorPosition = editor.text.length
            })
        }

        function commit() {
            if (!box.editing) return
            root.saveNotes(box.taskId, box.savedNotes, editor.text)
            box.savedNotes = Model.normalizeNotes(editor.text)
        }

        function endEdit() {
            box.commit()
            saveTimer.stop()
            root.notesEditingId = ""
            root.refresh()
        }

        Connections {
            target: root
            function onCommitNotes() {
                box.commit()
            }
        }

        // Zugeklappt oder aus der Liste gescrollt: offene Aenderung nicht
        // verlieren.
        onVisibleChanged: if (!visible && box.editing) box.endEdit()
        Component.onDestruction: box.commit()

        Timer {
            id: saveTimer
            interval: 800
            onTriggered: box.commit()
        }

        StyledText {
            id: view
            visible: !box.editing
            width: parent.width
            text: box.notes.trim() !== "" ? box.notes : "Notiz hinzufügen …"
            textFormat: box.notes.trim() !== "" ? Text.MarkdownText : Text.PlainText
            wrapMode: Text.Wrap
            color: box.notes.trim() !== "" ? Theme.surfaceText : Theme.surfaceVariantText
            linkColor: Theme.primary
            font.pixelSize: Theme.fontSizeSmall

            // Links oeffnen, sonst bearbeiten.
            MouseArea {
                anchors.fill: parent
                cursorShape: view.linkAt(mouseX, mouseY) !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
                onClicked: mouse => {
                    var link = view.linkAt(mouse.x, mouse.y)
                    if (link !== "") root.openLink(link)
                    else box.beginEdit()
                }
            }
        }

        DankTextEdit {
            id: editor
            visible: box.editing
            width: parent.width
            // Waechst mit den Zeilen, 4 bis 14; darueber scrollt das Feld.
            height: Math.round(Theme.fontSizeSmall * 1.5
                * Math.max(4, Math.min(14, editor.text.split("\n").length + 1)))
                + Theme.spacingS * 2
            font.pixelSize: Theme.fontSizeSmall
            placeholderText: "Notiz (Markdown) …"
            keyForwardTargets: [editorKeys]
            onTextEdited: saveTimer.restart()
            onEditingFinished: if (box.editing) box.endEdit()

            Item {
                id: editorKeys
                Keys.onEscapePressed: event => {
                    box.endEdit()
                    event.accepted = true
                }
            }
        }
    }

    // -------------------------------------------------------------------- IPC

    // Steuerung von aussen, etwa per Tastenkuerzel aus niri/config.kdl:
    //   dms ipc call superProductivity toggle|refresh|add <titel>|status
    // Zwei Fallen wie bei den anderen Plugins: jede Bar instanziiert das
    // Widget, bei mehreren Monitoren antwortet die zuerst registrierte
    // Instanz; und nach "dms ipc call plugins reload" haengt das Target an der
    // alten Instanz (quickshell#898) -- dann hilft nur ein Neustart der Shell.
    IpcHandler {
        target: "superProductivity"

        function toggle(): string {
            root.toggle()
            return "ok"
        }
        function refresh(): string {
            root.refresh()
            return "ok"
        }
        function add(title: string): string {
            return root.addTask(title) ? "ok" : "leerer Titel"
        }
        function status(): string {
            if (!root.reachable) return root.errorMessage
            var s = Model.countOpen(root.tasks, Model.FILTER_TODAY, root.now) + " heute, "
                + Model.countOpen(root.tasks, Model.FILTER_ALL, root.now) + " offen"
            return root.currentTask ? s + ", läuft: " + root.currentTask.title : s
        }
    }
}
