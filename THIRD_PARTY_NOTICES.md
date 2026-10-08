# Third-party notices

MirrorAct is licensed under the GNU General Public License v3.0 or later (see `LICENSE`).
It builds on the following third-party components. Their source code is not part of this
repository; `scripts/bootstrap-uxplay.sh` fetches UxPlay at a pinned commit, and OpenSSL and
libplist come from Homebrew. A distributed build of MirrorAct contains these components.

| Component | Used for | License |
|---|---|---|
| [UxPlay](https://github.com/FDH2/UxPlay) `lib/` (commit `3dbf7ce`) | AirPlay screen mirroring receiver (RAOP/AirPlay protocol, pairing, mirroring stream) | GPL-3.0-or-later as a whole; individual files LGPL-2.1-or-later (derived from shairplay/RPiPlay), `lib/crypto.c` GPL-3.0-or-later |
| UxPlay `lib/playfair` | FairPlay handshake for screen mirroring | GPL-3.0 |
| UxPlay `lib/llhttp` (llhttp by Fedor Indutny) | HTTP parsing | MIT |
| UxPlay `lib/srp.c` | SRP pairing | MIT |
| [OpenSSL](https://www.openssl.org) 3.x (statically linked) | Cryptography for AirPlay pairing | Apache-2.0 |
| [libplist](https://github.com/libimobiledevice/libplist) (statically linked) | Property lists in the AirPlay protocol | LGPL-2.1-or-later |

Apple system frameworks (AVFoundation, CoreMediaIO, VideoToolbox, Core Image, SwiftUI, AppKit,
App Intents) are used as system libraries.

The device frames are drawn by MirrorAct itself; no Apple artwork is included.
