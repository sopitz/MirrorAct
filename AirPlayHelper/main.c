// SPDX-License-Identifier: GPL-3.0-or-later
// mirroract-airplay: der AirPlay-Empfänger als eigenes Programm. Startet die Bridge
// (MirrorAct/AirPlay/airplay_bridge.c) und reicht Video, Ton und Ereignisse als Rahmen über
// stdout an die aufrufende App; Befehle kommen als Rahmen über stdin (helper_protocol.h, README.md).
// So kann eine App ohne GPL-Code (etwa die Windows-Version) den UxPlay-Empfänger nutzen.

#include "airplay_bridge.h"
#include "helper_protocol.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif

#define STDIN_FD 0
#define STDOUT_FD 1

typedef struct {
    const char *name;
    const char *device_id;
    const char *keyfile;
    int height;
    int fps;
    int pin;
    int log_level;
    bool hevc;
    bool p2p;
} options;

/* ---- stdout: Rahmen schreiben, serialisiert über einen Mutex ---- */

static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;

static long io_write(const void *data, size_t length) {
#ifdef _WIN32
    if (length > 1u << 30) length = 1u << 30;
    return _write(STDOUT_FD, data, (unsigned)length);
#else
    return (long)write(STDOUT_FD, data, length);
#endif
}

static long io_read(void *data, size_t length) {
#ifdef _WIN32
    if (length > 1u << 30) length = 1u << 30;
    return _read(STDIN_FD, data, (unsigned)length);
#else
    return (long)read(STDIN_FD, data, length);
#endif
}

/* schreibt alles; geht die Pipe kaputt, ist der Elternprozess weg und der Helfer beendet sich */
static void write_all(const void *data, size_t length) {
    const uint8_t *p = data;
    while (length > 0) {
        long n = io_write(p, length);
        if (n < 0) {
            if (errno == EINTR) continue;
            _exit(0);
        }
        p += n;
        length -= (size_t)n;
    }
}

static void send_frame(uint8_t type, uint8_t flags, const void *payload, uint32_t length) {
    uint8_t header[MB_HELPER_HEADER_SIZE] = {
        (uint8_t)length, (uint8_t)(length >> 8), (uint8_t)(length >> 16), (uint8_t)(length >> 24),
        type, flags, 0, 0,
    };
    pthread_mutex_lock(&out_lock);
    write_all(header, sizeof(header));
    if (length > 0) write_all(payload, length);
    pthread_mutex_unlock(&out_lock);
}

/* ---- kleine Zeichenkettenhilfe für die JSON-Nutzlasten ---- */

typedef struct {
    char *data;
    size_t size;
    size_t length;
} strbuf;

static void sb_putc(strbuf *b, char c) {
    if (b->length + 1 < b->size) b->data[b->length++] = c;
}

static void sb_puts(strbuf *b, const char *s) {
    while (*s) sb_putc(b, *s++);
}

/* JSON-String mit Anführungszeichen; UTF-8 bleibt, nur Steuerzeichen, " und \ werden maskiert */
static void sb_json_string(strbuf *b, const char *s) {
    static const char hex[] = "0123456789abcdef";
    sb_putc(b, '"');
    for (; s && *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"': sb_puts(b, "\\\""); break;
        case '\\': sb_puts(b, "\\\\"); break;
        case '\n': sb_puts(b, "\\n"); break;
        case '\r': sb_puts(b, "\\r"); break;
        case '\t': sb_puts(b, "\\t"); break;
        default:
            if (c < 0x20) {
                sb_puts(b, "\\u00");
                sb_putc(b, hex[c >> 4]);
                sb_putc(b, hex[c & 15]);
            } else {
                sb_putc(b, (char)c);
            }
        }
    }
    sb_putc(b, '"');
}

static void sb_int(strbuf *b, long value) {
    char digits[24];
    snprintf(digits, sizeof(digits), "%ld", value);
    sb_puts(b, digits);
}

static void put_u32le(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)value;
    dst[1] = (uint8_t)(value >> 8);
    dst[2] = (uint8_t)(value >> 16);
    dst[3] = (uint8_t)(value >> 24);
}

