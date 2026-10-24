import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "reminder"

    SelectionSetting {
        settingKey: "bareUnit"
        label: "Zahl ohne Einheit"
        description: "Wie eine reine Zahl im Timer-HUD zählt, z. B. 25. Mit Einheit (3h30m4s, 90m, 45s) oder als Uhrzeit (14:30) gilt immer das Geschriebene"
        options: [
            { label: "Minuten", value: "m" },
            { label: "Stunden", value: "h" },
            { label: "Sekunden", value: "s" }
        ]
        defaultValue: "m"
    }

    StringSetting {
        settingKey: "presets"
        label: "Vorgaben"
        description: "Kacheln unter dem Zeitfeld, mit ←/→ wählbar; durch Komma getrennt, z. B. 5m, 25m, 1h30m. Reine Zahlen zählen in der Einheit oben"
        placeholder: "5m, 10m, 15m, 25m, 45m, 1h"
        defaultValue: "5m, 10m, 15m, 25m, 45m, 1h"
    }

    ToggleSetting {
        settingKey: "showCountdown"
        label: "Restzeit in der Toggle-Leiste"
        description: "Zeigt neben dem Timer-Icon die Restzeit des nächsten Timers; aus: nur das Icon"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "playSound"
        label: "Ton beim Ablauf"
        description: "Spielt den Weckerton des Systems (alarm-clock-elapsed); gilt für neu gestellte Timer"
        defaultValue: true
    }
}
