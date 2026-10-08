// SPDX-License-Identifier: GPL-3.0-or-later
// AirPlay-Empfänger auf Basis der UxPlay-Bibliothek. Entspricht dem Ablauf in
// UxPlays uxplay.cpp (start_dnssd → start_raop_server → register_dnssd), aber ohne
// GStreamer: Video und Audio gehen roh an Swift.

#include "airplay_bridge.h"

#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "dnssd.h"
#include "logger.h"
#include "raop.h"

#define MISSED_FEEDBACK_LIMIT 15 /* Sekunden ohne Heartbeat bis zur Trennung */

static raop_t *raop;
static dnssd_t *dnssd;
static mb_airplay_callbacks cb;
static pthread_t service_thread;
static atomic_bool service_running;
static atomic_int open_connections;
static atomic_int missed_feedback;
static atomic_bool reset_requested;
static int wake_pipe[2] = {-1, -1};

static void bridge_log(int level, const char *format, ...) __attribute__((format(printf, 2, 3)));
static void bridge_log(int level, const char *format, ...) {
    if (!cb.log) return;
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    cb.log(cb.ctx, level, buffer);
}

static void notify_connections(void) {
    if (cb.connections) cb.connections(cb.ctx, atomic_load(&open_connections));
}

/* ---- raop-Callbacks ---- */

static void on_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    if (cb.video && data->data && data->data_len > 0) {
        cb.video(cb.ctx, data->data, data->data_len, data->is_h265);
    }
}

static void on_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    if (cb.audio && data->data && data->data_len > 0) {
        cb.audio(cb.ctx, data->data, data->data_len, data->ct);
    }
}

static void on_video_pause(void *cls) {}
static void on_video_resume(void *cls) {}

static void on_conn_feedback(void *cls) {
    atomic_store(&missed_feedback, 0);
}

static void on_conn_reset(void *cls, int reason) {
    bridge_log(LOGGER_INFO, "connection reset (reason %d)", reason);
    atomic_store(&reset_requested, true);
}

static void on_video_reset(void *cls, reset_type_t type) {
    if (cb.video_reset) cb.video_reset(cb.ctx);
}

static void on_conn_init(void *cls) {
    atomic_fetch_add(&open_connections, 1);
    notify_connections();
}

static void on_conn_destroy(void *cls) {
    if (atomic_fetch_sub(&open_connections, 1) <= 1) {
        atomic_store(&open_connections, 0);
        atomic_store(&missed_feedback, 0);
    }
    notify_connections();
}

static void on_audio_flush(void *cls) {}
static void on_video_flush(void *cls) {
    if (cb.video_reset) cb.video_reset(cb.ctx);
}

static double on_audio_set_client_volume(void *cls) { return 0.0; }
static void on_audio_set_volume(void *cls, float volume) {
    if (cb.volume) cb.volume(cb.ctx, volume);
}
static void on_audio_set_metadata(void *cls, const void *buffer, int buflen) {}
static void on_audio_set_coverart(void *cls, const void *buffer, int buflen) {}
static void on_audio_stop_coverart_rendering(void *cls) {}
static void on_audio_remote_control_id(void *cls, const char *dacp_id, const char *active_remote_header) {}
static void on_audio_set_progress(void *cls, uint32_t *start, uint32_t *curr, uint32_t *end) {}
static void on_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf, bool *using_screen,
                                bool *is_media, uint64_t *audio_format) {}

static void on_video_report_size(void *cls, float *width_source, float *height_source, float *width, float *height) {
    if (cb.video_size) cb.video_size(cb.ctx, *width_source, *height_source, *width, *height);
}

static void on_report_client_request(void *cls, char *device_id, char *model, char *name, bool *admit) {
    *admit = true;
    bridge_log(LOGGER_INFO, "connection request from %s (%s), ID %s", name, model, device_id);
    if (cb.client) cb.client(cb.ctx, device_id, model, name);
}

static void on_display_pin(void *cls, char *pin) {
    if (cb.pin) cb.pin(cb.ctx, pin);
}

static void on_register_client(void *cls, const char *device_id, const char *pk_str, const char *name) {}
static bool on_check_register(void *cls, const char *pk_str) { return true; }

static const char *on_passwd(void *cls, int *len) {
    *len = 0;
    return NULL;
}

static void on_export_dacp(void *cls, const char *active_remote, const char *dacp_id) {}
static int on_video_set_codec(void *cls, video_codec_t codec) { return 0; }

