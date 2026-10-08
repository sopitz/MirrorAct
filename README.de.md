<p align="center"><img src="docs/icon.png" width="128" alt="MirrorAct-Symbol"></p>

# MirrorAct

iPhone, iPad oder Android-Telefon auf dem Mac spiegeln, rahmen und aufnehmen – per Kabel oder kabellos.
Open Source, alles bleibt auf deinem Mac.

*English: [README.md](README.md)*

<p align="center"><img src="docs/mirror.jpg" width="800" alt="MirrorAct spiegelt ein iPhone, mit Werkzeugleiste und Stil-Panel"></p>

## Warum

Apples *iPhone Mirroring* gibt es in der EU nicht; Apple begründet das mit dem Digital Markets
Act. Daher der Name. MirrorAct zeigt den Bildschirm von iPhone, iPad oder Android-Telefon im
Gerätrahmen auf dem Mac – für Demos, Präsentationen, Screenshots und Bildschirmaufnahmen.
Android-Telefone und, mit einem kleinen Test-Agent, auch iPhone und iPad lassen sich dabei mit Maus
und Tastatur bedienen.

## Loslegen

### 1. Installieren

Mit [Homebrew](https://brew.sh):

```bash
brew install --cask sopitz/tap/mirroract
```

Oder `MirrorAct-<version>.zip` unter [Releases](https://github.com/sopitz/MirrorAct/releases)
laden, entpacken und MirrorAct in den Ordner Programme ziehen. MirrorAct braucht macOS 15 oder
neuer auf einem Mac mit Apple Silicon. Die App ist mit einer Developer ID signiert und von Apple
notarisiert. Aktualisieren mit `brew upgrade --cask mirroract`.

### 2. Gerät verbinden

MirrorAct öffnen. Das Startfenster zeigt deine Geräte, den Code für kabellos und eine Anleitung
zum Verbinden.

- **iPhone oder iPad per Kabel:** Gerät anschliessen und entsperren, «Diesem Computer vertrauen» bestätigen, dann im Startfenster anklicken. Beim ersten Mal fragt macOS nach dem Kamerazugriff – so stellt macOS den Gerätebildschirm bereit.
- **iPhone oder iPad kabellos:** Auf dem Gerät Kontrollzentrum → Bildschirmsynchronisierung → «MirrorAct». Beim ersten Mal den Code aus dem Startfenster eingeben. Erscheint «MirrorAct» nicht, in macOS den AirPlay-Empfänger einschalten (Allgemein → AirDrop & Handoff).
- **Android-Telefon:** MirrorAct braucht adb, aus Homebrew (`brew install android-platform-tools`) oder aus dem Android-SDK (`~/Library/Android/sdk`). Einmalig USB-Debugging einschalten (Einstellungen → Telefoninfo → siebenmal auf «Build-Nummer» tippen, dann Einstellungen → Entwickleroptionen → USB-Debugging), Telefon anschliessen, auf dem Telefon «Zulassen» tippen und es im Startfenster anklicken. Für WLAN: Rechtsklick auf das Telefon im Startfenster → «WLAN statt Kabel verwenden» und danach das Kabel abziehen – ein offenes Fenster läuft über WLAN weiter –, oder ohne Kabel unter Gerät verbinden → Android koppeln (ab Android 11).

### 3. Rahmen, festhalten, präsentieren

Das Spiegelfenster zeigt nur das Gerät im Rahmen. Fährt die Maus darüber, erscheint daneben eine
Werkzeugleiste; ein Rechtsklick zeigt alle Funktionen.

- ⌘S macht einen Screenshot, ⌘R startet und beendet eine Aufnahme. Screenshots lassen sich direkt aus dem Fenster ziehen.
- ⌘K öffnet das Stil-Panel: Grösse, Rahmenfarbe, Hintergrund, Abstand, Schatten, Format.
- ⌃⌘F präsentiert das Gerät im Vollbild auf dem Hintergrund.
- ⌘E öffnet den Editor, für Screenshots und Aufnahmen, die du schon hast.

## Screenshots

| Startfenster | Editor |
|---|---|
| <img src="docs/start-window.jpg" alt="Startfenster mit Gerätekarten, Code für kabellos und Anleitung"> | <img src="docs/editor.jpg" alt="Editor rahmt einen Screenshot auf einem Verlauf in 16:9"> |

**Ergebnis:** ein gerahmter Screenshot auf einem Verlauf, direkt aus dem Spiegelfenster

<img src="docs/framed.jpg" width="800" alt="Gerahmter iPhone-Screenshot auf blauem Verlauf">

Die Bilder zeigen die englische Oberfläche.

## Funktionen

- **Kabel (USB):** Bildabgriff wie bei QuickTime (CoreMediaIO, AVFoundation). Geringste Verzögerung, mit Ton.
- **Kabellos:** eigener AirPlay-Empfänger für die Bildschirmsynchronisierung. VideoToolbox dekodiert ohne Puffer, Ton inklusive. Neben dem WLAN bietet er sich auch über AWDL an (Apples Direktfunk), damit es auch klappt, wenn der Router Bonjour nicht weiterleitet.
- **Android:** über USB-Debugging, per Kabel oder WLAN, mit dem Server von [scrcpy](https://github.com/Genymobile/scrcpy) auf dem Telefon: Video ohne Puffer dekodiert, Ton ab Android 11, Bedienen mit Maus, Trackpad und Tastatur, Zwischenablage in beide Richtungen; siehe [Android-Telefon bedienen](#android-telefon-bedienen).
- **iPhone und iPad bedienen** (optional, für Entwickler): Maus, Trackpad und Tastatur über einen Test-Agent auf dem Gerät (WebDriverAgent), per Kabel oder kabellos; siehe [iPhone oder iPad bedienen](#iphone-oder-ipad-bedienen).
- **Gerätrahmen** pro Modell gezeichnet: Notch, Dynamic Island, Home-Button, iPad, Android mit Kameraloch (Lage und Eckenradius liest MirrorAct vom Telefon), hoch und quer. Sieben Rahmenfarben.
- **Fenster ohne Leiste:** nur das Gerät auf dem Schreibtisch. Fährt die Maus darüber, erscheint daneben eine Werkzeugleiste: Aufnahme, Foto, Ton, Oben, Vollbild, Stil. Ein Rechtsklick zeigt alle Funktionen.
- **Stil-Panel:** Grösse (lebensgross, pixelgenau, punktgenau, Bildschirm füllen), Rahmen an/aus, Rahmenfarbe, Hintergrund (transparent, Verläufe, Farbe, Bild), Abstand, Schatten, Format (1:1, 16:9, 9:16, 4:3).
- **Screenshots und Aufnahmen** mit oder ohne Rahmen und Hintergrund. Mit transparentem Hintergrund entstehen PNG bzw. HEVC mit Alpha für Keynote und Schnittprogramme, sonst H.264. Screenshots lassen sich direkt aus dem Fenster ziehen.
- **Präsentieren:** Gerät mittig auf dem Hintergrund, im Vollbild ohne Menüleiste und Dock.
- **Editor:** vorhandene Screenshots und Bildschirmaufnahmen nachträglich rahmen, Videos kürzen, zwei Screenshots als **Duo** (nebeneinander, versetzt, gekippt, perspektivisch).
- **Kurzbefehle:** «Screenshot einrahmen» (auch als Finder-Schnellaktion), «Screenshot vom iPhone», «Aufnahme starten oder beenden».

Die Oberfläche gibt es auf Englisch und Deutsch; die Sprache lässt sich unter Einstellungen → Allgemein wählen (Systemsprache, Deutsch, English).

## Tastatur und Einstellungen

⌘R Aufnahme, ⌘S Screenshot, ⇧⌘C Screenshot kopieren, ⌘K Stil-Panel, ⌃⌘F Präsentieren,
⌘T immer im Vordergrund, ⌘1 lebensgross, ⌘2 pixelgenau, ⌘0 punktgenau, ⌘E Editor.

Einstellungen unter MirrorAct → Einstellungen, das Log in `~/Library/Logs/MirrorAct.log`.

## Android-Telefon bedienen

Sobald ein Android-Telefon gespiegelt wird, bedient das Spiegelfenster es:

<p align="center"><img src="docs/android.jpg" width="800" alt="MirrorAct spiegelt ein Android-Telefon, mit Zurück, Home und Letzte Apps in der Werkzeugleiste"></p>

- Klick: tippen, Ziehen: wischen (der Finger folgt der Maus live), ⌘-Ziehen verschiebt das Fenster
- Trackpad oder Mausrad: scrollen, Mittelklick: Home
- Tippen geht ans Telefon, auch Umlaute und andere Zeichen; Esc ist Zurück, ⌘V fügt die Zwischenablage des Macs ein, auf dem Telefon kopierter Text landet in der Zwischenablage des Macs
- Zurück, Home und Letzte Apps in der Werkzeugleiste, in Reihenfolge und Aussehen der Navigationsleiste des Telefons (Samsung: Letzte Apps, Home, Zurück); Mitteilungen, Lautstärke, Bildschirm ein/aus und Drehen im Kontextmenü

Dauerhaft installiert wird nichts: Während der Spiegelung läuft der scrcpy-Server aus einer
temporären Datei auf dem Telefon und endet, wenn das Fenster geschlossen wird. Ton gibt es ab
Android 11; er spielt dann auf dem Mac statt auf dem Telefon. Apps, die ihre Inhalte schützen
(Banking, Streaming), bleiben schwarz.

## iPhone oder iPad bedienen

Optional, für Entwickler: Mit einem kleinen Test-Agent auf dem Gerät gibt MirrorAct Klicks, Ziehen,
Scrollen und Tippen an das iPhone oder iPad weiter. iOS erlaubt das nur für UI-Tests, deshalb geht
MirrorAct den Weg, auf dem Xcode Apps automatisiert:
[WebDriverAgent](https://github.com/appium/WebDriverAgent) (aus dem Appium-Projekt) läuft als
UI-Test auf dem Gerät und wird mit `xcodebuild` gestartet.

Dafür braucht es:

- Xcode in einer Version, die die iOS-Version des Geräts unterstützt
- ein Apple-Entwicklerteam (eine kostenlose Apple-ID geht auch, die Signatur läuft aber nach 7 Tagen ab)
- auf dem Gerät: **Entwicklermodus** (Einstellungen → Datenschutz & Sicherheit → Entwicklermodus; das Gerät startet neu) und danach unter Einstellungen → Entwickler die **UI-Automatisierung**

Dieses Repository klonen, `Config/Local.xcconfig.example` nach `Config/Local.xcconfig` kopieren und
die eigene Team-ID als `DEVELOPMENT_TEAM` eintragen. Dann den Agent einmal bauen (erneut nach einem
Wechsel von Team oder Xcode-Version). Das geht auch mit MirrorAct aus Homebrew; es braucht nur
Xcode, nicht die Pakete, mit denen MirrorAct selbst gebaut wird:

```bash
scripts/build-agent.sh
```

Er wird mit dem eigenen Team signiert und liegt dann in
`~/Library/Application Support/MirrorAct/Agent`. Ist das Gerät noch nicht im Team registriert, es
anschliessen und seine Kennung aus Xcode → Devices and Simulators mitgeben:
`scripts/build-agent.sh --device <UDID>`.

Die Bedienung startet von selbst, sobald das Gerät verbunden ist; der Agent braucht auf dem Gerät
einige Sekunden. Klappt das nicht, etwa weil das Gerät gesperrt ist, bleibt in der Werkzeugleiste
der Knopf **Bedienen**; ein Klick darauf (oder Gerät → Gerät bedienen, ⌥⌘C) prüft erneut und sagt,
was fehlt. Wer die Bedienung nur bei Bedarf will, schaltet unter MirrorAct → Einstellungen →
Allgemein «Bedienung beim Verbinden starten» aus. Nach dem Ausschalten oder Schliessen des Fensters
läuft der Agent noch fünf Minuten auf dem Gerät weiter, damit die Bedienung sofort wieder da ist;
beim Beenden von MirrorAct wird er gestoppt. Danach:

- Klick: Tippen, Halten: langes Drücken, Ziehen: Wischen
- Trackpad oder Mausrad: Scrollen (den Schwung ergänzt iOS selbst)
- Tippen geht in das aktive Textfeld, ⌘V tippt den Text aus der Zwischenablage des Macs
- Home, App-Umschalter, Mitteilungszentrale, Lautstärke und Sperren in der Werkzeugleiste und im Kontextmenü

Das geht per Kabel und kabellos; MirrorAct erreicht den Agent über usbmuxd (wie Xcode) oder über das
lokale Netz. Gesten werden beim Loslassen der Maustaste geschickt, der Finger folgt der Maus also
nicht live. Ein Gerät mit Code lässt sich so nicht entsperren. Die Ausgabe von `xcodebuild` steht in
`~/Library/Logs/MirrorAct-Agent.log`.

## Datenschutz

MirrorAct arbeitet lokal, sendet keine Daten und hat keine Telemetrie. Netzwerkzugriff gibt es nur
für den AirPlay-Empfänger im lokalen Netz und über AWDL, für adb zu Android-Telefonen (per Kabel
oder, bei WLAN, im lokalen Netz) sowie, während ein iPhone oder iPad bedient wird, zum Agent auf
diesem Gerät.

## Rechtliches

MirrorAct steht in keiner Verbindung zu Apple Inc. iPhone, iPad, AirPlay und macOS sind Marken
von Apple Inc. Der kabellose Empfang nutzt die unabhängige AirPlay-Umsetzung des Projekts
[UxPlay](https://github.com/FDH2/UxPlay). Geschützte Inhalte (z. B. aus Streaming-Apps) sperrt
iOS; sie lassen sich nicht spiegeln.

Android ist eine Marke von Google LLC; MirrorAct steht in keiner Verbindung zu Google. Die
Android-Spiegelung nutzt den Server des Projekts [scrcpy](https://github.com/Genymobile/scrcpy)
von Genymobile.

## Rückmeldungen und Mitarbeit

Einen Fehler gefunden oder fehlt etwas? Dafür gibt es die [Issues](https://github.com/sopitz/MirrorAct/issues).
Wer MirrorAct selbst bauen oder daran mitarbeiten will – aus dem Quellcode bauen, Aufbau des Codes,
Branches und Releases –, findet alles in [CONTRIBUTING.de.md](CONTRIBUTING.de.md).

## Unterstützen

MirrorAct ist kostenlos. Wenn dir die App Zeit spart, kannst du mir [einen Kaffee spendieren](https://buymeacoffee.com/sopitz).

[![Buy me a coffee](https://img.shields.io/badge/Buy_me_a_coffee-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/sopitz)

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE). Fremdkomponenten: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
