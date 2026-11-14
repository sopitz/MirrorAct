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

Das Skript holt UxPlay mit festem Commit nach `Vendor/`, baut nur dessen AirPlay-Bibliothek, lädt
den scrcpy-Server für Android (feste Version, per SHA-256 geprüft), erzeugt das Xcode-Projekt mit
XcodeGen, baut die App und installiert sie nach `~/Applications/MirrorAct.app`. `--debug` baut die
Debug-Konfiguration, `--no-install` lässt die Installation weg, und Argumente `NAME=WERT` gibt das
Skript als Build-Einstellungen an xcodebuild weiter; `MIRRORACT_DERIVED` wählt einen anderen
Build-Ordner als `~/Library/Caches/MirrorAct/DerivedData`.

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
| `MirrorAct/Frame` | Geräteprofile (`DeviceProfile` liest `Shared/DeviceProfiles.json`), Rahmengeometrie, `FrameStyle`, `SceneRenderer` (Core Image; gemeinsam für Screenshots, Aufnahmen und Editor) |
| `MirrorAct/Mirror` | Spiegelfenster, Werkzeugleiste, Stil-Panel, Präsentieren, `DeviceControl` (Schnittstelle zum Bedienen eines Geräts) |
| `MirrorAct/Control` | Bedienung von iPhone/iPad: `IOSControl` (Gesten, Tastatur, Start des Agents über `xcodebuild`), `AgentRunners` (laufende Agents, einige Minuten gehalten, beim Ende einer kabellosen Verbindung gestoppt), `AgentConnection` (HTTP zu WebDriverAgent), `USBMux` (usbmuxd) |
| `MirrorAct/Recording` | `MirrorRecorder` (AVAssetWriter, Host-Zeit, variable Bildrate) |
| `MirrorAct/Text` | Text auf dem Bildschirm: `TextRecognizer` (Vision; `LeadingMark` lässt ein Symbol weg, das als Zeichen vor einer Zeile gelesen wurde, `LineTone` misst, wie hell und wie farbig die Buchstaben einer Zeile sind), `FramePixels` (Vorschaubilder und Farben direkt aus dem Bild), `ScreenTranslator` (ein `FrameProcessor` im `FrameSink`: liest, übersetzt und zeichnet neben den Bildern her), `TranslationCompositor` mit `BlockPlacement`, `BlockTextMask` und `ChromaPlane` (zeichnet die Übersetzungen in eine Kopie des Bildes, in dessen eigenem Pixelformat und in der Grösse des ursprünglichen Textes), `TranslationEngine` (die Schnittstelle, die jeder Übersetzer erfüllt), `TranslationEngines` (wählt, was laut Einstellungen übersetzt), `AppleTranslationEngine` (Apples Translation-Framework; ordnet die Texte mit `LanguageMatching` nach Sprachen und sendet die kurzen Beschriftungen eines Bildschirms zusammen, `AppleTranslationJoining`; die Sitzungen leben in einem unsichtbaren Hilfsfenster, `AppleTranslationHost`), `LLMTranslationEngine` (Sprachmodell-Dienste mit dem Schlüssel des Nutzers aus `KeychainStore`) |
| `MirrorAct/Text/Core` | der Teil, der nur Foundation verwendet (und CoreGraphics, wo es das gibt), damit andere MirrorAct-Apps ihn verwenden können: `TextLayout` (Zeilen zu Absätzen; lässt die Statusleiste weg und, für «Übersetzen», die als Buchstaben gelesenen Symbole von Listeneinträgen, hält den Titel eines Eintrags an der Helligkeit der Buchstaben von seiner Zusammenfassung getrennt, markiert abgeschnittene Zeilen), `TextTracking` (die Werte, die Texterkennung, Tracker und Zeichnen austauschen), `LumaImage` (Vorschaubilder), `OverlayTracker` mit `MotionEstimator`, `ReadingPlan` und `BlockPatch` (hält Übersetzungen auf ihrem Text, während sich der Inhalt bewegt, und entscheidet, was wann gelesen und was wann zum Übersetzen geschickt wird), `YCbCrColor`, `LLMProvider`/`LLMWire`/`TranslationPrompt` (was an einen Dienst geht und wie seine Antworten gelesen werden, ohne Netzwerk), `LanguageMatching` (die Sprache jedes Textes und des Bildschirms, und wann macOS nach einer Sprache gefragt werden darf). Seine Regeln stehen in seinen Kommentaren, und wer eine Regel ändert, beschreibt die Änderung dort. Die Tests liegen in `MirrorActTests/TextCore` (mit einem Simulator scrollender Telefonbildschirme und einem Prüfstand, `Tracking*.swift`) |
| `MirrorAct/Editor` | Editor, `DuoRenderer`, `VideoFramer` (AVVideoComposition + Export) |
| `MirrorAct/Intents` | App Intents für Kurzbefehle |
| `MirrorAct/Launcher` | Startfenster, Einstellungen |
| `MirrorAct/Localization` | String Catalogs (Englisch als Quelle, deutsche Übersetzung), Info.plist und Siri-Phrasen |
| `Shared` | `DeviceProfiles.json` – die Gerätebauformen (Notch, Dynamic Island, Kameraloch, Ecken, Rand, Tasten, Punkte, ppi; bei einem faltbaren Gerät auch der innere Bildschirm, unter `unfolded`) für alle MirrorAct-Apps; als Ressource in die App gebündelt; ausserhalb der App kompilierte Swift-Werkzeuge (z. B. mit swiftc) können mit `MIRRORACT_DEVICE_PROFILES` darauf zeigen; andere MirrorAct-Apps lesen dieselbe Datei. `scripts/build.sh` prüft sie als striktes JSON (keine Kommas am Ende), und die App bricht beim Start bei unbekannten Schlüsseln oder widersprüchlichen Einträgen ab. Ein Name darin, der eine Übersetzung braucht, bekommt einen manuellen Eintrag in `MirrorAct/Localization/Localizable.xcstrings`, weil der Compiler ihn nicht extrahieren kann |
| `Agent` | MirrorActs Zusatzbefehle für WebDriverAgent (schnelle Berührungen), von `scripts/build-agent.sh` mitkompiliert |
| `MirrorActTests` | Tests, laufen in einem Debug-Build der App (`scripts/test.sh`) |
| `scripts` | Skripte für Build, Tests, Agent, Release, Symbol und die Prüfung der Geräteprofile |