static void put_f32le(uint8_t *dst, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    put_u32le(dst, bits);
}

/* ---- Bridge-Callbacks → Rahmen (kommen auf den Threads der UxPlay-Bibliothek) ---- */

static void on_video(void *ctx, const uint8_t *data, int32_t length, bool is_h265) {
    if (length > 0) send_frame(MB_FRAME_VIDEO, is_h265 ? MB_VIDEO_FLAG_HEVC : 0, data, (uint32_t)length);
}

static void on_audio(void *ctx, const uint8_t *data, int32_t length, uint8_t compression_type) {
    if (length > 0) send_frame(MB_FRAME_AUDIO, compression_type, data, (uint32_t)length);
}

static void on_client(void *ctx, const char *device_id, const char *model, const char *name) {
    char buffer[2048];
    strbuf b = {buffer, sizeof(buffer), 0};
    sb_puts(&b, "{\"deviceId\":");
    sb_json_string(&b, device_id);
    sb_puts(&b, ",\"model\":");
    sb_json_string(&b, model);
    sb_puts(&b, ",\"name\":");
    sb_json_string(&b, name);
    sb_puts(&b, "}");
    send_frame(MB_FRAME_CLIENT, 0, buffer, (uint32_t)b.length);
}

static void on_connections(void *ctx, int32_t open_connections) {
    uint8_t payload[4];
    put_u32le(payload, (uint32_t)open_connections);
    send_frame(MB_FRAME_CONNECTIONS, 0, payload, sizeof(payload));
}

static void on_video_size(void *ctx, float source_width, float source_height, float width, float height) {
    uint8_t payload[16];
    put_f32le(payload, source_width);
    put_f32le(payload + 4, source_height);
    put_f32le(payload + 8, width);
    put_f32le(payload + 12, height);
    send_frame(MB_FRAME_VIDEO_SIZE, 0, payload, sizeof(payload));
}

static void on_video_reset(void *ctx) {
    send_frame(MB_FRAME_VIDEO_RESET, 0, NULL, 0);
}

static void on_connection_lost(void *ctx) {
    send_frame(MB_FRAME_CONNECTION_LOST, 0, NULL, 0);
}

static void on_pin(void *ctx, const char *pin) {
    if (pin) send_frame(MB_FRAME_PIN, 0, pin, (uint32_t)strlen(pin));
}

static void on_volume(void *ctx, float volume_db) {
    uint8_t payload[4];
    put_f32le(payload, volume_db);
    send_frame(MB_FRAME_VOLUME, 0, payload, sizeof(payload));
}

static void on_log(void *ctx, int32_t level, const char *message) {
    if (!message) return;
    size_t length = strlen(message);
    while (length > 0 && (message[length - 1] == '\n' || message[length - 1] == '\r')) length--;
    if (length == 0) return;
    uint8_t flags = level < 0 ? 0 : level > 255 ? 255 : (uint8_t)level;
    send_frame(MB_FRAME_LOG, flags, message, (uint32_t)length);
}

static void send_started(const char *name, unsigned port) {
    char buffer[1024];
    strbuf b = {buffer, sizeof(buffer), 0};
    sb_puts(&b, "{\"name\":");
    sb_json_string(&b, name);
    sb_puts(&b, ",\"port\":");
    sb_int(&b, (long)port);
    sb_puts(&b, "}");
    send_frame(MB_FRAME_STARTED, 0, buffer, (uint32_t)b.length);
}

static const char *error_message(int code) {
    switch (code) {
    case -1: return "a receiver is already running in this process";
    case -2: return "invalid device ID (expected AA:BB:CC:DD:EE:FF)";
    case -3: return "DNS-SD could not be initialised";
    case -4: return "the AirPlay server could not be created";
    case -5: return "the AirPlay server could not be initialised (key file not writable?)";
    case -6: return "DNS-SD registration failed (name in use, or UDP port 5353 / multicast blocked)";
    case -7: return "the service thread's wake-up could not be created";
    case -8: return "the service thread could not be started";
    default: return "unknown error";
    }
}

