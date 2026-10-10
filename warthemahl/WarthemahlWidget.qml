import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Die WartheMahl-Wochenkarte als DMS-Bar-Widget: Port des Omarchy-Plugins
// likt0r.warthemahl. Model.js und bin/warthemahl-menu sind bis auf
// Material-Icon-Namen und den Cache-Pfad unveraendert uebernommen; das
// Omarchy-Panel ist auf PluginComponent/PopoutComponent uebersetzt
// (Zuordnung: docs/omarchy-to-dms.md im dotfiles-Repo). Weggefallen ist die
// Tastatur-Navigation des Omarchy-Panels -- das DMS-Popout hat keinen
// KeyCatcher, nur Esc zum Schliessen.
PluginComponent {
    id: root

    property var popoutService: null

    // Neben dieser Datei aufgeloest statt ueber PATH gesucht, damit das Plugin
    // ohne Installationsschritt aus seinem eigenen Verzeichnis laeuft.
    readonly property string helperPath: {
        var url = Qt.resolvedUrl("bin/warthemahl-menu").toString()
        return url.indexOf("file://") === 0 ? url.substring(7) : url
    }

    property var menu: Model.emptyMenu()
    property bool loading: false
    // Relative Zeitstempel und "welcher Tag ist heute" brauchen eine Uhr, die
    // tickt; ein nacktes new Date() in einem Binding bliebe beim Laden stehen.
    property date now: new Date()

    // Einstellungen kommen reaktiv aus pluginData; der Veg-Schalter im Popout
    // schreibt per savePluginData dieselben Schluessel wie Settings.qml
    // (Ersatz fuer bar.shell.updateEntryInline im Omarchy-Original).
    readonly property bool vegetarianOnly: pluginData?.vegetarianOnly === true
    readonly property bool showTodayInBar: pluginData?.showTodayInBar === true
    readonly property int refreshIntervalSec: Math.max(60, Math.round((Number(pluginData?.refreshIntervalMin) || 60) * 60))

    readonly property int todayIndex: Model.todayIndex(root.menu.days, root.now)
    readonly property string weekNote: Model.weekNote(root.menu, root.now)
    readonly property bool hasDays: root.menu.days.length > 0

    // Bar-Zeile neben dem Icon: das erste sichtbare Gericht des Tages. Laeuft
    // ueber visibleDishes statt Model.barLabel, damit der Vegetarier-Filter
    // auch hier greift und niemandem das Fleischgericht angezeigt wird.
    readonly property string barText: {
        if (!root.showTodayInBar || root.todayIndex < 0) return ""
        var rows = Model.visibleDishes(root.menu.days[root.todayIndex], root.vegetarianOnly)
        return rows.length ? Model.truncate(rows[0].text, 40) : ""
    }

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    popoutWidth: 440

    // Nur zeigen, wenn die Karte ueberhaupt etwas nuetzt: werktags bis 14 Uhr.
    // Danach ist Mittag durch, am Wochenende hat die Kantine zu. Die Pille
    // faellt dann auf Breite 0 (PluginComponent faehrt sie ueber
    // effectiveVisible zusammen); uebrig bleibt das Spacing der Sektion.
    // Das Popout bleibt per "dms ipc call warthemahl toggle" erreichbar.
    visibilityCommand: "[ \"$(date +%u)\" -le 5 ] && [ \"$(date +%H)\" -lt 14 ]"
    visibilityInterval: 600

    function refresh(force) {
        if (fetchProc.running) return
        root.now = new Date()
        root.loading = true
        fetchProc.command = force
            ? [root.helperPath]
            : [root.helperPath, "--max-age", String(root.refreshIntervalSec)]
        fetchProc.running = true
    }

    function applyPayload(text) {
        var parsed = Model.parsePayload(text)
        if (!parsed) return
        root.menu = parsed
    }

    function failWith(message) {
        // Nur dann einen harten Fehler behaupten, wenn nichts Vertrauenswuerdiges
        // auf dem Schirm steht; eine alte geparste Karte schlaegt eine Fehlerbox.
        if (root.hasDays) return
        var empty = Model.emptyMenu()
        empty.error = message
        root.menu = empty
    }

    function setVegetarianOnly(value) {
        pluginService?.savePluginData(root.pluginId, "vegetarianOnly", value === true)
    }

    function openPdf() {
        if (root.menu.pdfUrl === "") { root.openSite(); return }
        Quickshell.execDetached(["xdg-open", root.menu.pdfUrl])
    }

    function openSite() {
        var url = root.menu.sourceUrl !== "" ? root.menu.sourceUrl : "https://warthemahl.de/speisekarte/"
        Quickshell.execDetached(["xdg-open", url])
    }

    // Rechtsklick erzwingt einen Abruf wie im Omarchy-Plugin; PDF und Website
    // haben Knoepfe im Popout-Kopf (Mittelklick kennt PluginComponent nicht).
    pillRightClickAction: () => root.refresh(true)

    Component.onCompleted: root.refresh(false)

    // Steuerung von aussen (Keybind in niri/config.kdl):
    //   dms ipc call warthemahl toggle|refresh|vegetarian|status
    // Wie im ExampleCompositePlugin ein nackter IpcHandler. Zwei Fallen:
    // jede Bar instanziiert das Widget, bei mehreren Monitoren antwortet die
    // zuerst registrierte Instanz; und nach "dms ipc call plugins reload"
    // haengt der Target an der alten Instanz (quickshell#898) -- dann hilft
    // nur ein Neustart der Shell.
    IpcHandler {
        target: "warthemahl"
        function toggle(): string { root.triggerPopout(); return "ok" }
        function refresh(): string { root.refresh(true); return "ok" }
        function vegetarian(): string {
            var newValue = !root.vegetarianOnly
            root.setVegetarianOnly(newValue)
            return newValue ? "on" : "off"
        }
        function status(): string { return Model.tooltipText(root.menu, new Date(), root.vegetarianOnly) }
    }

    Process {
        id: fetchProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyPayload(text)
        }
        stderr: StdioCollector { waitForEnd: true }
        onExited: exitCode => {
            root.loading = false
            // Der Helfer meldet seine eigenen Probleme im JSON; ein Exit != 0
            // heisst, er kam gar nicht so weit -- fehlender Interpreter,
            // verlorenes Ausfuehrungsbit, abgeschossener Prozess.
            if (exitCode !== 0) root.failWith("Speisekarten-Helfer fehlgeschlagen (Code " + exitCode + ")")
            else if (!root.hasDays && root.menu.error === "") root.failWith("Keine Speisekarte empfangen")
        }
    }

    // Haelt "vor 12 Min." ehrlich und rollt die HEUTE-Markierung ueber
    // Mitternacht, auch waehrend das Popout offen steht.
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    // Hintergrund-Abruf, damit die Bar-Zeile das heutige Gericht kennt, bevor
    // jemand klickt. Cache-schonend: ein Tick kostet meist nur einen Lesezugriff.
    Timer {
        interval: Math.min(6 * 3600 * 1000, root.refreshIntervalSec * 1000)
        running: true
        repeat: true
        onTriggered: root.refresh(false)
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "restaurant"
                color: Theme.widgetTextColor
                size: root.barIconPx
            }

            StyledText {
                visible: root.barText !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.barText
                color: Theme.widgetTextColor
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: pillIconV.width
            implicitHeight: pillIconV.height

            DankIcon {
                id: pillIconV
                anchors.centerIn: parent
                name: "restaurant"
                color: Theme.widgetTextColor
                size: root.barIconPx
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "WartheMahl"
            detailsText: (root.menu.weekLabel !== "" ? root.menu.weekLabel : "Speisekarte der Woche")
                + (root.menu.stale ? " · OFFLINE" : "")
            showCloseButton: true

            // Jedes Oeffnen zieht cache-schonend nach -- das Gegenstueck zu
            // onOpenedChanged im Omarchy-Panel.
            Component.onCompleted: root.refresh(false)
            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popout.parentPopout.shouldBeVisible) root.refresh(false)
                }
            }

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS

                    DankActionButton {
                        iconName: "refresh"
                        tooltipText: "Neu laden"
                        enabled: !root.loading
                        onClicked: root.refresh(true)
                    }

                    DankActionButton {
                        iconName: "picture_as_pdf"
                        tooltipText: "Speisekarte als PDF"
                        enabled: root.menu.pdfUrl !== ""
                        onClicked: root.openPdf()
                    }

                    DankActionButton {
                        iconName: "open_in_new"
                        tooltipText: "warthemahl.de oeffnen"
                        onClicked: root.openSite()
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // DankToggle bemisst sich mit text selbst ueber die volle
                // Breite (Label links, Schalter rechts) -- kein Wrapper noetig.
                DankToggle {
                    width: parent.width
                    text: "Nur vegetarisch"
                    checked: root.vegetarianOnly
                    onToggled: checked => root.setVegetarianOnly(checked)
                }

                StyledText {
                    visible: root.weekNote !== "" && root.hasDays
                    width: parent.width
                    leftPadding: Theme.spacingS
                    text: root.weekNote
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }

                DankFlickable {
                    width: parent.width
                    height: Math.min(daysColumn.implicitHeight, 460)
                    contentHeight: daysColumn.implicitHeight
                    clip: true

                    Column {
                        id: daysColumn
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.menu.days

                            // Ein Tag der Woche: Datumskopf plus jedes gelistete
                            // Gericht. Die heutige Karte traegt Rahmen und
                            // hellere Flaeche, damit sie ohne Suchen als Antwort
                            // auf "was gibt es jetzt" lesbar ist.
                            StyledRect {
                                id: card

                                required property var modelData
                                required property int index
                                readonly property bool isToday: root.todayIndex === card.index

                                width: daysColumn.width
                                radius: Theme.cornerRadius
                                color: card.isToday ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                                border.color: card.isToday ? Theme.primary : "transparent"
                                border.width: card.isToday ? 1 : 0
                                implicitHeight: cardBody.implicitHeight + Theme.spacingM * 2

                                Column {
                                    id: cardBody
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingXS

                                    Item {
                                        width: parent.width
                                        height: Math.max(weekdayText.implicitHeight, dateText.implicitHeight)

                                        StyledText {
                                            id: weekdayText
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: card.modelData ? String(card.modelData.weekday || "") : ""
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Bold
                                        }

                                        StyledText {
                                            visible: card.isToday
                                            anchors.right: dateText.left
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "HEUTE"
                                            color: Theme.primary
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Bold
                                            font.letterSpacing: 1
                                        }

                                        StyledText {
                                            id: dateText
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: card.modelData ? String(card.modelData.dateLabel || "") : ""
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                        }
                                    }

                                    Repeater {
                                        model: Model.visibleDishes(card.modelData, root.vegetarianOnly)

                                        // Umgebrochener Gerichtstext treibt die
                                        // Zeilenhoehe ueber contentHeight: die
                                        // Icon-Spalte ist fix, der Text bekommt
                                        // den Rest und die Zeile seine Hoehe.
                                        Item {
                                            id: dishRow
                                            required property var modelData

                                            width: cardBody.width
                                            height: Math.max(dishGlyph.height, dishText.contentHeight)

                                            DankIcon {
                                                id: dishGlyph
                                                anchors.left: parent.left
                                                anchors.top: parent.top
                                                name: Model.dishIcon(dishRow.modelData.index, dishRow.modelData.text)
                                                color: dishRow.modelData.index === 0 ? Theme.surfaceText : Theme.primary
                                                opacity: dishRow.modelData.index === 0 ? 0.75 : 0.9
                                                size: Theme.iconSizeSmall
                                            }

                                            StyledText {
                                                id: dishText
                                                anchors.left: parent.left
                                                anchors.leftMargin: Theme.iconSizeSmall + Theme.spacingS
                                                anchors.right: parent.right
                                                anchors.top: parent.top
                                                text: String(dishRow.modelData.text || "")
                                                color: Theme.surfaceText
                                                opacity: dishRow.modelData.index === 0 ? 1.0 : 0.82
                                                font.pixelSize: Theme.fontSizeSmall
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }

                                    StyledText {
                                        visible: root.vegetarianOnly && Model.visibleDishes(card.modelData, true).length === 0
                                        width: cardBody.width
                                        text: "Keine vegetarische Option"
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.italic: true
                                    }
                                }
                            }
                        }
                    }
                }

                // Nichts geparst: entweder schlug der Abruf fehl oder die Seite
                // hat ihre Form geaendert. In beiden Faellen steht der Grund da,
                // und die Website-Schaltflaeche oben bleibt der Ausweg.
                StyledText {
                    visible: !root.hasDays
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.loading ? "Speisekarte wird geladen…"
                        : (root.menu.error !== "" ? root.menu.error : "Keine Speisekarte gefunden")
                    color: root.loading ? Theme.surfaceVariantText : Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    leftPadding: Theme.spacingS
                    text: Model.statusLine(root.menu, root.now, root.loading)
                    color: root.menu.stale || (!root.hasDays && !root.loading) ? Theme.error : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    elide: Text.ElideRight
                }
            }
        }
    }
}
