# mirroract-airplay – the AirPlay receiver as a separate program

`mirroract-airplay` wraps MirrorAct's AirPlay receiver (`MirrorAct/AirPlay/airplay_bridge.c` on top
of the [UxPlay](https://github.com/FDH2/UxPlay) library) in a console program. An app starts it,
reads video, audio and events from its stdout and writes commands to its stdin. The Mac app links
the bridge directly; the helper exists so that other programs can use the receiver as a separate
process over a pipe – for example a port of MirrorAct to a platform where the app itself cannot
be GPL code. Like the rest of this repository it is licensed GPL-3.0-or-later.

It builds on macOS, Linux and Windows (MinGW/MSYS2 UCRT64). On macOS it uses Bonjour; on Linux and
Windows it uses UxPlay's own mDNS responder (`lib/mdnsd`), so nothing has to be installed on the
machine that runs it. On Windows the helper must be allowed through the firewall (it receives
UDP 5353 for discovery and the AirPlay ports), and the network must be a private profile.

## Build

macOS (same libraries as the app; `scripts/bootstrap-uxplay.sh` must have run, see
[CONTRIBUTING.md](../CONTRIBUTING.md)):

```bash
cmake -S AirPlayHelper -B build/airplay-helper -DCMAKE_BUILD_TYPE=Release
cmake --build build/airplay-helper
```

Linux (`libplist-dev`, `libssl-dev`, `pkg-config`) and Windows (MSYS2 UCRT64 with
`mingw-w64-ucrt-x86_64-{gcc,cmake,ninja,openssl,libplist,pkg-config}`): fetch UxPlay at the commit
pinned in `scripts/bootstrap-uxplay.sh` into `Vendor/UxPlay`, then run the same two commands. The
CMake file builds UxPlay's `lib`, `lib/playfair`, `lib/llhttp` and `lib/mdnsd` from source; on
Windows the result is linked statically and depends only on system DLLs.
`.github/workflows/airplay-helper.yml` does exactly this on all three platforms.

## Command line

```
mirroract-airplay --name "MirrorAct" --device-id AA:BB:CC:DD:EE:FF --keyfile <path>
                  [--height 2160] [--fps 60] [--hevc] [--pin 1234] [--p2p] [--log-level 6]
```

| Option | Meaning |
|---|---|
| `--name` | name shown in Screen Mirroring on the iPhone or iPad |
| `--device-id` | ID of the receiver in MAC format; use a locally administered address, not the machine's MAC |
| `--keyfile` | PEM file with the receiver's key; created when missing |
| `--height` | stream height requested from the device (width = height × 16/9), 240–4320, default 2160 |
| `--fps` | maximum frame rate, 1–120, default 60 |
| `--hevc` | offer HEVC in addition to H.264 |
| `--pin` | fixed code (1–9999) the device has to enter (legacy pairing) |
| `--p2p` | also offer the receiver over AWDL (macOS only, ignored elsewhere); needs `--pin` |
| `--log-level` | 0 (emergency) to 8 (debug incl. packet data), default 6; LOG frames carry the level |

stdout must be a pipe, not a terminal. Exit code 0 after `STOP`, end of stdin, SIGINT or SIGTERM;
2 for invalid arguments; otherwise the (positive) bridge error code that was also sent in the
`ERROR` frame. When the parent process dies, the helper exits (end of stdin, broken pipe).

## Protocol

Everything on stdout and stdin is binary with the same 8-byte header, little-endian; stdout and
stdin are switched to binary mode on Windows:

```
uint32 length      bytes of payload
uint8  type
uint8  flags
uint16 reserved    0
payload[length]
```

Frames from the helper (stdout):

| type | name | flags | payload |
|---|---|---|---|
| 1 | VIDEO | bit 0 = HEVC | one Annex-B access unit (start codes; parameter sets precede key frames) |
| 2 | AUDIO | compression type (8 = AAC-ELD, 2 = ALAC) | one audio packet as the bridge delivers it |
| 3 | CLIENT | – | JSON `{"deviceId":"…","model":"iPhone15,2","name":"…"}` |
| 4 | CONNECTIONS | – | int32 open connections |
| 5 | VIDEO_SIZE | – | 4 × float32: source width, source height, width, height |
| 6 | VIDEO_RESET | – | empty: the decoder must reset and wait for a key frame |
| 7 | CONNECTION_LOST | – | empty: the device is gone, the receiver is ready again |
| 8 | PIN | – | UTF-8 code to show |
| 9 | VOLUME | – | float32 dB (−30…0, −144 = mute) |
| 10 | LOG | level (3 = error … 7 = debug) | UTF-8 text |
| 11 | STARTED | – | JSON `{"name":"…","port":7100}`, sent once after the receiver started |
| 12 | ERROR | – | JSON `{"code":-3,"message":"…"}`, sent if starting failed; the helper then exits |

A client should wait for `STARTED` or `ERROR` after launching the helper. Video and audio
payloads are passed through unchanged; AAC-ELD audio is 44.1 kHz, 480 frames per packet, with the
AudioSpecificConfig `F8 E8 50 00`. All frames are written completely and never interleaved.

Commands to the helper (stdin), same header, no payload:

| type | name | effect |
|---|---|---|
| 1 | DISCONNECT | disconnects the device; the receiver stays ready |
| 2 | STOP | stops the receiver; the helper exits with 0 |

End of stdin has the same effect as `STOP`. The constants are in `helper_protocol.h`.

## Files

| File | Content |
|---|---|
| `main.c` | argument parsing, frame writer (mutex, complete writes), stdin command thread, bridge callbacks |
| `helper_protocol.h` | frame and command types |
| `CMakeLists.txt` | build for macOS, Linux and Windows |
| `../MirrorAct/AirPlay/airplay_bridge.c` | the receiver itself, shared with the Mac app |
