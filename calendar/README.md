# Kalender

Datum und Uhrzeit in der DankMaterialShell-Bar. Ein Klick klappt ein
Monatsraster mit Terminpunkten, die Tagesagenda und auf Wunsch die Details
eines Termins auf.

Nachfolger von [likt0r.calendar](https://github.com/likt0r/omarchy-calendar)
aus Omarchy. Der groesste Unterschied steckt nicht in der Oberflaeche, sondern
darunter: Dort las ein Python-Exporter Thunderbirds SQLite-Cache aus, hier
kommen die Termine von **DankCalendar** (`dcal`) ueber den `CalendarService`
von DMS.

## Was es zeigt

**In der Bar** Datum und Uhrzeit im eingestellten Format, auf Wunsch dahinter
den naechsten Termin. Rechtsklick schaltet durch die Formatvorlagen und
schreibt das Ergebnis in die Plugin-Daten zurueck.

**Im Popout** — durchgehend Monospace, wie beim Vorgaenger: eine Kalendertabelle
lebt von festen Spalten.

- das heutige Datum gross als Ueberschrift, darunter ein Balken, wie weit das
  Jahr fortgeschritten ist (abschaltbar)
- Monatsraster mit Kalenderwochen. Heute traegt einen duennen Rahmen, der
  ausgewaehlte Tag eine Fuellung. Mausrad und die Pfeile unter dem Gitter
  blaettern, ein Klick auf den Monatsnamen springt zurueck auf heute
- Punkte unter jedem Tag, einer je beteiligtem Kalender in dessen Farbe; ab
  dem fuenften Kalender ein blasser Mehr-Marker
- Tagesagenda mit Zeitraum, Titel, Ort und Herkunftskalender. Vergangene
  Termine sind **durchgestrichen** statt nur blass, laufende hervorgehoben,
  und eine rote "Jetzt"-Linie steht vor dem naechsten. Das Auge im Agenda-Kopf
  blendet Vergangenes ganz aus und zaehlt dann, wie viel es verbirgt
- Kamera-Knopf bei Terminen mit Videokonferenz, der den Link oeffnet
- Klick auf einen Eintrag schlaegt rechts eine **eigene Detailspalte** auf und
  verbreitert das Popout: Zeitraum, Serienhinweis, ein Beitreten-Knopf, Ort,
  Herkunftskalender, Organisator, Teilnehmer mit Zu- und Absagen sowie der
  Einladungstext. Der Text ist markierbar, weil dort die Einwahlnummern und
  Meeting-IDs stehen. Der Ort bleibt weg, wenn er nichts als der Konferenzlink
  ist -- darauf zeigt ja schon der Knopf.

Videokonferenzen erkennt das Plugin notfalls selbst: `dcal` fuellt `meetingUrl`
nur fuer Zoom, Google Meet und Teams. Steht stattdessen ein BigBlueButton- oder
Jitsi-Link im Ort oder im Einladungstext, findet ihn die Hostliste in
`Model.js` -- uebernommen aus dem Thunderbird-Exporter des Vorgaengers.

## Voraussetzung

Ein Kalender-Backend, das `CalendarService` kennt — also `dcal` oder `khal`.
Laeuft keines, sagt das Popout das statt ein leeres Raster zu zeigen.

```
dcal account add caldav --url https://dav.example.org --username ich --name "Arbeit"
systemctl --user enable --now dcal
```

Ausgeblendete Kalender und abgesagte Termine filtert DMS selbst heraus. Welche
Kalender erscheinen, entscheidet darum nicht dieses Plugin, sondern:

```
dcal ipc calendars.list
dcal ipc calendars.setHidden calendarId=<id> hidden=true
```

Das wirkt zugleich auf Bar, Dash und die dcal-Anwendung — anders als die
`hiddenCalendars`-Liste des Omarchy-Vorgaengers, die nur fuer dessen Panel galt.

## Einbinden

```
ln -s "$PWD" ~/.config/DankMaterialShell/plugins/calendar
dms ipc call plugins scan
dms ipc call plugins enable calendar
```

Danach die Id `calendar` in die Widget-Liste der Bar eintragen
(`~/.config/DankMaterialShell/settings.json`) — sinnvollerweise **anstelle**
der eingebauten `clock`, denn die Pille ersetzt sie.

## Steuerung von aussen

```
dms ipc call calendar toggle        # Popout auf/zu
dms ipc call calendar today         # zurueck auf den heutigen Monat
dms ipc call calendar refresh       # Zeitraum neu anfordern
dms ipc call calendar cycleFormat   # naechstes Bar-Format
dms ipc call calendar weekStart     # Montag <-> Sonntag
dms ipc call calendar status        # Backend und Zahl der heutigen Termine
dms ipc call calendar next          # naechster Termin als Text
```

## Einstellungen

Alles ueber Settings → Plugins → Kalender. `ww` in einem Format setzt die
ISO-Kalenderwoche ein; Qt kennt dafuer kein eigenes Token, das Plugin zerlegt
das Format und setzt die Zahl selbst ein.

## Was gegenueber dem Vorgaenger fehlt

- **Der Lebensbalken** (`birthYear`, `lifeExpectancy`). Der Jahresbalken ist da.
- **Tastaturnavigation.** Ein DMS-Popout kann nur Esc; fuer echten
  Tastaturfokus braeuchte es ein eigenes Overlay wie bei `scribe`.
- **Mittelklick** auf die Pille. Den gibt es in DMS nicht.
- **Die Wiederholungsregel im Klartext** ("alle zwei Wochen mittwochs").
  `dcal` liefert ueber `events.list` nur ein `recurringId`, keine RRULE — es
  bleibt beim Hinweis "Serientermin".

## Tests

```
node --test tests/
```

Deckt nur `Model.js` ab, also die Datums- und Terminmathematik ohne QML.