### Text und Übersetzen

«Text» liest das aktuelle Bild mit `TextRecognizer` und kopiert `TextLayout.plainText`, das alles
behält ausser der Statusleiste, Zeilen, die der obere oder untere Rand abschneidet, und
Unlesbarem (`TextLayout.Purpose.copying`).

Solange «Übersetzen» an ist, ist `ScreenTranslator` der `FrameProcessor` im `FrameSink` des
Fensters, und jedes Bild läuft durch ihn:

1. `FramePixels` macht ein Vorschaubild, und `OverlayTracker.advance` führt die bekannten Absätze
   darauf nach (`MotionEstimator` sagt, was blieb, sich verschob oder sich änderte) und sagt, wo
   jeder gezeichnet wird und ob ein Bereich gelesen werden muss.
2. Neben den Bildern her liest `TextRecognizer` diesen Bereich des Bildes, wie das Gerät es
   gesendet hat; `TextLayout.content` (`.translating`) lässt die Statusleiste und die Symbole von
   Listeneinträgen weg, und `TextLayout.blocks` bildet die Absätze, nie über eine bekannte Kante
   eines Scrollbereichs hinweg. `OverlayTracker.finishRecognition` übernimmt sie; `ReadingPlan`
   hält fest, was noch wann gelesen werden muss (was ins Bild gescrollt ist, sofort; was sich
   geändert hat, sobald es ruht; eine abgeschnittene Zeile, sobald sie ganz zu sehen ist).
3. Der Tracker entscheidet, welche Texte wann an den Übersetzer gehen (`textsAwaitingTranslation`,
   höchstens 40 in einer Anfrage). Ein Übersetzer mit `prefersSettledText` (ein Sprachmodell-Dienst)
   wartet vorher bis zu 1,5 s darauf, dass das Bild ruht. Ein Text, dessen Übersetzung fehlschlug,
   wird nach 5, 10, 20 und 40 s und dann alle 60 s wieder angeboten; der Übersetzer eines Dienstes
   wartet mit denselben Schritten auf den Dienst als Ganzes (`TranslationWait`), damit sich die
   beiden Wartezeiten nicht addieren.
