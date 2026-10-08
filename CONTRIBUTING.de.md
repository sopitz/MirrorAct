# Mitarbeiten an MirrorAct

*English: [CONTRIBUTING.md](CONTRIBUTING.md)*

Hier geht es um die Arbeit an MirrorAct selbst. Wie man die App installiert und benutzt, steht im
[README](README.de.md).

Fehler und Ideen gehören in die [Issues](https://github.com/sopitz/MirrorAct/issues), Änderungen
kommen als Pull Request nach `develop` (siehe [Branches und Pull Requests](#branches-und-pull-requests)).

## Selbst bauen

Dafür braucht es:

- macOS 15 oder neuer (getestet auf Apple Silicon)
- Xcode 16 oder neuer
- [Homebrew](https://brew.sh)-Pakete:

```bash
brew install xcodegen cmake pkgconf libplist openssl@3 gstreamer
```

GStreamer braucht nur UxPlays CMake beim Konfigurieren, MirrorAct selbst nutzt es nicht. OpenSSL
und libplist werden statisch gelinkt, die fertige App braucht kein Homebrew.

Dann:

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
eintragen. Dasselbe Team signiert den Agent für die Bedienung von iPhone und iPad
(`scripts/build-agent.sh`, siehe [README](README.de.md#iphone-oder-ipad-bedienen)).

## Aufbau

| Ordner | Inhalt |
|---|---|
| `MirrorAct/AirPlay` | `airplay_bridge.c` – dünne C-Schicht über UxPlays AirPlay-Bibliothek (Bonjour oder UxPlays eigener mDNS-Responder, Heartbeat, Neustart; baut auf macOS, Linux und Windows), `AirPlayReceiver` |
| `AirPlayHelper` | `mirroract-airplay` – derselbe Empfänger als eigenes Programm für andere Apps (Rahmen über stdout, Befehle über stdin; Protokoll und Build in [`AirPlayHelper/README.md`](AirPlayHelper/README.md), Englisch); `.github/workflows/airplay-helper.yml` baut ihn für macOS, Windows und Linux |
| `MirrorAct/Android` | `ADB` (adb, Geräteliste, WLAN), `ScrcpyClient` (scrcpy-Protokoll: Video-, Ton- und Steuer-Socket), `AndroidControl` (Maus und Tastatur als scrcpy-Steuernachrichten) |
| `MirrorAct/Audio` | `AACAudioPlayer` (AAC-ELD von AirPlay, AAC-LC von Android, ohne Puffer) |
| `MirrorAct/Video` | `AnnexBDecoder` (H.264/HEVC → VideoToolbox), `FrameSink` / `VideoDisplayView` (AVSampleBufferDisplayLayer) |
| `MirrorAct/USB` | Geräte finden und Bild abgreifen (`AVCaptureDevice`, `.muxed`) |
| `MirrorAct/Frame` | Geräteprofile, Rahmengeometrie, `FrameStyle`, `SceneRenderer` (Core Image; gemeinsam für Screenshots, Aufnahmen und Editor) |
| `MirrorAct/Mirror` | Spiegelfenster, Werkzeugleiste, Stil-Panel, Präsentieren, `DeviceControl` (Schnittstelle zum Bedienen eines Geräts) |
| `MirrorAct/Control` | Bedienung von iPhone/iPad: `IOSControl` (Gesten, Tastatur, Start des Agents über `xcodebuild`), `AgentRunners` (laufende Agents, einige Minuten gehalten), `AgentConnection` (HTTP zu WebDriverAgent), `USBMux` (usbmuxd) |
| `MirrorAct/Recording` | `MirrorRecorder` (AVAssetWriter, Host-Zeit, variable Bildrate) |
| `MirrorAct/Editor` | Editor, `DuoRenderer`, `VideoFramer` (AVVideoComposition + Export) |
| `MirrorAct/Intents` | App Intents für Kurzbefehle |
| `MirrorAct/Launcher` | Startfenster, Einstellungen |
| `MirrorAct/Localization` | String Catalogs (Englisch als Quelle, deutsche Übersetzung), Info.plist und Siri-Phrasen |
| `Agent` | MirrorActs Zusatzbefehle für WebDriverAgent (schnelle Berührungen), von `scripts/build-agent.sh` mitkompiliert |
| `scripts` | Skripte für Build, Agent, Release und Symbol |

## Ohne Gerät testen

Ohne Gerät lässt sich die Darstellung prüfen:

```bash
~/Applications/MirrorAct.app/Contents/MacOS/MirrorAct --render-test /tmp/mirroract-render
```

Das schreibt Rahmen, Stile, Duo-Posen und Teile der Oberfläche als PNG, nimmt zwei kurze
Testvideos auf (mit Drehung und mit AAC-ELD-Ton wie über AirPlay) und rahmt eines davon wie der
Editor.

## Screenshots

Die Bilder in `docs/` zeichnet die App selbst aus ihren echten Ansichten: im Debug-Build mit
`MirrorAct --showcase <ordner>` oder beim Spiegeln über die Distributed Notification
`io.github.sopitz.MirrorAct.showcase`; der Gerätebildschirm ist das live gespiegelte Bild. Keine
nachgebauten oder retuschierten Bilder.

Format wie die vorhandenen: JPEG, 1600 px breit; PNG nur, wo Transparenz nötig ist. Keine privaten
Inhalte (Nachrichten, Kontakte, Benachrichtigungen) auf dem Gerätebildschirm.

## Branches und Pull Requests

MirrorAct arbeitet mit Git Flow: `main` enthält die letzte Veröffentlichung, `develop` die Arbeit
für die nächste.

| Branch | Zweck |
|---|---|
| `main` | Veröffentlichte Versionen, jede mit Tag `v<version>` |
| `develop` | Nächste Veröffentlichung, Ziel für Pull Requests |
| `feature/<thema>`, `chore/<thema>` | Zweigen von `develop` ab, kommen zurück nach `develop` |
| `release/<version>` | Zweigt von `develop` ab, geht nach `main` und `develop` |
| `hotfix/<version>` | Zweigt von `main` ab, geht nach `main` und `develop` |

Für einen Pull Request:

- ein Thema pro Branch, abgezweigt von `develop`, Pull Request nach `develop`
- Commit-Messages und Pull Requests auf Englisch, sie beschreiben die Änderung
- wer Funktionen, Bedienung, Voraussetzungen, den Build oder die Ordnerstruktur ändert, passt
  `README.md` und `README.de.md` (bzw. `CONTRIBUTING.md` und `CONTRIBUTING.de.md`) im selben
  Branch an – inhaltlich gleich, jede in ihrer Sprache
- zu einer sichtbaren Änderung gehören aktuelle Screenshots in `docs/`: Bilder ersetzen, die nicht
  mehr stimmen, für neue Funktionen neue aufnehmen und in beiden READMEs einbinden, mit `alt`-Text
  in der jeweiligen Sprache

## Release

Für Maintainer. Ein Release geht über einen Branch `release/<version>` von `develop` nach `main`:

1. `release/<version>` von `develop` abzweigen, `MARKETING_VERSION` und
   `CURRENT_PROJECT_VERSION` in `project.yml` erhöhen und einen Pull Request nach `main` öffnen.
2. Nach dem Merge den Merge-Commit auf `main` taggen:
   `git tag -a v<version> -m "MirrorAct <version>"`.
3. Aus einer sauberen Arbeitskopie auf dem Tag `scripts/release.sh --publish` ausführen.
4. `main` per Pull Request zurück nach `develop` führen.

`scripts/release.sh` baut die App zum Weitergeben: mit Developer ID signiert, von Apple notarisiert
und als `build/release/MirrorAct-<version>.zip` gepackt. Mit `--publish` pusht es zusätzlich das
Tag, legt das GitHub-Release `v<version>` an und führt den Cask in
[sopitz/homebrew-tap](https://github.com/sopitz/homebrew-tap) nach. Ohne `--publish` baut und
notarisiert es nur.

Dafür braucht es das Zertifikat «Developer ID Application» im Schlüsselbund, für `--publish` die
[GitHub CLI](https://cli.github.com) und einmalig ein notarytool-Profil:

```bash
xcrun notarytool store-credentials mirroract-notary --apple-id <Apple-ID> --team-id <Team>
```

Die erzeugten Release-Notes sind knapp; durch eigene ersetzen:
`gh release edit v<version> --notes-file <datei>`.
