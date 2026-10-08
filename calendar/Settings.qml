import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "calendar"

    ToggleSetting {
        settingKey: "showNextEvent"
        label: "Naechsten Termin in der Bar"
        description: "Zeigt hinter der Uhrzeit den naechsten Termin mit Uhrzeit; ganztaegige bleiben aussen vor"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "nextEventHorizon"
        label: "Vorschau"
        description: "Wie weit der naechste Termin voraus liegen darf, damit er in der Bar erscheint"
        defaultValue: 8
        minimum: 1
        maximum: 48
        unit: "h"
    }

    ToggleSetting {
        settingKey: "showYearBar"
        label: "Jahresbalken"
        description: "Zeigt ueber dem Monatsraster, wie weit das Jahr fortgeschritten ist"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "hidePast"
        label: "Vergangene Termine ausblenden"
        description: "Blendet abgelaufene Termine aus der Tagesagenda aus, statt sie nur abzublenden; entspricht dem Auge im Popout"
        defaultValue: false
    }

    StringSetting {
        settingKey: "barFormat"
        label: "Format in der Bar"
        description: "Qt-Datumsformat fuer waagerechte Bars; Rechtsklick auf die Pille schaltet durch die Vorlagen. 'ww' setzt die ISO-Kalenderwoche ein"
        defaultValue: "ddd dd.MM. HH:mm"
    }

    StringSetting {
        settingKey: "barFormatVertical"
        label: "Format in senkrechter Bar"
        description: "Dasselbe fuer links oder rechts angeschlagene Bars; Zeilenumbrueche sind erlaubt"
        defaultValue: "HH\n—\nmm"
    }

    StringSetting {
        settingKey: "weekStart"
        label: "Wochenbeginn"
        description: "monday oder sunday; leer laesst die Sprache des Systems entscheiden"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "locale"
        label: "Sprache der Datumsangaben"
        description: "Etwa de_DE oder en_US; leer nimmt die des Systems"
        defaultValue: ""
    }
}