4. `TranslationCompositor.prepare` setzt die Übersetzungen mit Core Text ausserhalb des Threads der
   Bilder (`BlockTextMask`), und `compose` zeichnet sie in eine Kopie jedes Bildes, die Fenster,
   Screenshots und Aufnahmen zeigen.

Jedes Mal, wenn «Übersetzen» eingeschaltet wird oder sich seine Einstellungen ändern, beginnt es
neu, mit dem Übersetzer, den `TranslationEngines` nach den Einstellungen erzeugt.

Die Regeln des Kerns, wie seine Kommentare sie nennen: Er verwendet nur Foundation (und
CoreGraphics, wo es das gibt), damit andere MirrorAct-Apps ihn verwenden können. `OverlayTracker`
ist nicht threadsicher (der Aufrufer sorgt dafür, dass sich Aufrufe nie überschneiden), hat keine
Uhr und keinen Zufall (dieselben Aufrufe ergeben dieselben Ergebnisse; Zeiten sind Sekunden einer
beliebigen stetigen Uhr) und misst die Lage eines Blocks an den Pixeln, aus denen er gelesen wurde,
statt sie von Bild zu Bild aufzusummieren. `LLMWire` enthält nur Werte und reine Funktionen, damit
derselbe Code und dieselben Tests beschreiben, was an einen Dienst geht. Rechtecke zwischen den
Teilen sind in Pixeln des Bildes, Ursprung oben links; die von `TextLayout` in 0…1 des Bildes.
`TextLayout` hält den Titel eines Eintrags nur dann von seiner Zusammenfassung getrennt, wenn die
Texterkennung `RecognizedLine.tone` gemessen hat; ohne das bewirkt diese Regel nichts.

## Ohne Gerät testen

Ohne Gerät lässt sich die Darstellung prüfen:

```bash
~/Applications/MirrorAct.app/Contents/MacOS/MirrorAct --render-test /tmp/mirroract-render
```

Das schreibt Rahmen (auch das iPhone Duo zu- und aufgeklappt), Stile, Duo-Posen und Teile der
Oberfläche als PNG, nimmt zwei kurze Testvideos auf (mit Drehung und mit AAC-ELD-Ton wie über
AirPlay) und rahmt eines davon wie der Editor.

Nach Änderungen an `Shared/DeviceProfiles.json` prüft `scripts/test-device-profiles.sh`, ob die
Tabelle gültig ist, ob fehlerhafte Einträge (vertippte Schlüssel, falsche Pixelgrössen,
unbekannte Aussparungen, Tasten neben ihrer Kante) mit einer klaren Meldung abgelehnt werden und
ob beim iPhone Duo die Bildgrösse den zu- und den aufgeklappten Bildschirm unterscheidet.

## Tests

```bash
scripts/test.sh
```

Führt `MirrorActTests` in einem Debug-Build der App aus, die den Tests als Host dient;
`scripts/test.sh PresentationTests` führt nur eine Klasse aus (auch `Klasse/testName`, und mehrere
Namen auf einmal). Das Skript holt `Vendor/` und den scrcpy-Server, wo sie fehlen, erzeugt das
Projekt, baut nach `~/Library/Caches/MirrorAct/DerivedData` (`MIRRORACT_DERIVED` wählt einen
anderen Ordner), schreibt die ganze Ausgabe dort nach `test.log` und zeigt die Fehler oder die
Zahl der ausgeführten Tests. Jede `TRACKING_*`-Variable gibt es an die Tests weiter (siehe den
Prüfstand unten).

Als Host startet die App ohne AirPlay-Empfänger, USB und adb, hält ihre Einstellungen von den
eigenen getrennt (Domain `io.github.sopitz.MirrorAct.tests`, geleert, wenn ein Lauf beginnt und
wenn er endet; API-Schlüssel unter einem eigenen Namen im Schlüsselbund) und schreibt nur ins
Systemlog. Zwei Testläufe gleichzeitig teilen diese Domain und stören einander: immer nur einen
laufen lassen.

