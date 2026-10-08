// SPDX-License-Identifier: GPL-3.0-or-later
// Schmale C-Schnittstelle zwischen der UxPlay-AirPlay-Bibliothek (Vendor/UxPlay/lib)
// und Swift. Es gibt genau einen Empfänger pro Prozess.

#ifndef MB_AIRPLAY_BRIDGE_H
#define MB_AIRPLAY_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    void *ctx;
    /* Annex-B-Videodaten (Startcodes, SPS/PPS bzw. VPS/SPS/PPS vor Keyframes) */
    void (*video)(void *ctx, const uint8_t *data, int32_t length, bool is_h265);
    /* entschlüsselte Audiopakete; compression_type 8 = AAC-ELD (Spiegelung), 2 = ALAC */
    void (*audio)(void *ctx, const uint8_t *data, int32_t length, uint8_t compression_type);
    void (*client)(void *ctx, const char *device_id, const char *model, const char *name);
    void (*connections)(void *ctx, int32_t open_connections);
    void (*video_size)(void *ctx, float source_width, float source_height, float width, float height);
    /* Videostrom neu aufgesetzt (Decoder zurücksetzen, auf Keyframe warten) */
    void (*video_reset)(void *ctx);
    /* Verbindung verloren oder getrennt; Empfänger ist wieder bereit */
    void (*connection_lost)(void *ctx);
    void (*pin)(void *ctx, const char *pin);
    void (*volume)(void *ctx, float volume_db);
    void (*log)(void *ctx, int32_t level, const char *message);
} mb_airplay_callbacks;

typedef struct {
    const char *name;           /* Name in der Bildschirmsynchronisierung */
    const char *device_id;      /* "AA:BB:CC:DD:EE:FF" */
    const char *keyfile;        /* Schlüssel (PEM), wird bei Bedarf angelegt */
    uint16_t width;
    uint16_t height;            /* massgebend für die Auflösung, die das iPhone schickt */
    uint16_t refresh_rate;
    uint16_t max_fps;
    bool h265;
    bool peer_to_peer;          /* zusätzlich über AWDL anbieten (verlangt pin) */
    int32_t pin;                /* 1..9999 fester Code, 0 = ohne Code */
    int32_t log_level;          /* 3 = Fehler ... 7 = Debug */
} mb_airplay_config;

/* 0 bei Erfolg, sonst negativer Fehlercode */
int mb_airplay_start(const mb_airplay_config *config, const mb_airplay_callbacks *callbacks);
/* TCP-Port des laufenden Empfängers, 0 wenn nicht gestartet */
uint16_t mb_airplay_port(void);
void mb_airplay_stop(void);
/* trennt das verbundene Gerät; der Empfänger bleibt bereit */
void mb_airplay_disconnect(void);

#endif