static void send_error(int code) {
    char buffer[512];
    strbuf b = {buffer, sizeof(buffer), 0};
    sb_puts(&b, "{\"code\":");
    sb_int(&b, code);
    sb_puts(&b, ",\"message\":");
    sb_json_string(&b, error_message(code));
    sb_puts(&b, "}");
    send_frame(MB_FRAME_ERROR, 0, buffer, (uint32_t)b.length);
}

/* ---- stdin: Befehle lesen, auf eigenem Thread ---- */

static atomic_bool stop_requested;
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t state_cond = PTHREAD_COND_INITIALIZER;

static void request_stop(void) {
    pthread_mutex_lock(&state_lock);
    atomic_store(&stop_requested, true);
    pthread_cond_signal(&state_cond);
    pthread_mutex_unlock(&state_lock);
}

/* liest genau length Bytes; false bei Dateiende oder Fehler */
static bool read_all(uint8_t *data, size_t length) {
    while (length > 0) {
        long n = io_read(data, length);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        data += n;
        length -= (size_t)n;
    }
    return true;
}

static void *stdin_loop(void *arg) {
    uint8_t header[MB_HELPER_HEADER_SIZE];
    bool open = true;
    while (open && read_all(header, sizeof(header))) {
        uint32_t length = header[0] | (uint32_t)header[1] << 8 | (uint32_t)header[2] << 16 | (uint32_t)header[3] << 24;
        uint8_t type = header[4];
        /* Befehle haben derzeit keine Nutzlast; eine vorhandene wird überlesen */
        uint8_t skip[256];
        while (open && length > 0) {
            size_t chunk = length < sizeof(skip) ? length : sizeof(skip);
            open = read_all(skip, chunk);
            length -= (uint32_t)chunk;
        }
        if (!open) break;
        switch (type) {
        case MB_COMMAND_DISCONNECT: mb_airplay_disconnect(); break;
        case MB_COMMAND_STOP: open = false; break;
        default: break; /* unbekannte Befehle werden ignoriert */
        }
    }
    request_stop(); /* Dateiende und STOP wirken gleich */
    return NULL;
}

static void on_signal(int sig) {
    atomic_store(&stop_requested, true);
}

/* ---- Argumente ---- */

static void usage(FILE *out) {
    fputs("Usage: mirroract-airplay --name <name> --device-id AA:BB:CC:DD:EE:FF --keyfile <path>\n"
          "                         [--height 2160] [--fps 60] [--hevc] [--pin 1234] [--p2p] [--log-level 6]\n"
          "\n"
          "AirPlay screen mirroring receiver for MirrorAct. Writes video, audio and events as\n"
          "binary frames to stdout and reads commands from stdin (see README.md); stdout must\n"
          "therefore be a pipe. Exit code 0 after STOP or end of stdin, otherwise the bridge's\n"
          "error code (2 = invalid arguments).\n"
          "\n"
          "  --name        name shown in Screen Mirroring\n"
          "  --device-id   locally administered MAC-style ID of the receiver\n"
          "  --keyfile     PEM key of the receiver, created when missing\n"
          "  --height      stream height requested from the device (width = height * 16/9), 240-4320\n"
          "  --fps         maximum frame rate, 1-120\n"
          "  --hevc        offer HEVC besides H.264\n"
          "  --pin         fixed code (1-9999) the device must enter (legacy pairing)\n"
          "  --p2p         also offer the receiver over AWDL (macOS only, ignored elsewhere; needs --pin)\n"
          "  --log-level   0 (emergency) to 8 (debug with packet data); LOG frames carry the level\n",
          out);
}

static bool parse_int(const char *text, int min, int max, int *value) {
    char *end = NULL;
    long parsed = strtol(text, &end, 10);
    if (!end || *end || end == text || parsed < min || parsed > max) return false;
    *value = (int)parsed;
    return true;
}