Einige Tests öffnen echte Fenster. `PresentationTests` zeigt ein Spiegelfenster, holt die App nach
vorn und geht ins Vollbild; `StylePanelAppearanceTests` zeigt ein Spiegelfenster und holt die App
nach vorn; `TextSettingsViewTests` zeigt die Text-Einstellungen in einem Fenster und macht es zum
aktiven; `OnTopTests` zeigt ein Spiegelfenster, holt die App nach vorn, lässt das Fenster über
anderen Fenstern und auf jedem Schreibtisch schweben und geht einmal ins Vollbild.
(`SettingsLayoutTests` und `ShowcaseTests` legen ihre Fenster ausserhalb der Bildschirme ab;
`AppleTranslationEngineTests` holt kurz ein fast durchsichtiges Fenster auf den Bildschirm, das
weder Klicks noch Tasten annimmt.) Wer währenddessen am Mac arbeiten will, lässt diese vier weg:
die nötigen Klassen mit Namen aufrufen, oder xcodebuild wie das Skript aufrufen, mit
`-skip-testing`:

```bash
caffeinate -d -i xcodebuild -project MirrorAct.xcodeproj -scheme MirrorAct -configuration Debug \
  -derivedDataPath ~/Library/Caches/MirrorAct/DerivedData HOMEBREW_PREFIX=$(brew --prefix) \
  -skip-testing:MirrorActTests/PresentationTests \
  -skip-testing:MirrorActTests/StylePanelAppearanceTests \
  -skip-testing:MirrorActTests/TextSettingsViewTests \
  -skip-testing:MirrorActTests/OnTopTests test
```

Die Tests brauchen einen wachen Bildschirm: Schläft er, enden die Animationen dieser Fenster nie,
jede hält einen Thread, und ist keiner mehr frei, wartet ein Test, der Text liest, für immer in
Vision. `scripts/test.sh` weckt den Bildschirm deshalb und hält ihn wach, solange die Tests laufen
(`caffeinate`).

Ein Test, der mit AppKit zeichnet, darf nicht von den angeschlossenen Bildschirmen abhängen:
`NSImage`, vor allem bei SF Symbols, richtet ein Bild an den Pixeln des Hauptbildschirms aus, auch
wenn es in ein eigenes Bitmap zeichnet. Ein solcher Test bekommt feste Masse
(`LeadingMarkTests.SettingsRows` macht jedes Symbol hundertmal so gross und zeichnet es in seiner
genauen Grösse), ein festes Erscheinungsbild und ausdrücklich gesetzte Schriftglättung, und er muss
mit einem Bildschirm mit Faktor 1 ebenso bestehen wie mit Faktor 2.

Die Tests von «Text» und «Übersetzen» brauchen kein Gerät und kein Netzwerk: `TextRecognizerTests`,
`LeadingMarkTests`, `ScreenTranslatorTests` und `ScreenTranslatorCutOffTests` (erzeugte Bilder,
echtes Vision), `ScreenTranslatorRetryTests` (Minuten eines ausfallenden Dienstes, mit einer
eigenen Uhr des Tests), `TranslationCompositorTests`, `ChromaPlaneTests`,
`AppleTranslationEngineTests` (ein Stellvertreter antwortet an Stelle von macOS, macOS wird also
nie gebeten, zu übersetzen oder eine Sprache zu laden), `LLMTranslationEngineTests`,
`LLMSessionTests` und `LocalServiceWaitTests` (ein Stellvertreter für das Netzwerk),
`TranslationStatusNoticeTests`, `TextSettingsViewTests`, `TextSettingsLanguageMenuTests`,
`MirrorSessionTests` («Übersetzen», wenn das Gerät weggeht oder die App das Fenster auf eine andere
Verbindung wechselt), `ShowcaseTests` (die Bilder, mit «Übersetzen» so, wie es die gespiegelte
Sitzung hat) und `FrameSinkTests` (das übersetzte Bild wird gezeigt und aufgenommen); die Tests des
Kerns liegen in `MirrorActTests/TextCore` (`OverlayTrackerContractTests` hält fest, was jeder
Tracker tun muss).

