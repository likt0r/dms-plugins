# VPN Hub

Ein Bar-Icon für alle VPN-Verbindungen in DankMaterialShell: NetworkManager-
Profile (WireGuard, OpenVPN, …) und Proton VPN über die offizielle CLI. Das
Popout zeigt, was gerade verbunden ist, den Traffic des Tunnels, alle
Verbindungen mit Schalter, zuletzt benutzte und favorisierte Proton-Ziele und
eine Länderauswahl.

Herkunft: Port des Omarchy-Plugins [likt0r.vpn](https://github.com/likt0r/omarchy-vpn)
(ein Icon je Verbindung), erweitert um Proton VPN. Aufbau und Bedienung des
Popouts folgen [proton.omarchy](https://github.com/48hoursnonstop/proton-vpn-omarchy)
— nur als Vorbild, ohne Code daraus (GPL-3.0; dessen Rust-Backend gibt es nur
als Arch-Paket). Die Zuordnung Omarchy→DMS steht in `docs/omarchy-to-dms.md`
im dotfiles-Repo.

## Installation

`bin/apply` (dotfiles) verlinkt das Verzeichnis nach
`~/.config/DankMaterialShell/plugins/vpn`. Danach:

```sh
dms ipc call plugins scan
dms ipc call plugins enable vpnHub
```

und unter Leiste → Widgets **„VPN Hub“** platzieren.

**Die Plugin-Id ist `vpnHub`, nicht `vpn`.** `vpn` ist in DMS fest an das
eingebaute VPN-Widget vergeben: Ein Plugin mit dieser Id lädt zwar, in der Bar
erscheint unter `"vpn"` aber immer das eingebaute Widget.

### Proton VPN

```sh
sudo dnf install proton-vpn-cli          # aus dem Proton-Repo (protonvpn-stable-release)
protonvpn signin <benutzer>              # einmalig, interaktiv
```

Die Proton-VPN-App (Flatpak oder RPM) darf dabei nicht laufen. Läuft sie,
verweigert sich die CLI, und das Widget meldet das als Toast.

## Bedienung

| Aktion | Wirkung |
|---|---|
| Linksklick aufs Icon | Popout |
| Rechtsklick | VPN-Panel von DMS (Profile importieren, Details) |
| großer Knopf im Popout | trennt die angezeigte Verbindung, sonst Proton zum Standardziel |
| Schalter je Verbindung | an/aus |
| Länder: Zeile | schnellster Server im Land (mit dem gewählten Filter) |
| Länder: Pfeil | Städte aufklappen; Klick auf eine Stadt verbindet dorthin |
| Stern | Ziel als Favorit merken (erscheint unter „Zuletzt & Favoriten“) |

Das Icon ist `vpn_lock` in der Primärfarbe, sobald irgendeine VPN-Verbindung
steht, sonst `vpn_key_off`. Während des Umschaltens ist es halb transparent.

Von außen, etwa per Keybind in `niri/config.kdl`:

```sh
dms ipc call vpnHub openPopout
dms ipc call vpnHub toggle wg_config        # NM-Profil (Name oder Anzeigename)
dms ipc call vpnHub toggle proton           # Proton an/aus, Standardziel
dms ipc call vpnHub connectTo CH            # Proton: "", "CH", "CH#42", "Zurich"
dms ipc call vpnHub disconnectProton
dms ipc call vpnHub status
```

Nicht `connect`/`disconnect`: Diese Namen hat jedes QObject schon, und ein
`IpcHandler` mit solchen Funktionen wird nicht registriert.

## Einstellungen

Einstellungen → Plugins → VPN Hub:

| Einstellung | Schlüssel | Bedeutung |
|---|---|---|
| Proton VPN einbinden | `protonEnabled` | Reiter „Länder“, Proton-Zeile, Zuletzt/Favoriten |
| Standardziel | `protonTarget` | leer = schnellster Server, `DE`, `DE#12` oder eine Stadt |
| Verbindung in der Bar nennen | `showLabel` | Text neben dem Icon (bei Proton das Land) |
| je NM-Profil: im Popout zeigen, Anzeigename, eigener Befehl | `connections` | Objekt, Schlüssel = Profilname |

Verbindungen werden nicht im Widget angelegt. Das Popout zeigt jedes
VPN-Profil, das NetworkManager kennt; neue importiert man über das DMS-Panel
(Rechtsklick). Zuletzt benutzte Ziele und Favoriten liegen im Plugin-State
(`~/.local/state/DankMaterialShell/plugins/vpnHub_state.json`).

### Eigener Umschaltbefehl

Ist für ein Profil ein Befehl eingetragen, ruft das Widget ihn **ohne
Argumente** auf, statt selbst zu schalten. Er entscheidet selbst, ob verbunden
oder getrennt wird. Absoluter Pfad, denn er läuft ohne Shell.

Gedacht für alles, was NetworkManager nicht weiß. Beispiel WireGuard ins
eigene Heimnetz:

* **Zuhause ist der Tunnel sinnlos.** Der Endpoint ist die öffentliche Adresse
  des eigenen Anschlusses, und die meisten Router leiten sie von innen nicht
  zurück (kein NAT-Loopback). Der Verbindungsversuch scheitert dann ohne
  Fehlermeldung.
* **Ein bestehendes Interface ist kein bestehender Tunnel.** NetworkManager
  meldet „aktiviert“, sobald das Interface steht. Ob je ein Handshake zustande
  kam, steht erst in `rx_bytes`.

```sh
#!/usr/bin/env bash
set -uo pipefail

PROFIL="mein-vpn"
IFNAME="wg-mein"
LAN="192.168.0."          # Präfix des Netzes am anderen Ende

aktiv()   { nmcli -t -f NAME connection show --active | grep -qx "$PROFIL"; }
zuhause() { ip -4 -brief addr show | grep -v "^${IFNAME}" | grep -q " ${LAN}"; }
rx()      { cat "/sys/class/net/${IFNAME}/statistics/rx_bytes" 2>/dev/null || echo 0; }

if aktiv; then
  nmcli connection down "$PROFIL" && notify-send "VPN getrennt"
  exit 0
fi

if zuhause; then
  notify-send "Schon im Zielnetz" "Tunnel nicht nötig."
  exit 0
fi

nmcli connection up "$PROFIL" || { notify-send -u critical "Verbinden fehlgeschlagen"; exit 1; }

for _ in $(seq 1 10); do
  [[ "$(rx)" -gt 0 ]] && { notify-send "VPN verbunden"; exit 0; }
  sleep 1
done
notify-send -u critical "Kein Handshake" "Interface steht, Gegenseite antwortet nicht."
```

## Wie es funktioniert

**Zustand ohne Polling.** Alles kommt aus `DMSNetworkService.vpnActive`; das
DMS-Backend schiebt Änderungen von NetworkManager. Auch Proton erscheint dort:
Die CLI legt beim Verbinden eine NM-Verbindung `ProtonVPN <Server>` an und
räumt sie beim Trennen ab. Proton wird daran erkannt (oder am Gerät `proton0`).

**Schalten.** NM-Profile über DMS, per UUID (DMS löst seine Busy-Markierung erst,
wenn die gemerkte UUID aktiv wird; mit einem Namen hinge sie bis zum Timeout).
Fehler meldet DMS als Toast, Passwörter fragt DMS ab. Proton über
`protonvpn connect|disconnect`. Deren Fehler stehen als `Error: …` in der
Ausgabe (Exit 2). Läuft die Proton-App, verweigert die CLI mit Exit 0. Deshalb
liest das Widget die Ausgabe und verlässt sich nicht auf den Exit-Code.

**Standorte.** Die Proton-Bibliothek speichert die Serverliste unter
`~/.cache/Proton/VPN/serverlist.json` (rund 20 MB, über 17 000 Server).
`bin/proton-locations` fasst sie je Land und Stadt zusammen: Server online,
mittlere Last, Secure Core/P2P/Tor. Die Ländernamen kommen auf Deutsch aus
`iso-codes`. Das Ergebnis (~30 KB) wird in `~/.cache/dms/vpn-proton-locations.json`
gecacht und nur neu gebaut, wenn sich die Serverliste ändert. Ins Netz geht der
Helfer nicht: Die Liste aktualisiert die CLI selbst bei `connect`. Flaggen sind
Emoji (Noto Color Emoji); Protons „UK“ wird dafür zu „GB“.

**Traffic.** Alle 2 s die Zähler aus `/sys/class/net/<if>/statistics`, die
letzten 5 Minuten als Graph (Download durchgezogen, Upload gestrichelt). Das
Interface wird über die Tunnel-IP gesucht: Bei OpenVPN meldet NetworkManager
als Gerät das darunterliegende (`wlp2s0`), der Tunnel heißt `tun0`.

Gegenüber dem Omarchy-Original weggefallen: der Tooltip (DMS-Pills haben
keinen), der Mittelklick (gibt es in `PluginComponent` nicht), `Lock.js` (unter
DMS antwortet nur eine Instanz auf IPC) und das Polling per `nmcli`. Aus der
Vorlage proton.omarchy bewusst nicht übernommen: Gateways, Profile,
Split-Tunneling, Konto-, Support- und Diagnoseseiten, der Backend-Installer.

## Aufbau

```
plugin.json          Manifest (id vpnHub, Settings, Berechtigungen)
VpnWidget.qml        Bar-Pill, Popout (Übersicht, Länder), Schalten, Traffic, IPC
Settings.qml         Proton, Anzeige, Einstellungen je NM-Profil
Model.js             alles Reine: Zustand, Zeilen, Proton-Ziele, CLI-Fehler, Traffic
bin/proton-locations Serverliste → Länder/Städte (Python, nur Standardbibliothek)
tests/               node --test (ruft auch den Helfer mit einer Test-Serverliste auf)
```

## Tests

```sh
node --test tests/model.test.js
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