static bool parse_args(int argc, char **argv, options *opt) {
    memset(opt, 0, sizeof(*opt));
    opt->height = 2160;
    opt->fps = 60;
    opt->log_level = 6;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        const char *value = i + 1 < argc ? argv[i + 1] : NULL;
        bool ok = true;
        if (!strcmp(arg, "--help") || !strcmp(arg, "-h")) {
            usage(stdout);
            exit(0);
        } else if (!strcmp(arg, "--hevc")) {
            opt->hevc = true;
        } else if (!strcmp(arg, "--p2p")) {
            opt->p2p = true;
        } else if (!value) {
            fprintf(stderr, "mirroract-airplay: %s needs a value\n", arg);
            return false;
        } else if (!strcmp(arg, "--name")) {
            opt->name = value;
            i++;
        } else if (!strcmp(arg, "--device-id")) {
            opt->device_id = value;
            i++;
        } else if (!strcmp(arg, "--keyfile")) {
            opt->keyfile = value;
            i++;
        } else if (!strcmp(arg, "--height")) {
            ok = parse_int(value, 240, 4320, &opt->height);
            i++;
        } else if (!strcmp(arg, "--fps")) {
            ok = parse_int(value, 1, 120, &opt->fps);
            i++;
        } else if (!strcmp(arg, "--pin")) {
            ok = parse_int(value, 1, 9999, &opt->pin);
            i++;
        } else if (!strcmp(arg, "--log-level")) {
            ok = parse_int(value, 0, 8, &opt->log_level);
            i++;
        } else {
            fprintf(stderr, "mirroract-airplay: unknown option %s\n", arg);
            return false;
        }
        if (!ok) {
            fprintf(stderr, "mirroract-airplay: invalid value for %s: %s\n", arg, value);
            return false;
        }
    }
    if (!opt->name || !*opt->name || !opt->device_id || !opt->keyfile) {
        fputs("mirroract-airplay: --name, --device-id and --keyfile are required\n", stderr);
        return false;
    }
    return true;
}

/* ---- main ---- */

int main(int argc, char **argv) {
    options opt;
    if (!parse_args(argc, argv, &opt)) {
        usage(stderr);
        return 2;
    }

#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stdin), _O_BINARY);
    if (_isatty(STDOUT_FD)) {
#else
    signal(SIGPIPE, SIG_IGN); /* kaputte Pipe meldet write() als EPIPE, siehe write_all */
    if (isatty(STDOUT_FD)) {
#endif
        fputs("mirroract-airplay: stdout must be a pipe (binary frames), not a terminal\n", stderr);
        return 2;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    pthread_t reader;
    if (pthread_create(&reader, NULL, stdin_loop, NULL) != 0) {
        fputs("mirroract-airplay: could not start the stdin thread\n", stderr);
        return 2;
    }
    pthread_detach(reader); /* hängt bei einem Signal noch in read(); der Prozess endet trotzdem */

    mb_airplay_config config = {
        .name = opt.name,
        .device_id = opt.device_id,
        .keyfile = opt.keyfile,
        .width = (uint16_t)(opt.height * 16 / 9),
        .height = (uint16_t)opt.height,
        .refresh_rate = 60,
        .max_fps = (uint16_t)opt.fps,
        .h265 = opt.hevc,
        .peer_to_peer = opt.p2p,
        .pin = opt.pin,
        .log_level = opt.log_level,
    };
    mb_airplay_callbacks callbacks = {
        .ctx = NULL,
        .video = on_video,
        .audio = on_audio,
        .client = on_client,
        .connections = on_connections,
        .video_size = on_video_size,
        .video_reset = on_video_reset,
        .connection_lost = on_connection_lost,
        .pin = on_pin,
        .volume = on_volume,
        .log = on_log,
    };

    int result = mb_airplay_start(&config, &callbacks);
    if (result != 0) {
        send_error(result);
        return -result;
    }
    send_started(opt.name, mb_airplay_port());

    /* laufen lassen, bis STOP, Dateiende auf stdin oder ein Signal kommt */
    pthread_mutex_lock(&state_lock);
    while (!atomic_load(&stop_requested)) {
        struct timespec until;
        timespec_get(&until, TIME_UTC);
        until.tv_nsec += 250 * 1000 * 1000;
        if (until.tv_nsec >= 1000 * 1000 * 1000) {
            until.tv_nsec -= 1000 * 1000 * 1000;
            until.tv_sec += 1;
        }
        pthread_cond_timedwait(&state_cond, &state_lock, &until);
    }
    pthread_mutex_unlock(&state_lock);

    mb_airplay_stop();
    return 0;
}