### Der Prüfstand für das Nachführen

`TrackingBenchTests` spielt den Tracker durch Szenarien eines simulierten Telefonbildschirms
(`TrackingScenarios.swift`: Scrollen, Wischen mit Schwung, Leisten, Banner, Hinweisfenster, eine
Tastatur, neue Bildschirme, ein Video und Streifen, die von selbst seitwärts gleiten, etwa ein
Karussell und ein Ticker) und bewertet, was er zeichnet, an der Wahrheit der Simulation
(`TrackingBench.swift`). Jedes Szenario hat einen Regressionstest mit Seed 1, mit einer
Mindestpunktzahl und einer Höchstzahl falsch platzierter Bilder, und ein untersuchter Seed kann
einen eigenen Test haben (`testAlikeRowsSeed19` …). Der Prüfstand ist deterministisch: Schlägt ein
Test fehl, ist der Tracker schlechter geworden, oder der Prüfstand hat sich geändert.

Ein Debug-Build spielt ihn fünfzig- bis hundertmal langsamer als ein Release-Build;
`scripts/test.sh` spielt deshalb nur einige Szenarien und überspringt den Rest absichtlich, und die
übersprungenen Tests sagen das. `TRACKING_ALL=1 TRACKING_SEEDS=1 scripts/test.sh
TrackingBenchTests` spielt im Debug-Build alle und dauert fast eine Stunde. Im Release-Build, nach
`scripts/build.sh --no-install` (das `Vendor/` holt und das Projekt erzeugt), dauern der ganze
Prüfstand und sein Bericht über die Seeds 1 bis 3 einige Minuten:

```bash
TEST_RUNNER_TRACKING_REPORT=/tmp/tracking.json xcodebuild -project MirrorAct.xcodeproj \
  -scheme MirrorAct -configuration Release ENABLE_TESTABILITY=YES HOMEBREW_PREFIX=$(brew --prefix) \
  -only-testing:MirrorActTests/TrackingBenchTests test
```

xcodebuild gibt eine Variable nur mit dem Präfix `TEST_RUNNER_` an die Tests weiter;
`scripts/test.sh` setzt es vor jede `TRACKING_*`-Variable. `TRACKING_SEEDS=1,2,3` wählt die Seeds
des Berichts (`testReport`; ein Debug-Build erstellt ihn nur, wenn sie gesetzt ist),
`TRACKING_SCENARIOS` die Szenarien, `TRACKING_REPORT=<datei>` schreibt den Bericht als JSON (mit
absolutem Pfad); die übrigen Variablen sind oben in `TrackingBenchTests.swift` beschrieben. Der
Bericht ist eine Tabelle mit einer Zeile pro Szenario und Seed: die Punktzahl (0 bis 100), die
falsch platzierten Block × Anzeigebilder (wie viele höchstens auf einmal, die längste Folge, das
erste), wie viel des ruhenden und des bewegten Textes abgedeckt war, die Latenz, Lagefehler und
Zittern, Flackern und halb gelesene Übersetzungen und was es gekostet hat (Lesedurchgänge, gelesene
Fläche, Übersetzungsanfragen und gezeichnete Texte, jeweils gegen ihr Budget); danach die
mittlere Punktzahl pro Szenario und insgesamt. Wie die Punktzahl entsteht, steht oben in
`TrackingBench.swift`: Eine falsch platzierte Übersetzung wiegt weit mehr als eine fehlende.

Eine Änderung am Tracker kommt mit einem Unit-Test des Falls, den sie löst (in den
`OverlayTracker*Tests` von `MirrorActTests/TextCore`), besteht alle Regressionstests des Prüfstands
im Release-Build und zeigt den Bericht über dieselben Seeds vorher und nachher: Kein Szenario darf
mehr falsch platzierte Bilder bekommen oder Punkte verlieren, ohne dass die Änderung einen Grund
dafür nennt. Eine Grenze des Prüfstands wird erst angehoben, wenn die Ereignisse angesehen sind,
die der fehlgeschlagene Test auflistet. `TrackingParityTests` schreibt Prüfsummen dessen, was der
Tracker in einigen Szenarien getan hat, in die Datei, die `TRACKING_PARITY` nennt; der Vergleich
zweier solcher Dateien, von vor und nach einer Änderung oder aus einer anderen MirrorAct-App mit
demselben Kern, zeigt, ob sich sein Verhalten geändert hat.