/* HLS ist abgeschaltet; die Callbacks müssen trotzdem existieren */
static void on_video_play(void *cls, const char *location, const float start_position) {}
static void on_video_scrub(void *cls, const float position) {}
static void on_video_rate(void *cls, const float rate) {}
static void on_video_stop(void *cls) {}
static void on_video_acquire_playback_info(void *cls, playback_info_t *playback_info) {}
static float on_video_playlist_remove(void *cls) { return 0.0f; }

static void on_raop_log(void *cls, int level, const char *msg) {
    if (cb.log) cb.log(cb.ctx, level, msg);
}

/* ---- Hintergrund-Thread: Bonjour-Sockets bedienen, Heartbeat, Neustarts ---- */

static void restart_httpd(void) {
    unsigned short port = raop_get_port(raop);
    raop_stop_httpd(raop);
    raop_remove_known_connections(raop);
    raop_start_httpd(raop, &port);
    raop_set_port(raop, port);
    atomic_store(&open_connections, 0);
    atomic_store(&missed_feedback, 0);
    notify_connections();
    if (cb.connection_lost) cb.connection_lost(cb.ctx);
}

static void *service_loop(void *arg) {
    bool service_failed[2] = {false, false};
    time_t last_tick = time(NULL);

    while (atomic_load(&service_running)) {
        struct pollfd fds[3];
        int services[3];
        int count = 0;
        fds[count] = (struct pollfd){.fd = wake_pipe[0], .events = POLLIN};
        services[count++] = -1;
        for (int s = 0; s < 2; s++) {
            if (service_failed[s]) continue;
            int fd = dnssd_get_service_fd(dnssd, s);
            if (fd >= 0) {
                fds[count] = (struct pollfd){.fd = fd, .events = POLLIN};
                services[count++] = s;
            }
        }

        int ready = poll(fds, count, 1000);
        if (!atomic_load(&service_running)) break;

        if (ready > 0) {
            for (int i = 1; i < count; i++) {
                if (fds[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
                    service_failed[services[i]] = true;
                    bridge_log(LOGGER_ERR, "Bonjour socket for service %d failed", services[i]);
                } else if ((fds[i].revents & POLLIN) && dnssd_process_service(dnssd, services[i]) != 0) {
                    service_failed[services[i]] = true;
                    bridge_log(LOGGER_ERR, "Bonjour service %d stopped responding", services[i]);
                }
            }
        }

        time_t now = time(NULL);
        if (now != last_tick) {
            last_tick = now;
            if (atomic_load(&open_connections) > 0) {
                if (atomic_fetch_add(&missed_feedback, 1) + 1 > MISSED_FEEDBACK_LIMIT) {
                    bridge_log(LOGGER_INFO, "no heartbeat for %d s, disconnecting", MISSED_FEEDBACK_LIMIT);
                    atomic_store(&reset_requested, true);
                }
            } else {
                atomic_store(&missed_feedback, 0);
            }
        }

        if (atomic_exchange(&reset_requested, false)) {
            restart_httpd();
        }
    }
    return NULL;
}

/* ---- öffentliche Funktionen ---- */

static void teardown(void) {
    if (raop) {
        raop_destroy(raop);
        raop = NULL;
    }
    if (dnssd) {
        dnssd_unregister_raop(dnssd);
        dnssd_unregister_airplay(dnssd);
        dnssd_destroy(dnssd);
        dnssd = NULL;
    }
}

int mb_airplay_start(const mb_airplay_config *config, const mb_airplay_callbacks *callbacks) {
    static bool ntp_initialized = false;
    if (raop || dnssd) return -1;
    cb = *callbacks;
    if (!ntp_initialized) {
        ntp_global_init();
        ntp_initialized = true;
    }

    unsigned int hw[6];
    if (sscanf(config->device_id, "%x:%x:%x:%x:%x:%x", &hw[0], &hw[1], &hw[2], &hw[3], &hw[4], &hw[5]) != 6) {
        bridge_log(LOGGER_ERR, "invalid device ID %s", config->device_id);
        return -2;
    }
    char hw_addr[6];
    for (int i = 0; i < 6; i++) hw_addr[i] = (char)hw[i];

    unsigned char pin_pw = config->pin > 0 ? 1 : 0;
    int error = 0;
    dnssd = dnssd_init(config->name, (int)strlen(config->name), hw_addr, 6, pin_pw, &error);
    if (error || !dnssd) {
        bridge_log(LOGGER_ERR, "dnssd_init failed (%d)", error);
        dnssd = NULL;
        return -3;
    }
    dnssd_set_peer_to_peer(dnssd, config->peer_to_peer ? 1 : 0);
    dnssd_set_airplay_features(dnssd, 0, 0);  /* kein HLS-Video */
    dnssd_set_airplay_features(dnssd, 4, 0);
    dnssd_set_airplay_features(dnssd, 42, config->h265 ? 1 : 0);  /* Screen Multi Codec (HEVC) */
    dnssd_set_airplay_features(dnssd, 27, pin_pw);  /* Legacy Pairing, nötig für pin und AWDL */

    raop_callbacks_t rc;
    memset(&rc, 0, sizeof(rc));
    rc.audio_process = on_audio_process;
    rc.video_process = on_video_process;
    rc.video_pause = on_video_pause;
    rc.video_resume = on_video_resume;
    rc.conn_feedback = on_conn_feedback;
    rc.conn_reset = on_conn_reset;
    rc.video_reset = on_video_reset;
    rc.conn_init = on_conn_init;
    rc.conn_destroy = on_conn_destroy;
    rc.audio_flush = on_audio_flush;
    rc.video_flush = on_video_flush;
    rc.audio_set_client_volume = on_audio_set_client_volume;
    rc.audio_set_volume = on_audio_set_volume;
    rc.audio_set_metadata = on_audio_set_metadata;
    rc.audio_set_coverart = on_audio_set_coverart;
    rc.audio_stop_coverart_rendering = on_audio_stop_coverart_rendering;
    rc.audio_remote_control_id = on_audio_remote_control_id;
    rc.audio_set_progress = on_audio_set_progress;
    rc.audio_get_format = on_audio_get_format;
    rc.video_report_size = on_video_report_size;
    rc.report_client_request = on_report_client_request;
    rc.display_pin = on_display_pin;
    rc.register_client = on_register_client;
    rc.check_register = on_check_register;
    rc.passwd = on_passwd;
    rc.export_dacp = on_export_dacp;
    rc.video_set_codec = on_video_set_codec;
    rc.on_video_play = on_video_play;
    rc.on_video_scrub = on_video_scrub;
    rc.on_video_rate = on_video_rate;
    rc.on_video_stop = on_video_stop;
    rc.on_video_acquire_playback_info = on_video_acquire_playback_info;
    rc.on_video_playlist_remove = on_video_playlist_remove;

    raop = raop_init(&rc);
    if (!raop) {
        teardown();
        return -4;
    }
    raop_set_log_callback(raop, on_raop_log, NULL);
    raop_set_log_level(raop, config->log_level);
    /* nohold = 1: ein neues Gerät übernimmt die Verbindung */
    if (raop_init2(raop, 1, config->device_id, config->keyfile)) {
        free(raop);
        raop = NULL;
        teardown();
        return -5;
    }

    raop_set_plist(raop, "width", config->width);
    raop_set_plist(raop, "height", config->height);
    raop_set_plist(raop, "refreshRate", config->refresh_rate);
    raop_set_plist(raop, "maxFPS", config->max_fps);
    if (pin_pw) raop_set_plist(raop, "pin", config->pin + 10000);  /* > 9999 = fester Code */

    unsigned short tcp[3] = {0, 0, 0};
    unsigned short udp[3] = {0, 0, 0};
    raop_set_tcp_ports(raop, tcp);
    raop_set_udp_ports(raop, udp);
    unsigned short port = raop_get_port(raop);
    raop_start_httpd(raop, &port);
    raop_set_port(raop, port);
    raop_set_dnssd(raop, dnssd);

    if (dnssd_register_raop(dnssd, port) || dnssd_register_airplay(dnssd, port)) {
        bridge_log(LOGGER_ERR, "Bonjour registration failed");
        teardown();
        return -6;
    }
    bridge_log(LOGGER_INFO, "AirPlay receiver \"%s\" on port %u", config->name, port);

    if (pipe(wake_pipe) != 0) {
        teardown();
        return -7;
    }
    atomic_store(&open_connections, 0);
    atomic_store(&missed_feedback, 0);
    atomic_store(&reset_requested, false);
    atomic_store(&service_running, true);
    if (pthread_create(&service_thread, NULL, service_loop, NULL) != 0) {
        atomic_store(&service_running, false);
        close(wake_pipe[0]);
        close(wake_pipe[1]);
        teardown();
        return -8;
    }
    return 0;
}

void mb_airplay_stop(void) {
    if (atomic_exchange(&service_running, false)) {
        (void)write(wake_pipe[1], "x", 1);
        pthread_join(service_thread, NULL);
        close(wake_pipe[0]);
        close(wake_pipe[1]);
        wake_pipe[0] = wake_pipe[1] = -1;
    }
    teardown();
    atomic_store(&open_connections, 0);
}

void mb_airplay_disconnect(void) {
    if (!atomic_load(&service_running)) return;
    atomic_store(&reset_requested, true);
    (void)write(wake_pipe[1], "x", 1);
}
