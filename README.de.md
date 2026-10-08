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
Android-Telefone lassen sich dabei auch mit Maus und Tastatur bedienen.

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
- **Android:** über USB-Debugging, per Kabel oder WLAN, mit dem Server von [scrcpy](https://github.com/Genymobile/scrcpy) auf dem Telefon: Video ohne Puffer dekodiert, Ton ab Android 11, Bedienen mit Maus, Trackpad und Tastatur, Zwischenablage in beide Richtungen.
- **Gerätrahmen** pro Modell gezeichnet: Notch, Dynamic Island, Home-Button, iPad, Android mit Kameraloch (Lage und Eckenradius liest MirrorAct vom Telefon), hoch und quer. Sieben Rahmenfarben.
- **Fenster ohne Leiste:** nur das Gerät auf dem Schreibtisch. Fährt die Maus darüber, erscheint daneben eine Werkzeugleiste: Aufnahme, Foto, Ton, Oben, Vollbild, Stil. Ein Rechtsklick zeigt alle Funktionen.
- **Stil-Panel:** Grösse (lebensgross, pixelgenau, punktgenau, Bildschirm füllen), Rahmen an/aus, Rahmenfarbe, Hintergrund (transparent, Verläufe, Farbe, Bild), Abstand, Schatten, Format (1:1, 16:9, 9:16, 4:3).
- **Screenshots und Aufnahmen** mit oder ohne Rahmen und Hintergrund. Mit transparentem Hintergrund entstehen PNG bzw. HEVC mit Alpha für Keynote und Schnittprogramme, sonst H.264. Screenshots lassen sich direkt aus dem Fenster ziehen.
- **Präsentieren:** Gerät mittig auf dem Hintergrund, im Vollbild ohne Menüleiste und Dock.
- **Editor:** vorhandene Screenshots und Bildschirmaufnahmen nachträglich rahmen, Videos kürzen, zwei Screenshots als **Duo** (nebeneinander, versetzt, gekippt, perspektivisch).
- **Kurzbefehle:** «Screenshot einrahmen» (auch als Finder-Schnellaktion), «Screenshot vom iPhone», «Aufnahme starten oder beenden».

Die Oberfläche gibt es auf Englisch und Deutsch; die Sprache lässt sich unter Einstellungen → Allgemein wählen (Systemsprache, Deutsch, English).

## Voraussetzungen

- macOS 15 oder neuer (getestet auf Apple Silicon)
- Xcode 16 oder neuer
- [Homebrew](https://brew.sh)-Pakete:

```bash
brew install xcodegen cmake pkgconf libplist openssl@3 gstreamer
```

GStreamer braucht nur UxPlays CMake beim Konfigurieren, MirrorAct selbst nutzt es nicht. OpenSSL
und libplist werden statisch gelinkt, die fertige App braucht kein Homebrew.

Für Android nutzt MirrorAct adb aus Homebrew (`brew install android-platform-tools`) oder aus dem
Android-SDK (`~/Library/Android/sdk`).

## Bauen

```bash
scripts/build.sh
```

Das Skript holt UxPlay mit festem Commit nach `Vendor/`, baut nur dessen AirPlay-Bibliothek,
lädt den scrcpy-Server für Android (feste Version, per SHA-256 geprüft),
erzeugt das Xcode-Projekt mit XcodeGen, baut die App und installiert sie nach
`~/Applications/MirrorAct.app`. `--debug` baut die Debug-Konfiguration, `--no-install` lässt die
Installation weg.

Standardmässig wird ad-hoc signiert. macOS fragt dann nach jedem Build erneut nach dem
Kamerazugriff. Damit die Freigabe bleibt, mit eigenem Zertifikat signieren:
`Config/Local.xcconfig.example` nach `Config/Local.xcconfig` kopieren und Signatur und Team
eintragen.

## Benutzung

- **Kabel:** Gerät anschliessen und entsperren, «Diesem Computer vertrauen» bestätigen, dann im Startfenster anklicken. Beim ersten Mal fragt macOS nach dem Kamerazugriff – so stellt macOS den Gerätebildschirm bereit.
- **Kabellos:** Auf dem Gerät Kontrollzentrum → Bildschirmsynchronisierung → «MirrorAct». Beim ersten Mal den Code aus dem Startfenster eingeben. Erscheint «MirrorAct» nicht, in macOS den AirPlay-Empfänger einschalten (Allgemein → AirDrop & Handoff).
- **Android:** Einmalig USB-Debugging einschalten (Einstellungen → Telefoninfo → siebenmal auf «Build-Nummer» tippen, dann Einstellungen → Entwickleroptionen → USB-Debugging), Telefon anschliessen, auf dem Telefon «Zulassen» tippen und es im Startfenster anklicken. Für WLAN: Rechtsklick auf das Telefon im Startfenster → «WLAN statt Kabel verwenden» und danach das Kabel abziehen – ein offenes Fenster läuft über WLAN weiter –, oder ohne Kabel unter Gerät verbinden → Android koppeln (ab Android 11).
- **Tastatur:** ⌘R Aufnahme, ⌘S Screenshot, ⇧⌘C Screenshot kopieren, ⌘K Stil-Panel, ⌃⌘F Präsentieren, ⌘T immer im Vordergrund, ⌘1 lebensgross, ⌘2 pixelgenau, ⌘0 punktgenau, ⌘E Editor.

Einstellungen unter MirrorAct → Einstellungen, das Log in `~/Library/Logs/MirrorAct.log`.

## Android-Telefon bedienen

Sobald ein Android-Telefon gespiegelt wird, bedient das Spiegelfenster es:

<p align="center"><img src="docs/android.jpg" width="800" alt="MirrorAct spiegelt ein Android-Telefon, mit Zurück, Home und Letzte Apps in der Werkzeugleiste"></p>

- Klick: tippen, Ziehen: wischen (der Finger folgt der Maus live), ⌘-Ziehen verschiebt das Fenster
- Trackpad oder Mausrad: scrollen, Mittelklick: Home
- Tippen geht ans Telefon, auch Umlaute und andere Zeichen; Esc ist Zurück, ⌘V fügt die Zwischenablage des Macs ein, auf dem Telefon kopierter Text landet in der Zwischenablage des Macs
- Zurück, Home und Letzte Apps in der Werkzeugleiste; Mitteilungen, Lautstärke, Bildschirm ein/aus und Drehen im Kontextmenü

Dauerhaft installiert wird nichts: Während der Spiegelung läuft der scrcpy-Server aus einer
temporären Datei auf dem Telefon und endet, wenn das Fenster geschlossen wird. Ton gibt es ab
Android 11; er spielt dann auf dem Mac statt auf dem Telefon. Apps, die ihre Inhalte schützen
(Banking, Streaming), bleiben schwarz.

## Aufbau

Siehe Tabelle im [englischen README](README.md#how-it-works). Ohne Gerät lässt sich die Darstellung
prüfen:

```bash
~/Applications/MirrorAct.app/Contents/MacOS/MirrorAct --render-test /tmp/mirroract-render
```

## Datenschutz

MirrorAct arbeitet lokal, sendet keine Daten und hat keine Telemetrie. Netzwerkzugriff gibt es nur
für den AirPlay-Empfänger im lokalen Netz und über AWDL sowie für adb zu Android-Telefonen (per
Kabel oder, bei WLAN, im lokalen Netz).

## Rechtliches

MirrorAct steht in keiner Verbindung zu Apple Inc. iPhone, iPad, AirPlay und macOS sind Marken
von Apple Inc. Der kabellose Empfang nutzt die unabhängige AirPlay-Umsetzung des Projekts
[UxPlay](https://github.com/FDH2/UxPlay). Geschützte Inhalte (z. B. aus Streaming-Apps) sperrt
iOS; sie lassen sich nicht spiegeln.

Android ist eine Marke von Google LLC; MirrorAct steht in keiner Verbindung zu Google. Die
Android-Spiegelung nutzt den Server des Projekts [scrcpy](https://github.com/Genymobile/scrcpy)
von Genymobile.

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE). Fremdkomponenten: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
