// SPDX-License-Identifier: GPL-3.0-or-later
// Rahmenformat zwischen mirroract-airplay und der aufrufenden App (Beschreibung: README.md).
// Jeder Rahmen beginnt mit 8 Byte Kopf, Little-Endian:
//   uint32 length    Bytes der Nutzlast
//   uint8  type      MB_FRAME_* (stdout) bzw. MB_COMMAND_* (stdin)
//   uint8  flags     typabhängig (VIDEO: Codec, AUDIO: Kompressionstyp, LOG: Stufe)
//   uint16 reserved  0
// danach die Nutzlast.

#ifndef MB_HELPER_PROTOCOL_H
#define MB_HELPER_PROTOCOL_H

#define MB_HELPER_HEADER_SIZE 8

/* Rahmen vom Helfer an die App (stdout) */
enum {
    MB_FRAME_VIDEO = 1,            /* eine Annex-B-Zugriffseinheit; flags Bit 0 = HEVC */
    MB_FRAME_AUDIO = 2,            /* ein Audiopaket; flags = Kompressionstyp (8 = AAC-ELD, 2 = ALAC) */
    MB_FRAME_CLIENT = 3,           /* JSON {"deviceId","model","name"} */
    MB_FRAME_CONNECTIONS = 4,      /* int32 offene Verbindungen */
    MB_FRAME_VIDEO_SIZE = 5,       /* 4 × float32: Quellbreite, Quellhöhe, Breite, Höhe */
    MB_FRAME_VIDEO_RESET = 6,      /* leer: Decoder zurücksetzen, auf Keyframe warten */
    MB_FRAME_CONNECTION_LOST = 7,  /* leer: Verbindung weg, Empfänger wieder bereit */
    MB_FRAME_PIN = 8,              /* UTF-8: anzuzeigender Code */
    MB_FRAME_VOLUME = 9,           /* float32 dB (−30…0, −144 = stumm) */
    MB_FRAME_LOG = 10,             /* UTF-8 Text; flags = Stufe (3 = Fehler … 7 = Debug) */
    MB_FRAME_STARTED = 11,         /* JSON {"name","port"}, einmal nach erfolgreichem Start */
    MB_FRAME_ERROR = 12            /* JSON {"code","message"}, wenn der Start scheitert; danach Ende */
};

#define MB_VIDEO_FLAG_HEVC 0x01

/* Befehle von der App an den Helfer (stdin); Dateiende auf stdin wirkt wie STOP */
enum {
    MB_COMMAND_DISCONNECT = 1,     /* verbundenes Gerät trennen, Empfänger bleibt bereit */
    MB_COMMAND_STOP = 2            /* Empfänger beenden, Prozess endet mit 0 */
};

#endif
