import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "superProductivity"

    SelectionSetting {
        settingKey: "barCount"
        label: "Zahl in der Bar"
        description: "Welche offenen Tasks die Pille zaehlt"
        options: [
            { label: "Heute (faellig + ueberfaellig)", value: "today" },
            { label: "Alle offenen", value: "all" },
            { label: "Keine Zahl", value: "none" }
        ]
        defaultValue: "today"
    }

    ToggleSetting {
        settingKey: "showCurrentInBar"
        label: "Laufenden Task in der Bar"
        description: "Zeigt neben der Zahl den Task, auf dem gerade Zeit erfasst wird"
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "startFilter"
        label: "Ansicht beim Start"
        description: "Mit welchem Filter das Panel nach dem Laden der Shell aufgeht"
        options: [
            { label: "Heute", value: "today" },
            { label: "Alle", value: "all" }
        ]
        defaultValue: "today"
    }

    StringSetting {
        settingKey: "defaultProject"
        label: "Projekt fuer neue Tasks"
        description: "Name oder ID des Projekts, in dem Tasks unter Heute und Alle landen; leer heisst Inbox"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "slideEdge"
        label: "Panel-Seite"
        description: "Von welcher Bildschirmkante das Panel hereinklappt"
        options: [
            { label: "Rechts", value: "right" },
            { label: "Links", value: "left" }
        ]
        defaultValue: "right"
    }

    SliderSetting {
        settingKey: "panelWidth"
        label: "Panel-Breite"
        defaultValue: 420
        minimum: 320
        maximum: 720
        unit: "px"
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: "Abgleich im Hintergrund"
        description: "Wie oft die Zahl in der Bar nachgezogen wird, solange das Panel zu ist; offen sind es 10 s"
        defaultValue: 60
        minimum: 15
        maximum: 600
        unit: "s"
    }

    StringSetting {
        settingKey: "launchCommand"
        label: "Startbefehl"
        description: "Womit der Knopf im Panel Super Productivity startet oder nach vorn holt"
        defaultValue: "flatpak run com.super_productivity.SuperProductivity"
    }
}
