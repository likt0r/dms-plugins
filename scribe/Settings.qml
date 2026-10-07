import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Die komfortable Oberflaeche fuer dieselben Schluessel liegt in der Karte des
// Widgets (Bar-Icon -> Einstellungen); dies hier ist die Settings-Seite von
// DMS, damit das Plugin auch dort konfigurierbar bleibt.
PluginSettings {
    pluginId: "scribe"

    StringSetting {
        settingKey: "backend"
        label: "Backend"
        description: "Name eines Programms in ~/.config/dms/scribe/backends/ oder im backends/-Verzeichnis des Plugins (anthropic, claude-cli, openai)"
        defaultValue: "anthropic"
    }

    StringSetting {
        settingKey: "model"
        label: "Modell"
        description: "Wird dem Backend woertlich durchgereicht"
        defaultValue: "claude-opus-5"
    }

    StringSetting {
        settingKey: "endpoint"
        label: "Endpoint"
        description: "Nur fuers openai-Backend: OpenAI-kompatible Basis-URL, z.B. http://gpu-box.local:11434/v1 fuer ollama; leer heisst api.openai.com"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "effort"
        label: "Effort"
        description: "Leer laesst das Backend entscheiden; anthropic: low/medium/high/xhigh/max, openai/ollama: reasoning_effort (\"none\" schaltet das Nachdenken ab)"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "timeoutSec"
        label: "Timeout"
        defaultValue: 30
        minimum: 5
        maximum: 300
        unit: "s"
    }

    ToggleSetting {
        settingKey: "clipboardFallback"
        label: "Auf die Zwischenablage ausweichen"
        description: "Ist nichts markiert, wird korrigiert, was in der Zwischenablage liegt"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notify"
        label: "Benachrichtigen, wenn fertig"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "historyEnabled"
        label: "History fuehren"
        description: "Aus schreibt gar nichts auf die Platte"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "historyStoreText"
        label: "Text in der History speichern"
        description: "Aus haelt nur Zeitpunkt, Modell und Laenge fest — kein korrigierter Text auf der Platte"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "historyLimit"
        label: "History-Eintraege"
        defaultValue: 50
        minimum: 0
        maximum: 500
    }
}
