// SPDX-License-Identifier: GPL-3.0-or-later
// Frame format between mirroract-airplay and the calling app (description: README.md).
// Every frame starts with an 8-byte header, little-endian:
//   uint32 length    payload bytes
//   uint8  type      MB_FRAME_* (stdout) or MB_COMMAND_* (stdin)
//   uint8  flags     type-dependent (VIDEO: codec, AUDIO: compression type, LOG: level)
//   uint16 reserved  0
// followed by the payload.

#ifndef MB_HELPER_PROTOCOL_H
#define MB_HELPER_PROTOCOL_H

#define MB_HELPER_HEADER_SIZE 8

/* Frames from the helper to the app (stdout) */
enum {
    MB_FRAME_VIDEO = 1,            /* one Annex B access unit; flags bit 0 = HEVC */
    MB_FRAME_AUDIO = 2,            /* one audio packet; flags = compression type (8 = AAC-ELD, 2 = ALAC) */
    MB_FRAME_CLIENT = 3,           /* JSON {"deviceId","model","name"} */
    MB_FRAME_CONNECTIONS = 4,      /* int32 open connections */
    MB_FRAME_VIDEO_SIZE = 5,       /* 4 × float32: source width, source height, width, height */
    MB_FRAME_VIDEO_RESET = 6,      /* empty: reset the decoder, wait for a keyframe */
    MB_FRAME_CONNECTION_LOST = 7,  /* empty: connection gone, receiver ready again */
    MB_FRAME_PIN = 8,              /* UTF-8: code to display */
    MB_FRAME_VOLUME = 9,           /* float32 dB (−30…0, −144 = muted) */
    MB_FRAME_LOG = 10,             /* UTF-8 text; flags = level (3 = error … 7 = debug) */
    MB_FRAME_STARTED = 11,         /* JSON {"name","port"}, once after a successful start */
    MB_FRAME_ERROR = 12            /* JSON {"code","message"} when the start fails; exits afterwards */
};

#define MB_VIDEO_FLAG_HEVC 0x01

/* Commands from the app to the helper (stdin); end of file on stdin acts like STOP */
enum {
    MB_COMMAND_DISCONNECT = 1,     /* disconnect the connected device, receiver stays ready */
    MB_COMMAND_STOP = 2            /* stop the receiver, process exits with 0 */
};

#endif
