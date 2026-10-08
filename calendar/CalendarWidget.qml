import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Datum und Uhrzeit in der Bar, Klick oeffnet Monatsraster, Tagesagenda und
// das Detailpanel eines Termins.
//
// Die Termine kommen aus CalendarService, nicht aus einer eigenen Quelle:
// der Dienst spricht mit dem dcal-Daemon, filtert ausgeblendete Kalender und
// abgesagte Termine schon heraus und schneidet mehrtaegige Termine pro Tag
// zu. Dieses Plugin zeichnet nur.
//
// Nachfolger von likt0r.calendar (Omarchy). Das Erscheinungsbild folgt dem
// Vorgaenger: durchgehend Monospace, grosse Datumsueberschrift, Jahresbalken,
// Monatsnavigation unter dem Gitter, heute als duenner Rahmen statt Kreis,
// vergangene Termine durchgestrichen, Details als eigene Spalte rechts.
// Die Farben kommen dabei aus dem DMS-Theme, nicht aus Omarchy.
PluginComponent {
    id: root

    // ---------------------------------------------------------------- Zeit

    // Minutengenau reicht: feiner zeigt kein Format, und die "Jetzt"-Linie
    // springt ohnehin nur zur vollen Minute.
    SystemClock {
        id: sysClock
        precision: SystemClock.Minutes
    }

    readonly property date now: sysClock.date
    readonly property string todayKey: Model.keyForDate(root.now)

    // --------------------------------------------------- Einstellungen

    readonly property var loc: Qt.locale(Model.localeName(pluginData?.locale, Qt.locale().name))
    readonly property string barFormat: String(pluginData?.barFormat ?? "ddd dd.MM. HH:mm")
    readonly property string barFormatVertical: String(pluginData?.barFormatVertical ?? "HH\n—\nmm")
    readonly property bool showNextEvent: pluginData?.showNextEvent === true
    readonly property int nextEventHorizon: Math.max(1, Number(pluginData?.nextEventHorizon ?? 8))
    readonly property bool hidePast: pluginData?.hidePast === true
    readonly property bool showYearBar: pluginData?.showYearBar !== false
    readonly property int weekStart: Model.normalizedWeekStart(pluginData?.weekStart, root.loc.firstDayOfWeek)
    readonly property bool use24Hour: SettingsData.use24HourClock !== false

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
    readonly property real barTextPx: Theme.barTextSize(root.barThickness)

    // ------------------------------------------------------------- Masse
    //
    // Feste Zellen statt anteiliger Breiten: das Raster soll in jedem Monat
    // gleich aussehen, und eine Monospace-Schrift lebt von festen Spalten.

    readonly property int cellW: 62
    readonly property int cellH: 54
    readonly property int weekColW: 34
    readonly property int panePad: 36
    readonly property int gridW: root.weekColW + 7 * root.cellW
    readonly property int calWidth: root.gridW + 2 * root.panePad
    readonly property int detailWidth: 436
    readonly property int timeColW: 112
    // Was vom Bildschirm uebrig bleibt: Bar oben, dazu der Rand, den
    // PluginPopout oben und unten laesst, plus etwas Luft zur Kante.
    readonly property real screenAvail: Math.max(320,
        (root.parentScreen?.height ?? 1080) - root.barThickness - 72)
    // PluginPopout setzt den Inhalt mit Theme.spacingS Rand auf beiden Seiten
    // (PluginPopout.qml:56). Wer das nicht einrechnet, verliert rechts genau
    // diese 16 Pixel -- bei mir war das der halbe Beitreten-Knopf.
    readonly property int popoutChrome: Theme.spacingS * 2

    // ------------------------------------------------------------ Zustand

    property int viewYear: root.now.getFullYear()
    property int viewMonth: root.now.getMonth()
    property string selectedKey: root.todayKey
    // Welcher Termin rechts aufgeschlagen ist. Leer = Detailspalte zu, und
    // dann ist das Popout nur so breit wie der Kalender.
    property string expandedId: ""

    // ------------------------------------------------------------- Daten

    readonly property var eventsByDate: CalendarService.eventsByDate
    readonly property bool backendReady: CalendarService.calendarAvailable

    function eventsFor(key) {
        var map = root.eventsByDate || ({})
        return map[key] || []
    }

    readonly property var selectedAll: root.eventsFor(root.selectedKey)
    readonly property var selectedEvents: Model.visibleForDay(
        root.selectedAll, root.selectedKey, { hidePast: root.hidePast, now: root.now })
    readonly property int hiddenCount: Math.max(0, root.selectedAll.length - root.selectedEvents.length)

    readonly property var upcoming: Model.nextEvent(root.eventsByDate, root.now, root.nextEventHorizon)

    readonly property var detailEvent: {
        if (root.expandedId === "")
            return null
        var list = root.selectedEvents
        for (var i = 0; i < list.length; i++)
            if (String(list[i].id || "") === root.expandedId)
                return list[i]
        return null
    }

    // CalendarService laedt ein Fenster um ein focusDate herum und zieht erst
    // nach, wenn der Rand naeher als 14 Tage kommt. Beim Monatswechsel also
    // ruhig melden -- der Dienst entscheidet selbst, ob das eine Abfrage wert
    // ist. Ohne diesen Anstoss bleibt eventsByDate leer, solange niemand
    // sonst (etwa das Dash) schon geladen hat.
    function ensureRange() {
        var from = new Date(root.viewYear, root.viewMonth - 1, 1)
        var to = new Date(root.viewYear, root.viewMonth + 2, 0)
        CalendarService.loadEvents(from, to)
    }

    Component.onCompleted: root.ensureRange()
    onViewMonthChanged: root.ensureRange()
    onViewYearChanged: root.ensureRange()

    // ----------------------------------------------------------- Aktionen

    function goToToday() {
        root.viewYear = root.now.getFullYear()
        root.viewMonth = root.now.getMonth()
        root.selectedKey = root.todayKey
        root.expandedId = ""
    }

    function stepMonth(delta) {
        var next = Model.stepMonth(root.viewYear, root.viewMonth, delta)
        root.viewYear = next.year
        root.viewMonth = next.month
        root.expandedId = ""
    }

    function selectDay(key) {
        root.selectedKey = key
        root.expandedId = ""
    }

    function cycleFormat() {
        var vertical = root.barConfig?.position === "left" || root.barConfig?.position === "right"
        var key = vertical ? "barFormatVertical" : "barFormat"
        var current = vertical ? root.barFormatVertical : root.barFormat
        var ring = Model.clockFormatRing(current, Model.clockFormats(vertical))
        pluginService?.savePluginData(root.pluginId, key, Model.nextClockFormat(ring, current))
    }

    function setHidePast(value) {
        pluginService?.savePluginData(root.pluginId, "hidePast", value === true)
    }

    function toggleWeekStart() {
        pluginService?.savePluginData(root.pluginId, "weekStart",
            Model.weekStartSettingName(Model.toggledWeekStart(root.weekStart)))
    }

    // Qt kennt kein ISO-Wochen-Token. Das Format an "ww" zerlegen, die Stuecke
    // einzeln formatieren und die Wochennummer dazwischensetzen -- das Token
    // nachtraeglich im fertigen Text zu ersetzen waere nicht eindeutig.
    function formatMoment(date, fmt) {
        var parts = String(fmt).split("ww")
        if (parts.length === 1)
            return date.toLocaleString(root.loc, fmt)
        var week = Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())
        var out = ""
        for (var i = 0; i < parts.length; i++) {
            out += (parts[i] === "" ? "" : date.toLocaleString(root.loc, parts[i]))
            if (i < parts.length - 1)
                out += week
        }
        return out
    }

    function dateFromKey(key) {
        var p = String(key).split("-")
        return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
    }

    function openUrl(url) {
        if (!Model.isOpenableUrl(url))
            return
        Quickshell.execDetached(["xdg-open", String(url)])
    }

    function openInCalendarApp() {
        Quickshell.execDetached(["dcal", "show"])
    }

    // ------------------------------------------------------------- Pillen

    readonly property string pillText: root.formatMoment(root.now, root.barFormat)
    readonly property string nextText: {
        if (!root.showNextEvent || !root.upcoming)
            return ""
        return Model.timeLabel(root.upcoming, root.use24Hour) + " " + String(root.upcoming.title || "")
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.pillText
                color: Theme.widgetTextColor
                font.pixelSize: root.barTextPx
            }

            // Trenner und naechster Termin nur, wenn es einen gibt -- eine
            // leere Pille soll nicht breiter aussehen als sie ist.
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.nextText !== ""
                text: "·"
                color: Theme.widgetTextColor
                opacity: 0.5
                font.pixelSize: root.barTextPx
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.nextText !== ""
                text: root.nextText
                color: Theme.widgetTextColor
                opacity: 0.8
                font.pixelSize: root.barTextPx
                elide: Text.ElideRight
                maximumLineCount: 1
                width: Math.min(implicitWidth, 220)
            }
        }
    }

    verticalBarPill: Component {
        StyledText {
            text: root.formatMoment(root.now, root.barFormatVertical)
            color: Theme.widgetTextColor
            font.pixelSize: root.barTextPx
            horizontalAlignment: Text.AlignHCenter
            lineHeight: 0.95
        }
    }

    pillRightClickAction: () => root.cycleFormat()

    // ---------------------------------------------------------- Bausteine
    //
    // Inline-Komponenten gehoeren in das Wurzelobjekt der Datei, nicht in ein
    // verschachteltes Component -- dort werden sie klaglos ignoriert, und das
    // Popout bleibt an der Stelle leer, ohne dass irgendwo eine Warnung
    // auftaucht. Gewoehnliche Eigenschaften statt required: die Delegaten
    // setzen sie.

    // Alles im Popout ist Monospace. Das ist der groesste einzelne Unterschied
    // zum DMS-Standardaussehen und der Grund, warum die Spalten ueberhaupt
    // ausgerichtet wirken.
    component Mono: StyledText {
        isMonospace: true
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeSmall + 1
    }

    // Abschnittsueberschrift im Detailpanel: klein, gesperrt, in Versalien.
    component SectionLabel: StyledText {
        isMonospace: true
        topPadding: Theme.spacingXS
        font.pixelSize: Theme.fontSizeSmall - 2
        font.weight: Font.DemiBold
        font.letterSpacing: 1.4
        color: Theme.surfaceVariantText
        opacity: 0.85
    }

    // Eine Zelle des Monatsrasters.
    component DayCell: Item {
        id: cell
        property var day: null

        readonly property var dayEvents: cell.day ? root.eventsFor(cell.day.key) : []
        readonly property bool selected: cell.day && cell.day.key === root.selectedKey
        readonly property bool isToday: cell.day && cell.day.today === true

        width: root.cellW
        height: root.cellH

        // Ausgewaehlt ist gefuellt, heute ist umrandet -- beides kann
        // zugleich gelten, darum zwei Eigenschaften an einem Rechteck.
        Rectangle {
            anchors.centerIn: parent
            width: root.cellW - 10
            height: root.cellH - 12
            radius: 3
            color: cell.selected ? Theme.withAlpha(Theme.surfaceText, 0.10)
                 : cellArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.05)
                 : "transparent"
            border.width: cell.isToday ? 1 : 0
            border.color: Theme.withAlpha(Theme.surfaceText, 0.40)
        }

        Mono {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 9
            text: cell.day ? String(cell.day.day) : ""
            font.pixelSize: Theme.fontSizeLarge
            color: (cell.day && cell.day.inMonth) ? Theme.surfaceText
                 : Theme.withAlpha(Theme.surfaceVariantText, 0.45)
        }

        // Ein Punkt je beteiligtem Kalender in dessen Farbe, bis zu vier.
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 32
            spacing: 3

            Repeater {
                model: Model.dotColors(cell.dayEvents, 4)
                delegate: Rectangle {
                    required property string modelData
                    width: 5
                    height: 5
                    radius: 2.5
                    color: modelData
                    opacity: (cell.day && cell.day.inMonth) ? 1.0 : 0.45
                }
            }

            Rectangle {
                visible: Model.hasMoreThanDots(cell.dayEvents, 4)
                width: 5
                height: 5
                radius: 2.5
                color: Theme.surfaceVariantText
                opacity: (cell.day && cell.day.inMonth) ? 0.5 : 0.25
            }
        }

        MouseArea {
            id: cellArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (cell.day) root.selectDay(cell.day.key)
        }
    }

    // Eine Zeile der Tagesagenda. "rowIndex" statt "index": der Delegat
    // bekommt index von Repeater und haette die Eigenschaft sonst doppelt.
    component AgendaRow: Column {
        id: row
        property var event: null
        property int rowIndex: 0
        property real rowWidth: 0

        readonly property bool selected: row.event && String(row.event.id || "") === root.expandedId
        readonly property bool past: row.event ? Model.isPast(row.event, root.selectedKey, root.now) : false
        readonly property bool ongoing: row.event ? Model.isOngoing(row.event, root.selectedKey, root.now) : false
        readonly property string meeting: row.event ? Model.meetingUrlFor(row.event) : ""
        readonly property string place: row.event ? Model.locationLabel(row.event) : ""
        readonly property string calText: {
            if (!row.event)
                return ""
            var cal = String(row.event.calendar || "")
            var acc = String(row.event.account || "")
            return acc !== "" && acc !== cal ? cal + " · " + acc : cal
        }

        width: row.rowWidth
        spacing: 0

        // "Jetzt"-Linie vor dem ersten noch kommenden Termin.
        Item {
            width: parent.width
            height: visible ? 13 : 0
            visible: row.rowIndex === Model.nowMarkerIndex(root.selectedEvents, root.selectedKey, root.now)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.error
                opacity: 0.55
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: 5
                height: 5
                radius: 2.5
                color: Theme.error
            }
        }

        Item {
            width: parent.width
            height: body.implicitHeight + Theme.spacingS * 2

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: -Theme.spacingXS
                radius: 3
                color: row.selected ? Theme.withAlpha(Theme.surfaceText, 0.07)
                     : rowArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.04)
                     : "transparent"
            }

            // Farbstreifen des Herkunftskalenders ueber die ganze Zeilenhoehe.
            // Bei Vergangenem fast weg -- der ruhigste Weg, es
            // zurueckzunehmen, ohne es unlesbar zu machen.
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: 2
                anchors.bottomMargin: 2
                width: 3
                radius: 1.5
                color: row.event ? String(row.event.color || Theme.primary) : Theme.primary
                opacity: row.past ? 0.3 : 1.0
            }

            Column {
                id: body
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Row {
                    width: parent.width
                    spacing: 0
                    // Ohne feste Hoehe zieht der Kamera-Knopf (26 px) die
                    // Zeile auseinander, und Termine mit Videokonferenz
                    // stehen luftiger als die anderen. Das Icon selbst ist
                    // kleiner als die Textzeile und passt hinein.
                    height: timeLbl.implicitHeight

                    Mono {
                        id: timeLbl
                        width: root.timeColW
                        text: {
                            if (!row.event)
                                return ""
                            if (row.event.allDay)
                                return "ganztägig"
                            return Model.timeLabel(row.event, root.use24Hour) + " – "
                                 + Model.endTimeLabel(row.event, root.use24Hour)
                        }
                        color: row.ongoing ? Theme.primary
                             : row.past ? Theme.withAlpha(Theme.surfaceVariantText, 0.55)
                             : Theme.surfaceVariantText
                        font.weight: row.ongoing ? Font.DemiBold : Font.Normal
                    }

                    Mono {
                        width: Math.max(0, parent.width - root.timeColW - (camBtn.visible ? 30 : 0))
                        text: row.event ? String(row.event.title || "") : ""
                        // Durchgestrichen statt nur blass: so bleibt lesbar,
                        // was war, ohne mit dem zu konkurrieren, was kommt.
                        font.strikeout: row.past
                        font.weight: row.ongoing ? Font.DemiBold : Font.Normal
                        color: row.past ? Theme.withAlpha(Theme.surfaceText, 0.5) : Theme.surfaceText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    DankActionButton {
                        id: camBtn
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Model.isOpenableUrl(row.meeting)
                        iconName: "videocam"
                        buttonSize: 26
                        iconSize: 15
                        tooltipText: Model.shortUrl(row.meeting)
                        onClicked: root.openUrl(row.meeting)
                    }
                }

                // Zweite Zeile, eingerueckt bis unter den Titel: Ort und
                // Herkunftskalender.
                Row {
                    x: root.timeColW
                    width: Math.max(0, parent.width - root.timeColW)
                    spacing: Theme.spacingXXS
                    visible: row.place !== "" || row.calText !== ""

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.place !== ""
                        name: "location_on"
                        size: 12
                        color: Theme.surfaceVariantText
                        opacity: row.past ? 0.45 : 0.75
                    }
                    Mono {
                        visible: row.place !== ""
                        text: row.place
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        opacity: row.past ? 0.45 : 0.85
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        width: Math.min(implicitWidth, 160)
                    }
                    Mono {
                        visible: row.place !== "" && row.calText !== ""
                        text: "·"
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        opacity: 0.45
                    }
                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.calText !== ""
                        name: "calendar_month"
                        size: 12
                        color: Theme.surfaceVariantText
                        opacity: row.past ? 0.45 : 0.75
                    }
                    Mono {
                        text: row.calText
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        opacity: row.past ? 0.45 : 0.8
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        // Was nach Ort und Trennpunkt uebrig bleibt. Ohne Ort
                        // ist das fast die ganze Zeile.
                        width: Math.min(implicitWidth, Math.max(60, parent.width - x - 16))
                    }
                }
            }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Der Kamera-Knopf liegt darueber und bekommt seine Klicks
                // selbst; hier nur das Auf- und Zuschlagen der Detailspalte.
                onClicked: root.expandedId = row.selected ? "" : String(row.event.id || "")
            }
        }
    }

    // ------------------------------------------------------------- Popout

    // Das Popout waechst nach rechts, wenn ein Termin aufgeschlagen ist --
    // wie beim Vorgaenger. Zu bleibt es genau so breit wie der Kalender.
    popoutWidth: root.popoutChrome
        + (root.detailEvent ? (root.calWidth + 1 + root.detailWidth) : root.calWidth)

    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Kein headerText und kein detailsText: die Kopfzeile von
            // PopoutComponent blendet sich dann aus, und die Ueberschrift
            // macht der Entwurf selbst.
            readonly property var weeks: Model.monthGrid(root.viewYear, root.viewMonth,
                root.weekStart, root.todayKey)

            // Beim Oeffnen auf heute zurueck und die Daten anstossen. Das
            // Popout wird nicht jedes Mal neu gebaut, darum reicht
            // Component.onCompleted allein nicht.
            Component.onCompleted: {
                root.goToToday()
                root.ensureRange()
            }

            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popout.parentPopout.shouldBeVisible) {
                        root.goToToday()
                        root.ensureRange()
                    }
                }
            }

            Row {
                width: parent.width
                spacing: 0

                // ---------------------------------------- Kalenderspalte
                Column {
                    id: calCol
                    width: root.calWidth
                    spacing: Theme.spacingS
                    topPadding: Theme.spacingS
                    bottomPadding: Theme.spacingM
                    leftPadding: root.panePad
                    rightPadding: root.panePad

                    readonly property real inner: root.calWidth - 2 * root.panePad

                    // Der feste Teil in einer eigenen Spalte: seine Hoehe laesst
                    // sich messen, ohne dass die Agenda darin vorkommt. Ohne
                    // diese Trennung waere die Rechnung unten ein Kreis.
                    Column {
                        id: calHead
                        width: calCol.inner
                        spacing: calCol.spacing

                        // Hinweis statt eines leeren Rasters, wenn gar kein
                        // Backend laeuft -- sonst sieht ein kaputter Daemon aus
                        // wie ein terminfreier Monat.
                        StyledRect {
                            width: calCol.inner
                            height: visible ? warn.implicitHeight + Theme.spacingS * 2 : 0
                            visible: !root.backendReady
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.error, 0.12)

                            Mono {
                                id: warn
                                anchors.centerIn: parent
                                width: parent.width - Theme.spacingM * 2
                                text: "Kein Kalender-Backend aktiv.\nLäuft dcal?\n  systemctl --user status dcal"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.error
                                wrapMode: Text.Wrap
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        // ---- Ueberschrift: der heutige Tag, gross.
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "calendar_month"
                                size: 26
                                color: Theme.surfaceText
                            }

                            Mono {
                                text: root.now.toLocaleString(root.loc,
                                    Model.dayMonthFormat(root.loc.dateFormat(Locale.LongFormat)))
                                font.pixelSize: Theme.fontSizeLarge + 14
                                font.weight: Font.Bold
                            }
                        }

                        // ---- Jahresbalken.
                        Item {
                            width: calCol.inner
                            height: visible ? 18 : 0
                            visible: root.showYearBar

                            Mono {
                                id: yearLabel
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: String(root.now.getFullYear())
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            Mono {
                                id: yearPct
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: Model.yearProgressPercent(root.now.getFullYear(),
                                    root.now.getMonth(), root.now.getDate()) + "%"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                horizontalAlignment: Text.AlignRight
                            }

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: yearLabel.right
                                anchors.right: yearPct.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                height: 7
                                radius: 3.5
                                color: Theme.withAlpha(Theme.surfaceText, 0.12)

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: parent.width * Model.yearProgress(root.now.getFullYear(),
                                        root.now.getMonth(), root.now.getDate())
                                    radius: parent.radius
                                    color: Theme.primary
                                }
                            }
                        }

                        Item {
                            width: 1
                            height: root.showYearBar ? Theme.spacingM : 0
                        }

                        // ---- Wochentagskoepfe, benannt von der Locale.
                        Row {
                            spacing: 0

                            Mono {
                                width: root.weekColW
                                text: "W"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.letterSpacing: 1.2
                                font.weight: Font.Bold
                                color: Theme.surfaceVariantText
                                opacity: 0.9
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Repeater {
                                model: Model.weekdayOrder(root.weekStart)
                                delegate: Mono {
                                    required property int modelData
                                    width: root.cellW
                                    text: root.loc.dayName(modelData, Locale.ShortFormat).toUpperCase()
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.letterSpacing: 1.2
                                    font.weight: Font.Bold
                                    color: Theme.surfaceVariantText
                                    opacity: 0.9
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }

                        // ---- Sechs feste Reihen: der Monatswechsel soll das
                        //      Popout nicht unter dem Zeiger springen lassen. Das
                        //      Item aussenrum traegt die Mausrad-Flaeche -- ein
                        //      MouseArea mit anchors.fill waere als Kind einer
                        //      Column nicht erlaubt.
                        Item {
                            width: root.gridW
                            height: 6 * root.cellH

                            // Senkrechte Trennlinie zwischen Wochenzahl und Tagen.
                            Rectangle {
                                x: root.weekColW - Theme.spacingS
                                y: 2
                                width: 1
                                height: parent.height - 4
                                color: Theme.withAlpha(Theme.surfaceText, 0.10)
                            }

                            Column {
                                anchors.fill: parent
                                spacing: 0

                                Repeater {
                                    model: popout.weeks
                                    delegate: Row {
                                        required property var modelData
                                        spacing: 0

                                        Mono {
                                            width: root.weekColW
                                            height: root.cellH
                                            text: Model.pad2(modelData.week)
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            opacity: 0.5
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }

                                        Repeater {
                                            model: modelData.days
                                            delegate: DayCell {
                                                required property var modelData
                                                day: modelData
                                            }
                                        }
                                    }
                                }
                            }

                            // Mausrad blaettert durch die Monate. Liegt unter den
                            // Zellen, damit deren Klicks weiter ankommen.
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.NoButton
                                z: -1
                                onWheel: wheel => {
                                    root.stepMonth(wheel.angleDelta.y > 0 ? -1 : 1)
                                    wheel.accepted = true
                                }
                            }
                        }

                        // ---- Monatsnavigation unter dem Gitter.
                        Item {
                            width: calCol.inner
                            height: 34

                            DankActionButton {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: "chevron_left"
                                buttonSize: 30
                                tooltipText: "Voriger Monat"
                                onClicked: root.stepMonth(-1)
                            }

                            Mono {
                                anchors.centerIn: parent
                                text: (new Date(root.viewYear, root.viewMonth, 1))
                                    .toLocaleString(root.loc, "MMMM yyyy").toUpperCase()
                                font.pixelSize: Theme.fontSizeMedium
                                font.letterSpacing: 2
                                color: Theme.surfaceText
                            }

                            // Doppelklick-Ziel gibt es nicht; wer zurueck zu heute
                            // will, klickt den Punkt in der Mitte.
                            MouseArea {
                                anchors.centerIn: parent
                                width: 200
                                height: parent.height
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.goToToday()
                            }

                            DankActionButton {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: "chevron_right"
                                buttonSize: 30
                                tooltipText: "Nächster Monat"
                                onClicked: root.stepMonth(1)
                            }
                        }

                        Rectangle {
                            width: calCol.inner
                            height: 1
                            color: Theme.withAlpha(Theme.surfaceText, 0.10)
                        }

                        // ---- Agenda-Kopf: Tag, Zahlen, Auge.
                        Item {
                            width: calCol.inner
                            height: 26

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                Mono {
                                    text: root.dateFromKey(root.selectedKey).toLocaleString(root.loc,
                                        Model.weekdayDayMonthFormat(root.loc.dateFormat(Locale.LongFormat)))
                                    font.pixelSize: Theme.fontSizeMedium
                                }

                                Mono {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.selectedEvents.length === 1 ? "1 Termin"
                                        : root.selectedEvents.length + " Termine"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                Mono {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: root.hiddenCount > 0
                                    text: root.hiddenCount + " ausgeblendet"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.italic: true
                                    color: Theme.surfaceVariantText
                                    opacity: 0.8
                                }
                            }

                            DankActionButton {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: root.hidePast ? "visibility_off" : "visibility"
                                buttonSize: 26
                                tooltipText: root.hidePast ? "Vergangene Termine einblenden"
                                                           : "Vergangene Termine ausblenden"
                                onClicked: root.setHidePast(!root.hidePast)
                            }
                        }
                    }

                    // ---- Die Agenda selbst. Feste Hoehe, damit das Popout
                    //      nicht bei jedem Tagwechsel eine andere Groesse hat.
                    DankFlickable {
                        width: calCol.inner
                        // So hoch wie noetig, hoechstens so hoch wie der
                        // Bildschirm zulaesst -- erst dann wird gescrollt.
                        height: Math.max(84, Math.min(agenda.implicitHeight + 4,
                            root.screenAvail - calHead.height - calCol.topPadding
                            - calCol.bottomPadding - calCol.spacing))
                        contentHeight: agenda.implicitHeight
                        clip: true

                        Column {
                            id: agenda
                            width: parent.width
                            spacing: 2

                            Mono {
                                visible: root.selectedEvents.length === 0
                                width: parent.width
                                topPadding: Theme.spacingL
                                text: root.hiddenCount > 0 ? "Nur noch vergangene Termine"
                                                           : "Keine Termine"
                                color: Theme.surfaceVariantText
                                opacity: 0.7
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Repeater {
                                model: root.selectedEvents
                                delegate: AgendaRow {
                                    required property var modelData
                                    required property int index
                                    event: modelData
                                    rowIndex: index
                                    rowWidth: agenda.width
                                }
                            }
                        }
                    }
                }

                // ---------------------------------------- Trennlinie
                Rectangle {
                    width: 1
                    height: calCol.height
                    visible: root.detailEvent !== null
                    color: Theme.withAlpha(Theme.surfaceText, 0.10)
                }

                // ---------------------------------------- Detailspalte
                Column {
                    id: detailCol
                    width: root.detailEvent ? root.detailWidth : 0
                    height: calCol.height
                    visible: root.detailEvent !== null
                    clip: true
                    topPadding: Theme.spacingM
                    bottomPadding: Theme.spacingM
                    leftPadding: root.panePad
                    rightPadding: root.panePad
                    spacing: Theme.spacingS

                    readonly property var ev: root.detailEvent
                    readonly property real inner: root.detailWidth - 2 * root.panePad
                    readonly property string meeting: detailCol.ev ? Model.meetingUrlFor(detailCol.ev) : ""

                    // ---- Kopf: Beschriftung, in dcal oeffnen, schliessen.
                    Item {
                        width: detailCol.inner
                        height: 28

                        SectionLabel {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "TERMIN"
                        }

                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXXS

                            DankActionButton {
                                iconName: "open_in_new"
                                buttonSize: 26
                                iconSize: 15
                                tooltipText: "Im Kalender öffnen"
                                onClicked: root.openInCalendarApp()
                            }
                            DankActionButton {
                                iconName: "close"
                                buttonSize: 26
                                iconSize: 15
                                tooltipText: "Schließen"
                                onClicked: root.expandedId = ""
                            }
                        }
                    }

                    Mono {
                        width: detailCol.inner
                        text: detailCol.ev ? String(detailCol.ev.title || "") : ""
                        font.pixelSize: Theme.fontSizeLarge + 1
                        font.weight: Font.DemiBold
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }

                    Mono {
                        width: detailCol.inner
                        text: {
                            if (!detailCol.ev)
                                return ""
                            var d = root.dateFromKey(root.selectedKey).toLocaleString(root.loc,
                                Model.weekdayDayMonthFormat(root.loc.dateFormat(Locale.LongFormat)))
                            if (detailCol.ev.allDay)
                                return d + "  ·  ganztägig"
                            return d + "  ·  " + Model.timeLabel(detailCol.ev, root.use24Hour)
                                 + " – " + Model.endTimeLabel(detailCol.ev, root.use24Hour)
                                 + (detailCol.ev.isMultiDay ? "  (mehrtägig)" : "")
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.Wrap
                    }

                    // dcal liefert ueber events.list nur ein recurringId,
                    // keine RRULE -- mehr als "Serientermin" ist daraus nicht
                    // zu machen. Der Vorgaenger schrieb hier die Regel aus.
                    Row {
                        spacing: Theme.spacingXS
                        visible: detailCol.ev && String(detailCol.ev.recurringId || "") !== ""

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "repeat"
                            size: 13
                            color: Theme.surfaceVariantText
                        }
                        Mono {
                            text: "Serientermin"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    // ---- Beitreten.
                    StyledRect {
                        // So breit wie sein Inhalt. Ueber die ganze Spalte
                        // gezogen wirkte der Knopf schwerer als die Sache ist.
                        width: joinRow.implicitWidth + Theme.spacingL * 2
                        height: visible ? 34 : 0
                        visible: Model.isOpenableUrl(detailCol.meeting)
                        radius: Theme.cornerRadius
                        color: joinArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.14)
                                                      : Theme.withAlpha(Theme.surfaceText, 0.08)

                        Row {
                            id: joinRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "videocam"
                                size: 16
                                color: Theme.surfaceText
                            }
                            Mono {
                                text: "Beitreten"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.DemiBold
                            }
                        }

                        MouseArea {
                            id: joinArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openUrl(detailCol.meeting)
                        }
                    }

                    // ---- Alles Weitere scrollt, damit lange Gaestelisten
                    //      und Einladungstexte die Spalte nicht sprengen.
                    DankFlickable {
                        width: detailCol.inner
                        height: Math.max(0, calCol.height - detailCol.topPadding
                                - detailCol.bottomPadding - rest.y)
                        contentHeight: rest.implicitHeight
                        clip: true

                        Column {
                            id: rest
                            width: parent.width
                            spacing: Theme.spacingXS

                            // Ist der Ort nichts als der Konferenzlink, zeigt
                            // schon der Beitreten-Knopf darauf -- dann bleibt
                            // der Abschnitt weg, statt die URL zu wiederholen.
                            readonly property string placeText: {
                                if (!detailCol.ev)
                                    return ""
                                var text = Model.collapseSpace(detailCol.ev.location || "")
                                if (text === "")
                                    return ""
                                return (detailCol.meeting !== "" && text.indexOf(detailCol.meeting) === 0)
                                    ? "" : text
                            }

                            SectionLabel {
                                text: "ORT"
                                visible: rest.placeText !== ""
                            }
                            Mono {
                                width: parent.width
                                visible: rest.placeText !== ""
                                text: rest.placeText
                                font.pixelSize: Theme.fontSizeSmall
                                wrapMode: Text.Wrap
                                bottomPadding: Theme.spacingXS
                            }

                            SectionLabel { text: "KALENDER" }
                            Row {
                                spacing: Theme.spacingXS
                                bottomPadding: Theme.spacingXS

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 7
                                    height: 7
                                    radius: 3.5
                                    color: detailCol.ev ? String(detailCol.ev.color || Theme.primary)
                                                        : Theme.primary
                                }
                                Mono {
                                    text: {
                                        if (!detailCol.ev)
                                            return ""
                                        var cal = String(detailCol.ev.calendar || "")
                                        var acc = String(detailCol.ev.account || "")
                                        return acc !== "" && acc !== cal ? cal + "  ·  " + acc : cal
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    width: Math.min(implicitWidth, rest.width - 20)
                                    elide: Text.ElideRight
                                }
                            }

                            SectionLabel {
                                text: "ORGANISATOR"
                                visible: detailCol.ev && detailCol.ev.organizer
                            }
                            Mono {
                                visible: detailCol.ev && detailCol.ev.organizer
                                text: (detailCol.ev && detailCol.ev.organizer)
                                    ? Model.attendeeName(detailCol.ev.organizer) : ""
                                font.pixelSize: Theme.fontSizeSmall
                                bottomPadding: Theme.spacingXS
                                width: parent.width
                                elide: Text.ElideRight
                            }

                            SectionLabel {
                                visible: detailCol.ev && (detailCol.ev.attendees || []).length > 0
                                text: {
                                    if (!detailCol.ev)
                                        return ""
                                    var s = Model.attendeeSummary(detailCol.ev.attendees)
                                    return "TEILNEHMER (" + s.total + ")  ·  " + s.accepted + " ZUGESAGT"
                                }
                            }

                            Repeater {
                                model: detailCol.ev ? (detailCol.ev.attendees || []) : []
                                delegate: Row {
                                    required property var modelData
                                    spacing: Theme.spacingXS

                                    DankIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: Model.attendeeIcon(modelData.status)
                                        size: 13
                                        color: String(modelData.status || "").toLowerCase() === "declined"
                                             ? Theme.error : Theme.surfaceVariantText
                                    }
                                    Mono {
                                        text: Model.attendeeName(modelData)
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: String(modelData.status || "").toLowerCase() === "declined"
                                             ? Theme.withAlpha(Theme.surfaceText, 0.55) : Theme.surfaceText
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        width: Math.min(implicitWidth, rest.width - 24)
                                    }
                                }
                            }

                            SectionLabel {
                                topPadding: Theme.spacingS
                                visible: detailCol.ev
                                    && Model.collapseSpace(detailCol.ev.description || "") !== ""
                                text: "EINLADUNG"
                            }

                            // Markierbar, weil dort die Einwahlnummern und
                            // Meeting-IDs stehen, die man herauskopieren will
                            // -- ein StyledText koennte das nicht.
                            TextEdit {
                                width: parent.width
                                visible: detailCol.ev
                                    && Model.collapseSpace(detailCol.ev.description || "") !== ""
                                text: detailCol.ev ? Model.trimSeparators(detailCol.ev.description || "") : ""
                                readOnly: true
                                selectByMouse: true
                                wrapMode: TextEdit.Wrap
                                textFormat: TextEdit.PlainText
                                font.family: Theme.monoFontFamily
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- IPC

    // Steuerung von aussen, etwa aus niri/config.kdl:
    //   dms ipc call calendar toggle|today|refresh|cycleFormat|status
    // Wie bei den anderen Plugins ein nackter IpcHandler. Zwei Fallen: jede
    // Bar instanziiert das Widget, bei mehreren Monitoren antwortet die zuerst
    // registrierte Instanz; und nach "dms ipc call plugins reload" haengt das
    // Target an der alten Instanz (quickshell#898) -- dann hilft nur ein
    // Neustart der Shell.
    IpcHandler {
        target: "calendar"

        function toggle(): string {
            root.triggerPopout()
            return "ok"
        }
        function today(): string {
            root.goToToday()
            return root.todayKey
        }
        function refresh(): string {
            root.ensureRange()
            return "ok"
        }
        function cycleFormat(): string {
            root.cycleFormat()
            return root.barFormat
        }
        function weekStart(): string {
            root.toggleWeekStart()
            return Model.weekStartSettingName(root.weekStart)
        }
        function status(): string {
            if (!root.backendReady)
                return "kein Backend"
            var n = root.eventsFor(root.todayKey).length
            return CalendarService.activeBackend + ", heute " + n + " Termine"
        }
        function next(): string {
            var e = root.upcoming
            if (!e)
                return "nichts in den naechsten " + root.nextEventHorizon + " h"
            return Model.timeLabel(e, root.use24Hour) + " " + String(e.title || "")
        }
    }
}
