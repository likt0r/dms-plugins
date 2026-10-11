import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "reminder"

    ToggleSetting {
        settingKey: "showCountdown"
        label: "Countdown in der Bar"
        description: "Zeigt neben dem Wecker die Restzeit der nächsten Erinnerung"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "playSound"
        label: "Ton bei Fälligkeit"
        description: "Spielt beim Auslösen den Weckerton des Systems (alarm-clock-elapsed); gilt für neu gestellte Erinnerungen"
        defaultValue: true
    }

    StringSetting {
        settingKey: "quickTimes"
        label: "Schnellwahl"
        description: "Minuten für die Knöpfe unter dem Zeitfeld, durch Komma getrennt"
        placeholder: "5, 10, 15, 30, 60"
        defaultValue: "5, 10, 15, 30, 60"
    }
}
