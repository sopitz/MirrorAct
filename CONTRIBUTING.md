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
downloads the scrcpy server for Android (pinned version, checked against its SHA-256),
generates the Xcode project with XcodeGen, builds the app and installs it to
`~/Applications/MirrorAct.app`. `--debug` builds the debug configuration, `--no-install` skips the
installation.

By default the app is signed ad hoc. macOS then asks for camera access again after every build.
To keep the permission, sign with your own certificate: copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and enter your signing identity and team. The same team signs the agent
for controlling an iPhone or iPad (`scripts/build-agent.sh`, see the
[README](README.md#controlling-an-iphone-or-ipad)).

## How it works

| Folder | Content |
|---|---|
| `MirrorAct/AirPlay` | `airplay_bridge.c` – thin C layer over UxPlay's AirPlay library (Bonjour, heartbeat, restart), `AirPlayReceiver` |
| `MirrorAct/Android` | `ADB` (adb, device list, Wi-Fi), `ScrcpyClient` (scrcpy protocol: video, audio, control sockets), `AndroidControl` (mouse and keyboard as scrcpy control messages) |
| `MirrorAct/Audio` | `AACAudioPlayer` (AAC-ELD from AirPlay, AAC-LC from Android, without buffering) |
| `MirrorAct/Video` | `AnnexBDecoder` (H.264/HEVC → VideoToolbox), `FrameSink` / `VideoDisplayView` (AVSampleBufferDisplayLayer) |
| `MirrorAct/USB` | device discovery and capture (`AVCaptureDevice`, `.muxed`) |
| `MirrorAct/Frame` | device profiles, frame geometry, `FrameStyle`, `SceneRenderer` (Core Image; shared by screenshots, recordings and the editor) |
| `MirrorAct/Mirror` | mirror window, tool rail, style panel, presentation, `DeviceControl` (interface for controlling a device) |
| `MirrorAct/Control` | iPhone/iPad control: `IOSControl` (gestures, keyboard, start of the agent via `xcodebuild`), `AgentRunners` (running agents, kept for a few minutes), `AgentConnection` (HTTP to WebDriverAgent), `USBMux` (usbmuxd) |
| `MirrorAct/Recording` | `MirrorRecorder` (AVAssetWriter, host time, variable frame rate) |
| `MirrorAct/Editor` | editor, `DuoRenderer`, `VideoFramer` (AVVideoComposition + export) |
| `MirrorAct/Intents` | App Intents for Shortcuts |
| `MirrorAct/Launcher` | start window, settings |
| `MirrorAct/Localization` | String Catalogs (English source, German translation), Info.plist and Siri phrases |
| `Agent` | MirrorAct's additional commands for WebDriverAgent (fast touches), compiled in by `scripts/build-agent.sh` |
| `scripts` | build, agent, release and icon scripts |

## Test without a device

Without a device you can check the rendering:

```bash
~/Applications/MirrorAct.app/Contents/MacOS/MirrorAct --render-test /tmp/mirroract-render
```

This writes frames, styles, duo poses and UI parts as PNG files, records two short test videos
(with rotation and with AAC-ELD audio as sent over AirPlay) and frames one of them like the editor.

## Screenshots

The pictures in `docs/` are drawn by the app itself from its real views: in a debug build with
`MirrorAct --showcase <folder>`, or while mirroring via the distributed notification
`io.github.sopitz.MirrorAct.showcase`; the device screen is the live mirrored frame. No mocked-up
or retouched images.

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
