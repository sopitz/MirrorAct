# Contributing to MirrorAct

*Deutsch: [CONTRIBUTING.de.md](CONTRIBUTING.de.md)*

This page is about working on MirrorAct itself. To install and use the app, see the
[README](README.md).

Bug reports and ideas go to [Issues](https://github.com/sopitz/MirrorAct/issues), changes come as
pull requests to `develop` (see [Branches and pull requests](#branches-and-pull-requests)).

## Build from source

You need:

- macOS 15 or later (tested on Apple silicon)
- Xcode 16 or later
- [Homebrew](https://brew.sh) packages:

```bash
brew install xcodegen cmake pkgconf libplist openssl@3 gstreamer
```

GStreamer is only needed because UxPlay's CMake looks for it while configuring; MirrorAct does not
use it. OpenSSL and libplist are linked statically, so the finished app does not depend on Homebrew.

Then:

```bash
scripts/build.sh
```

The script fetches UxPlay at a pinned commit into `Vendor/`, builds only its AirPlay library,
downloads the scrcpy server for Android (pinned version, checked against its SHA-256), generates
the Xcode project with XcodeGen, builds the app and installs it to `~/Applications/MirrorAct.app`.
`--debug` builds the debug configuration, `--no-install` skips the installation, and `NAME=VALUE`
arguments are passed on to xcodebuild as build settings; `MIRRORACT_DERIVED` chooses another build
folder than `~/Library/Caches/MirrorAct/DerivedData`.

By default the app is signed ad hoc. macOS then asks for camera access again after every build.
To keep the permission, sign with your own certificate: copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and enter your signing identity and team. The same team signs the agent
for controlling an iPhone or iPad (`scripts/build-agent.sh`, see the
[README](README.md#controlling-an-iphone-or-ipad)).

## How it works

| Folder | Content |
|---|---|
| `MirrorAct/AirPlay` | `airplay_bridge.c` – thin C layer over UxPlay's AirPlay library (Bonjour or UxPlay's own mDNS responder, heartbeat, restart; builds on macOS, Linux and Windows), `AirPlayReceiver` |
| `AirPlayHelper` | `mirroract-airplay` – the same receiver as a separate program for other apps (frames over stdout, commands over stdin; protocol and build in [`AirPlayHelper/README.md`](AirPlayHelper/README.md)); built by `.github/workflows/airplay-helper.yml` for macOS, Windows and Linux |
| `MirrorAct/Android` | `ADB` (adb, device list, Wi-Fi), `ScrcpyClient` (scrcpy protocol: video, audio, control sockets), `AndroidControl` (mouse and keyboard as scrcpy control messages) |
| `MirrorAct/Audio` | `AACAudioPlayer` (AAC-ELD from AirPlay, AAC-LC from Android, without buffering) |
| `MirrorAct/Video` | `AnnexBDecoder` (H.264/HEVC → VideoToolbox), `FrameSink` / `VideoDisplayView` (AVSampleBufferDisplayLayer) |
| `MirrorAct/USB` | device discovery and capture (`AVCaptureDevice`, `.muxed`) |
| `MirrorAct/Frame` | device profiles (`DeviceProfile` reads `Shared/DeviceProfiles.json`), frame geometry, `FrameStyle`, `SceneRenderer` (Core Image; shared by screenshots, recordings and the editor) |
| `MirrorAct/Mirror` | mirror window, tool rail, style panel, presentation, `DeviceControl` (interface for controlling a device) |
| `MirrorAct/Control` | iPhone/iPad control: `IOSControl` (gestures, keyboard, start of the agent via `xcodebuild`), `AgentRunners` (running agents, kept for a few minutes, stopped when a wireless connection ends), `AgentConnection` (HTTP to WebDriverAgent), `USBMux` (usbmuxd) |
| `MirrorAct/Recording` | `MirrorRecorder` (AVAssetWriter, host time, variable frame rate) |
| `MirrorAct/Text` | text on the screen: `TextRecognizer` (Vision; `LeadingMark` leaves out an icon read as a character in front of a line, `LineTone` measures how bright and how colored the letters of a line are), `FramePixels` (thumbnails and colors straight from the frame), `ScreenTranslator` (a `FrameProcessor` in the `FrameSink`: reads, translates and draws beside the frames), `TranslationCompositor` with `BlockPlacement`, `BlockTextMask` and `ChromaPlane` (draws the translations into a copy of the frame, in its own pixel format and in the size of the original text), `TranslationEngine` (the interface every engine implements), `TranslationEngines` (picks the engine the settings name), `AppleTranslationEngine` (Apple's Translation framework; sorts the texts by language with `LanguageMatching` and sends the short labels of a screen together, `AppleTranslationJoining`; its sessions live in a hidden host window, `AppleTranslationHost`), `LLMTranslationEngine` (language model services with the user's key from `KeychainStore`) |
| `MirrorAct/Text/Core` | the part that uses Foundation alone (and CoreGraphics where it is available), so that other MirrorAct apps can use it: `TextLayout` (lines into paragraphs; leaves out the status bar and, for Translate, the icons of rows read as letters, keeps the title of a row apart from its summary by the brightness of their letters, marks lines that are cut off), `TextTracking` (the values the recognition, the tracker and the drawing exchange), `LumaImage` (thumbnails), `OverlayTracker` with `MotionEstimator`, `ReadingPlan` and `BlockPatch` (keeps translations on their text while the content moves, and decides what is read and what is sent for translation when), `YCbCrColor`, `LLMProvider`/`LLMWire`/`TranslationPrompt` (what is sent to a service and how its replies are read, without the network), `LanguageMatching` (the language of each text and of the screen, and when macOS may be asked for a language). Its rules are written in its comments, and a change to a rule is described there. Its tests are in `MirrorActTests/TextCore` (with a simulator of scrolling phone screens and a bench, `Tracking*.swift`) |
| `MirrorAct/Editor` | editor, `DuoRenderer`, `VideoFramer` (AVVideoComposition + export) |
| `MirrorAct/Intents` | App Intents for Shortcuts |
| `MirrorAct/Launcher` | start window, settings |
| `MirrorAct/Localization` | String Catalogs (English source, German translation), Info.plist and Siri phrases |
| `Shared` | `DeviceProfiles.json` – the device shapes (notch, Dynamic Island, camera hole, corners, bezel, buttons, points, ppi; for a foldable also the inner screen, under `unfolded`) for all MirrorAct apps; bundled into the app as a resource; Swift tools compiled outside the app (e.g. with swiftc) can point `MIRRORACT_DEVICE_PROFILES` at it; other MirrorAct apps read the same file. `scripts/build.sh` checks it as strict JSON (no trailing commas), and the app stops at launch on unknown keys or inconsistent entries. A name in it that needs a translation gets a manual entry in `MirrorAct/Localization/Localizable.xcstrings`, because the compiler cannot extract it |
| `Agent` | MirrorAct's additional commands for WebDriverAgent (fast touches), compiled in by `scripts/build-agent.sh` |
| `MirrorActTests` | tests, run inside a debug build of the app (`scripts/test.sh`) |
| `scripts` | build, test, agent, release, icon and device profile check scripts |

### Text and Translate

"Text" reads the current frame with `TextRecognizer` and copies `TextLayout.plainText`, which keeps
everything but the status bar, lines cut off at the top or bottom edge and garbage
(`TextLayout.Purpose.copying`).

While "Translate" is on, `ScreenTranslator` is the `FrameProcessor` of the window's `FrameSink`,
and every frame passes through it:

1. `FramePixels` makes a thumbnail, and `OverlayTracker.advance` follows the known paragraphs to
   it (`MotionEstimator` tells what stayed, moved or changed) and says where each is drawn and
   whether a region has to be read.
2. Beside the frames, `TextRecognizer` reads that region of the frame as the device sent it,
   `TextLayout.content` (`.translating`) leaves out the status bar and the icons of rows, and
   `TextLayout.blocks` forms the paragraphs, never across a known edge of a scrolling area.
   `OverlayTracker.finishRecognition` takes them in; `ReadingPlan` keeps what still has to be
   read and when (what scrolled into view at once, what changed once it rests, a cut-off line once
   all of it shows).
3. The tracker decides which texts go to the engine when (`textsAwaitingTranslation`, at most 40
   in a request). An engine that `prefersSettledText` (a language model service) waits up to
   1.5 s for the picture to rest first. A text that failed is offered again after 5, 10, 20 and
   40 s and then every 60 s; the engine of a service waits the same steps for the service as a
   whole (`TranslationWait`), so that neither wait adds to the other.
4. `TranslationCompositor.prepare` sets the translations with Core Text off the frame thread
   (`BlockTextMask`), and `compose` draws them into a copy of each frame, which the window,
   screenshots and recordings show.

Each time "Translate" is turned on, or its settings change, it starts over with the engine
`TranslationEngines` makes from the settings.

The rules of the core, as its comments state them: it uses Foundation alone (and CoreGraphics where
it is available), so that other MirrorAct apps can use it. `OverlayTracker` is not thread safe (the
caller makes sure that calls never overlap), has no clock and no randomness (the same calls give
the same results; times are seconds of any steady clock), and measures a block's position against
the pixels it was read from, never adding it up from frame to frame. `LLMWire` holds values and
pure functions only, so that the same code and tests describe what goes to a service. Rectangles
between the parts are in frame pixels with the origin at the top left; those of `TextLayout` in 0…1
of the picture. `TextLayout` keeps a row's title apart from its summary only where the recognizer
measured `RecognizedLine.tone`; without it that rule does nothing.

## Test without a device

Without a device you can check the rendering:

```bash
~/Applications/MirrorAct.app/Contents/MacOS/MirrorAct --render-test /tmp/mirroract-render
```

This writes frames (including the iPhone Duo closed and open), styles, duo poses and UI parts as
PNG files, records two short test videos (with rotation and with AAC-ELD audio as sent over
AirPlay) and frames one of them like the editor.

After changing `Shared/DeviceProfiles.json`, `scripts/test-device-profiles.sh` checks that the
table is valid, that broken entries (misspelled keys, wrong pixel sizes, unknown cutouts, buttons
off their edge) are rejected with a clear message, and that the iPhone Duo's closed and open
screens are told apart by the image size.

## Tests

```bash
scripts/test.sh
```

Runs `MirrorActTests` in a debug build of the app, which is the tests' host; `scripts/test.sh
PresentationTests` runs a single class (also `Class/testName`, and several names at once). The
script fetches `Vendor/` and the scrcpy server where they are missing, generates the project,
builds into `~/Library/Caches/MirrorAct/DerivedData` (`MIRRORACT_DERIVED` chooses another
folder), writes the whole output to `test.log` there and prints the failures, or the count of
tests run. It hands every `TRACKING_*` variable on to the tests (see the tracking bench below).

Running as the host, the app starts without the AirPlay receiver, USB and adb, keeps its settings
apart from yours (domain `io.github.sopitz.MirrorAct.tests`, emptied when a run starts and when it
ends; API keys under a keychain name of their own) and logs only to the system log. Two test runs
at the same time share that domain and disturb each other: run one at a time.

Some tests open real windows. `PresentationTests` presents a mirror window, activates the app and
goes full screen; `StylePanelAppearanceTests` presents a mirror window and activates the app;
`TextSettingsViewTests` shows the Text settings in a window and makes it key; `OnTopTests` presents
a mirror window, activates the app, lets the window float above other windows and on every desktop,
and goes full screen once. (`SettingsLayoutTests` and `ShowcaseTests` place their windows outside
the screens; `AppleTranslationEngineTests` moves an almost transparent window, which takes no
clicks and no keys, onto the screen for a moment.) To work on the Mac meanwhile, leave those four
out: run the classes you need by name, or call xcodebuild as the script does, with `-skip-testing`:

```bash
caffeinate -d -i xcodebuild -project MirrorAct.xcodeproj -scheme MirrorAct -configuration Debug \
  -derivedDataPath ~/Library/Caches/MirrorAct/DerivedData HOMEBREW_PREFIX=$(brew --prefix) \
  -skip-testing:MirrorActTests/PresentationTests \
  -skip-testing:MirrorActTests/StylePanelAppearanceTests \
  -skip-testing:MirrorActTests/TextSettingsViewTests \
  -skip-testing:MirrorActTests/OnTopTests test
```

The suite needs the display awake: while it sleeps, the animations of those windows never end, each
holds a thread, and once no thread is left a test that reads text waits in Vision forever.
`scripts/test.sh` therefore wakes the display and keeps it awake while the tests run
(`caffeinate`).

A test that draws with AppKit must not depend on the displays attached: `NSImage`, SF Symbols
above all, lays an image out on the pixels of the main display even when it draws into a bitmap of
its own. Give such a test explicit geometry (`LeadingMarkTests.SettingsRows` makes each symbol a
hundred times as large and draws it at its exact size), a fixed appearance and font smoothing set
explicitly, and see that it passes with a display at scale 1 as well as at scale 2.

The tests of "Text" and "Translate" need no device and no network: `TextRecognizerTests`,
`LeadingMarkTests`, `ScreenTranslatorTests` and `ScreenTranslatorCutOffTests` (synthetic frames,
real Vision), `ScreenTranslatorRetryTests` (minutes of a failing service, with a clock of the
test's own), `TranslationCompositorTests`, `ChromaPlaneTests`, `AppleTranslationEngineTests` (a
stand-in answers in place of macOS, so macOS is never asked to translate or to download a
language), `LLMTranslationEngineTests`, `LLMSessionTests` and `LocalServiceWaitTests` (a stand-in
for the network), `TranslationStatusNoticeTests`, `TextSettingsViewTests`,
`TextSettingsLanguageMenuTests`, `MirrorSessionTests` (Translate when the device goes away or the
app moves the window to another connection), `ShowcaseTests` (the pictures, with Translate as the
mirrored session has it) and `FrameSinkTests` (the translated frame is shown and recorded); the
tests of the core are in `MirrorActTests/TextCore` (`OverlayTrackerContractTests` holds what every
tracker must do).

### The tracking bench

`TrackingBenchTests` plays the tracker through scenarios of a simulated phone screen
(`TrackingScenarios.swift`: scrolling, flicks, bars, banners, alerts, a keyboard, new screens, a
video, and strips that glide sideways by themselves, such as a carousel and a ticker) and scores
what it draws against the truth of the simulation (`TrackingBench.swift`). Each scenario has a
regression test on seed 1 with a minimum score and a maximum number of misplaced frames, and a
traced seed can have a test of its own (`testAlikeRowsSeed19` …). The bench is deterministic: a
test that fails means the tracker got worse, or the bench changed.

A debug build plays it fifty to a hundred times slower than a release build, so `scripts/test.sh`
plays only a few scenarios and skips the rest on purpose; the skipped tests say so.
`TRACKING_ALL=1 TRACKING_SEEDS=1 scripts/test.sh TrackingBenchTests` plays all of them in a debug
build, which takes close to an hour. In a release build, after `scripts/build.sh --no-install`
(which fetches `Vendor/` and generates the project), the whole bench and its report over seeds 1
to 3 take a few minutes:

```bash
TEST_RUNNER_TRACKING_REPORT=/tmp/tracking.json xcodebuild -project MirrorAct.xcodeproj \
  -scheme MirrorAct -configuration Release ENABLE_TESTABILITY=YES HOMEBREW_PREFIX=$(brew --prefix) \
  -only-testing:MirrorActTests/TrackingBenchTests test
```

xcodebuild hands a variable to the tests only with the prefix `TEST_RUNNER_`; `scripts/test.sh`
adds it to every `TRACKING_*` variable. `TRACKING_SEEDS=1,2,3` chooses the seeds of the report
(`testReport`; a debug build makes it only when this is set), `TRACKING_SCENARIOS` the scenarios,
`TRACKING_REPORT=<file>` writes the report as JSON (give an absolute path); the other variables
are described at the top of `TrackingBenchTests.swift`. The report is a table with a line per
scenario and seed: the score (0 to 100), the misplaced block × display frames (the most at once,
the longest run, the first), how much of the text at rest and of moving text was covered, the
latency, the alignment error and jitter, flickers and half-read translations, and what it cost
(recognition passes, area read, translation requests and texts drawn, each against its budget);
then the mean score per scenario and overall. How the score is made is described at the top of
`TrackingBench.swift`: a misplaced translation weighs far more than a missing one.

A change to the tracker comes with a unit test of the case it settles (in the
`OverlayTracker*Tests` of `MirrorActTests/TextCore`), passes all regression tests of the bench in a
release build, and shows the report over the same seeds before and after: no scenario may get more
misplaced frames or lose score without a reason that the change states. A limit of the bench is
raised only after the events the failing test lists were looked at. `TrackingParityTests` writes
checksums of what the tracker did in a few scenarios to the file `TRACKING_PARITY` names; comparing
two such files, from before and after a change or from another MirrorAct app with the same core,
shows whether its behavior changed.

### Trying Translate on a mirrored phone

In a debug build, the distributed notification `io.github.sopitz.MirrorAct.android-test` drives a
mirrored Android phone or emulator without clicking; the commands are listed at the top of
`MirrorAct/Android/AndroidDebug.swift`, and `device=<serial>` chooses the window. To post one from
the shell, save this as `post.swift` and run, for example,
`swift post.swift cmd=translate on=1 device=<serial>`:

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

For the text on the screen there are `cmd=translate on=1|0`, `cmd=copytext`, `cmd=translator` (logs
the translator's state), `cmd=dump path=<folder>` (one frame as sent and as shown, and what the
translator draws into it), `cmd=textsettings path=<file.png>` and `cmd=setting key=… value=…`
(changes a setting while the app runs and puts the stored value back afterwards). With "Translate"
on, a debug build falls behind the stream, because the tracker is many times slower without
optimization; to try the feature this way, build with
`scripts/build.sh --debug --no-install SWIFT_OPTIMIZATION_LEVEL=-O` (the app is then in
`~/Library/Caches/MirrorAct/DerivedData/Build/Products/Debug/MirrorAct.app`).

## Screenshots

The pictures in `docs/` are drawn by the app itself from its real views, in a debug build
(`scripts/build.sh --debug` installs it to `~/Applications/MirrorAct.app`):

- `~/Applications/MirrorAct.app/Contents/MacOS/MirrorAct --showcase <folder>` writes `mirror.png`,
  `start-window.png`, `editor.png` and `framed.png` with a test image on the device and quits;
- while mirroring, the distributed notification `io.github.sopitz.MirrorAct.android-test` with
  `cmd=showcase device=<serial> path=<folder>` (posted as shown above) writes the same pictures
  from exactly that window, with the live mirrored frame on the device. (The notification
  `io.github.sopitz.MirrorAct.showcase` with `dir=<folder>` does the same for the frontmost mirror
  window; name the device instead, so that no other window with private content is taken.)

The picture of a translated screen (`translate.jpg`) is the mirror picture of a session whose
"Translate" is on (`cmd=translate on=1 device=<serial>` first, and wait until the screen is
translated): the device then shows the translations, and the tool rail shows "Translate" as on; the
`mirror.png` written then becomes `docs/translate.jpg`. The pictures are drawn at 2 pixels per
point, whatever displays are attached (`MirrorAct/App/Showcase.swift`); convert them to JPEG, 1600
px wide, for example with
`sips -s format jpeg --resampleWidth 1600 mirror.png --out docs/mirror.jpg`. No mocked-up or
retouched images.

Format like the existing ones: JPEG, 1600 px wide; PNG only where transparency is needed. No
private content (messages, contacts, notifications) on the device screen.

## Branches and pull requests

MirrorAct uses git flow: `main` holds the latest release, `develop` the work for the next one.

| Branch | Purpose |
|---|---|
| `main` | Released versions, each tagged `v<version>` |
| `develop` | Next release, target for pull requests |
| `feature/<topic>`, `chore/<topic>` | Branch off `develop`, merge back into `develop` |
| `release/<version>` | Branches off `develop`, merges into `main` and `develop` |
| `hotfix/<version>` | Branches off `main`, merges into `main` and `develop` |

For a pull request:

- one topic per branch, branched off `develop`, pull request to `develop`
- commit messages and pull requests in English, describing the change
- a change to features, usage, requirements, the build or the folder structure updates
  `README.md` and `README.de.md` (or `CONTRIBUTING.md` and `CONTRIBUTING.de.md`) in the same
  branch – same content, each in its language
- a visible change comes with current screenshots in `docs/`: replace pictures that no longer
  match, add new ones for new features and include them in both READMEs with `alt` text in the
  respective language

## Release

For maintainers. A release goes from `develop` to `main` through a `release/<version>` branch:

1. Branch `release/<version>` off `develop`, raise `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` in `project.yml` and open a pull request to `main`.
2. After the merge, tag the merge commit on `main`:
   `git tag -a v<version> -m "MirrorAct <version>"`.
3. From a clean checkout at the tag, run `scripts/release.sh --publish`.
4. Merge `main` back into `develop` with a pull request.

`scripts/release.sh` builds the app for distribution: signed with a Developer ID, notarized by Apple
and packed as `build/release/MirrorAct-<version>.zip`. With `--publish` it also pushes the tag,
creates the GitHub release `v<version>` and updates the cask in
[sopitz/homebrew-tap](https://github.com/sopitz/homebrew-tap). Without `--publish` it only builds
and notarizes.

It needs a "Developer ID Application" certificate in the keychain, the [GitHub CLI](https://cli.github.com)
for `--publish` and, once, a notarytool profile:

```bash
xcrun notarytool store-credentials mirroract-notary --apple-id <Apple ID> --team-id <team>
```

The generated release notes are short; replace them with your own:
`gh release edit v<version> --notes-file <file>`.
