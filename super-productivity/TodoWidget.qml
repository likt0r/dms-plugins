import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Todos aus Super Productivity: Pille in der Bar, Klick klappt ein Panel von
// der Bildschirmkante herein (DankSlideout, wie das Notepad von DMS). Dort
// werden Tasks angelegt, abgehakt, umbenannt, geloescht und die
// Zeiterfassung gestartet.
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
    readonly property string slideEdge: pluginData?.slideEdge === "left" ? "left" : "right"
    readonly property real panelWidth: Math.max(320, Number(pluginData?.panelWidth ?? 420))
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
        if (root.editingId !== "") return
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

    // parentScreen ist in Plugin-Widgets null, das Slideout bekaeme damit keine
    // Geometrie. Deshalb waehlt jedes Oeffnen den Schirm selbst: per Klick den
    // der Pille, per IPC den fokussierten, notfalls den ersten.
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
        title: "Todos"
        slideoutWidth: root.panelWidth
        slideEdge: root.slideEdge
        content: Component {
            TodoPanel {}
        }
        onRevealed: root.refresh()
        onAboutToHide: {
            root.editingId = ""
            root.armedDeleteId = ""
        }
    }

    // Inline-Komponenten gehoeren in das Wurzelobjekt der Datei, nicht in ein
    // verschachteltes Component -- dort werden sie klaglos ignoriert.

    component TodoPanel: Item {
        id: panel

        // Das Eingabefeld bekommt den Fokus, sobald das Panel aufgeht, damit
        // man nach dem Tastenkuerzel direkt lostippen kann.
        Connections {
            target: slideout
            function onRevealed() {
                newTask.forceActiveFocus()
            }
        }
        Component.onCompleted: newTask.forceActiveFocus()

        Keys.onEscapePressed: slideout.hide()

        Column {
            id: top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Theme.spacingM

            DankFilterChips {
                width: parent.width
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
                enabled: root.reachable
                leftIconName: "add"
                placeholderText: "Neuer Task → " + root.targetLabel
                hidePlaceholderOnFocus: false
                onAccepted: {
                    if (root.addTask(text)) newTask.clear()
                }
                Keys.onEscapePressed: slideout.hide()
            }

            StyledText {
                visible: root.actionError !== ""
                width: parent.width
                text: root.actionError
                color: Theme.error
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
            }
        }

        // ------------------------------------------------ SP nicht erreichbar

        Column {
            visible: !root.reachable
            anchors.centerIn: parent
            width: parent.width - Theme.spacingL * 2
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

        // ------------------------------------------------------------- Liste

        ListView {
            id: list
            visible: root.reachable
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: top.bottom
            anchors.topMargin: Theme.spacingM
            anchors.bottom: footer.top
            anchors.bottomMargin: Theme.spacingS
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            model: root.rows

            delegate: Loader {
                id: rowLoader
                required property var modelData
                width: ListView.view.width
                sourceComponent: modelData.kind === "task" ? taskRow
                    : modelData.kind === "header" ? headerRow : doneHeaderRow
                onLoaded: item.row = rowLoader.modelData
                onModelDataChanged: if (item) item.row = rowLoader.modelData
            }

            StyledText {
                anchors.centerIn: parent
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

        // ------------------------------------------------------------- Fuss

        Row {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Theme.spacingXS
            layoutDirection: Qt.RightToLeft

            DankActionButton {
                iconName: "open_in_new"
                tooltipText: "Super Productivity öffnen"
                onClicked: root.launchApp()
            }

            DankActionButton {
                iconName: "refresh"
                tooltipText: "Neu laden"
                enabled: !root.refreshing
                onClicked: root.refresh()
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.currentTask !== null
                width: footer.width - 2 * 32 - 2 * footer.spacing
                horizontalAlignment: Text.AlignLeft
                elide: Text.ElideRight
                text: root.currentTask ? "▶ " + root.currentTask.title : ""
                color: Theme.primary
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    component HeaderRow: Item {
        property var row: ({})
        height: 30

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
            anchors.left: dot.right
            anchors.leftMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: parent.row.title || ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
        }
    }

    component DoneHeaderRow: Item {
        property var row: ({})
        height: 30

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
        readonly property bool showActions: hover.containsMouse || armed || row.isCurrent === true
        height: 36

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: taskItem.row.isCurrent ? Theme.withAlpha(Theme.primary, 0.12)
                : hover.containsMouse ? Theme.surfaceHover : "transparent"
        }

        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
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

        StyledText {
            id: titleText
            visible: !taskItem.editing
            anchors.left: check.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: meta.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: taskItem.row.title || ""
            elide: Text.ElideRight
            maximumLineCount: 1
            color: taskItem.row.isDone ? Theme.surfaceVariantText : Theme.surfaceText
            font.strikeout: taskItem.row.isDone === true

            // Doppelklick benennt um. Abgehakt wird nur ueber die Checkbox:
            // ein Einfachklick auf den Titel kaeme beim Doppelklick sonst
            // vorher an und haette den Task schon erledigt.
            MouseArea {
                anchors.fill: parent
                onDoubleClicked: root.editingId = taskItem.row.id
            }
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
                visible: taskItem.row.due === "overdue" && !taskItem.showActions
                text: "überfällig"
                color: Theme.error
                font.pixelSize: Theme.fontSizeSmall
            }

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
                iconName: taskItem.row.isCurrent ? "stop" : "play_arrow"
                iconColor: taskItem.row.isCurrent ? Theme.primary : Theme.surfaceText
                tooltipText: taskItem.row.isCurrent ? "Zeiterfassung stoppen" : "Zeiterfassung starten"
                onClicked: root.toggleTracking(taskItem.row.id)
            }

            DankActionButton {
                visible: taskItem.showActions
                buttonSize: 28
                iconName: taskItem.armed ? "delete_forever" : "delete"
                iconColor: taskItem.armed ? Theme.error : Theme.surfaceVariantText
                tooltipText: taskItem.armed ? "Nochmal klicken zum Löschen" : "Löschen"
                onClicked: root.requestDelete(taskItem.row.id)
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