### «Übersetzen» an einem gespiegelten Telefon ausprobieren

Im Debug-Build steuert die Distributed Notification `io.github.sopitz.MirrorAct.android-test` ein
gespiegeltes Android-Telefon oder einen Emulator ohne Klicken; die Befehle stehen oben in
`MirrorAct/Android/AndroidDebug.swift`, und `device=<serial>` wählt das Fenster. Aus der Shell
lässt sie sich so senden: dies als `post.swift` sichern und etwa
`swift post.swift cmd=translate on=1 device=<serial>` ausführen:

```swift
import Foundation
var info: [String: String] = [:]
for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { info[parts[0]] = parts[1] }
}
DistributedNotificationCenter.default().postNotificationName(
    .init("io.github.sopitz.MirrorAct.android-test"), object: nil, userInfo: info, deliverImmediately: true)
```

Für den Text auf dem Bildschirm gibt es `cmd=translate on=1|0`, `cmd=copytext`, `cmd=translator`
(schreibt den Zustand des Übersetzens ins Log), `cmd=dump path=<ordner>` (ein Bild, wie gesendet
und wie gezeigt, und was der Übersetzer hineinzeichnet), `cmd=textsettings path=<datei.png>` und
`cmd=setting key=… value=…` (ändert eine Einstellung, während die App läuft, und stellt den
gespeicherten Wert danach wieder her). Mit eingeschaltetem «Übersetzen» kommt ein Debug-Build dem
Videostrom nicht nach, weil das Nachführen ohne Optimierung um ein Vielfaches langsamer ist; um die
Funktion so auszuprobieren, mit `scripts/build.sh --debug --no-install SWIFT_OPTIMIZATION_LEVEL=-O`
bauen (die App liegt dann in
`~/Library/Caches/MirrorAct/DerivedData/Build/Products/Debug/MirrorAct.app`).

## Screenshots

Die Bilder in `docs/` zeichnet die App selbst aus ihren echten Ansichten, im Debug-Build
(`scripts/build.sh --debug` installiert ihn nach `~/Applications/MirrorAct.app`):

- `~/Applications/MirrorAct.app/Contents/MacOS/MirrorAct --showcase <ordner>` schreibt
  `mirror.png`, `start-window.png`, `editor.png` und `framed.png` mit einem Testbild auf dem Gerät
  und beendet sich;
- beim Spiegeln schreibt die Distributed Notification `io.github.sopitz.MirrorAct.android-test` mit
  `cmd=showcase device=<serial> path=<ordner>` (gesendet wie oben gezeigt) dieselben Bilder aus
  genau diesem Fenster, mit dem live gespiegelten Bild auf dem Gerät. (Die Notification
  `io.github.sopitz.MirrorAct.showcase` mit `dir=<ordner>` tut dasselbe für das vorderste
  Spiegelfenster; besser das Gerät nennen, damit kein anderes Fenster mit privaten Inhalten
  genommen wird.)

Das Bild eines übersetzten Bildschirms (`translate.jpg`) ist das Spiegelfenster-Bild einer Sitzung,
in der «Übersetzen» an ist (zuerst `cmd=translate on=1 device=<serial>`, und warten, bis der
Bildschirm übersetzt ist): Das Gerät zeigt dann die Übersetzungen, und die Werkzeugleiste zeigt
«Übersetzen» als eingeschaltet; das dabei geschriebene `mirror.png` wird zu `docs/translate.jpg`.
Die Bilder werden mit 2 Pixeln pro Punkt gezeichnet, welche Bildschirme auch angeschlossen sind
(`MirrorAct/App/Showcase.swift`); danach in JPEG mit 1600 px Breite umwandeln, etwa mit
`sips -s format jpeg --resampleWidth 1600 mirror.png --out docs/mirror.jpg`. Keine nachgebauten
oder retuschierten Bilder.

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
