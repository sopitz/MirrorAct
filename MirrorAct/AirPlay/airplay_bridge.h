// SPDX-License-Identifier: GPL-3.0-or-later
// Thin C interface between the UxPlay AirPlay library (Vendor/UxPlay/lib)
// and Swift. There is exactly one receiver per process.

#ifndef MB_AIRPLAY_BRIDGE_H
#define MB_AIRPLAY_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    void *ctx;
    /* Annex B video data (start codes, SPS/PPS or VPS/SPS/PPS before keyframes) */
    void (*video)(void *ctx, const uint8_t *data, int32_t length, bool is_h265);
    /* decrypted audio packets; compression_type 8 = AAC-ELD (mirroring), 2 = ALAC */
    void (*audio)(void *ctx, const uint8_t *data, int32_t length, uint8_t compression_type);
    void (*client)(void *ctx, const char *device_id, const char *model, const char *name);
    void (*connections)(void *ctx, int32_t open_connections);
    void (*video_size)(void *ctx, float source_width, float source_height, float width, float height);
    /* video stream restarted (reset decoder, wait for keyframe) */
    void (*video_reset)(void *ctx);
    /* connection lost or closed; receiver is ready again */
    void (*connection_lost)(void *ctx);
    void (*pin)(void *ctx, const char *pin);
    void (*volume)(void *ctx, float volume_db);
    void (*log)(void *ctx, int32_t level, const char *message);
} mb_airplay_callbacks;

typedef struct {
    const char *name;           /* name shown in Screen Mirroring */
    const char *device_id;      /* "AA:BB:CC:DD:EE:FF" */
    const char *keyfile;        /* key (PEM), created if needed */
    uint16_t width;
    uint16_t height;            /* determines the resolution the iPhone sends */
    uint16_t refresh_rate;
    uint16_t max_fps;
    bool h265;
    bool peer_to_peer;          /* also offer over AWDL (requires pin) */
    int32_t pin;                /* 1..9999 fixed code, 0 = no code */
    int32_t log_level;          /* 3 = error ... 7 = debug */
} mb_airplay_config;

/* 0 on success, otherwise a negative error code */
int mb_airplay_start(const mb_airplay_config *config, const mb_airplay_callbacks *callbacks);
/* TCP port of the running receiver, 0 when not started */
uint16_t mb_airplay_port(void);
void mb_airplay_stop(void);
/* disconnects the connected device; the receiver stays ready */
void mb_airplay_disconnect(void);

#endif
