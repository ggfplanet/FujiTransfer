#include "fuji_bridge_internal.h"

#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include <fuji.h>
#include <app.h>

FujiBridgeSession *fuji_session_from_runtime(struct PtpRuntime *r) {
    if (r == NULL) {
        return NULL;
    }
    return (FujiBridgeSession *)r->userdata;
}

void fuji_bridge_emit_log(
    FujiBridgeSession *session,
    FujiBridgeLogLevel level,
    const char *fmt,
    va_list args
) {
    char message[1024];
    vsnprintf(message, sizeof(message), fmt, args);

    size_t len = strlen(message);
    while (len > 0 && (message[len - 1] == '\n' || message[len - 1] == '\r')) {
        message[len - 1] = '\0';
        len--;
    }
    if (len == 0) {
        return;
    }

    if (session != NULL) {
        if (level == FUJI_LOG_ERROR) {
            snprintf(session->last_error, sizeof(session->last_error), "%s", message);
        }
        if (level == FUJI_LOG_VERBOSE && !session->verbose) {
            return;
        }
        if (session->log_cb != NULL) {
            session->log_cb(session->log_ctx, level, message);
            return;
        }
    }

    if (level == FUJI_LOG_ERROR) {
        fprintf(stderr, "[fuji-err] %s\n", message);
    } else if (level == FUJI_LOG_INFO) {
        fprintf(stderr, "[fuji] %s\n", message);
    } else if (session != NULL && session->verbose) {
        fprintf(stderr, "[fuji-dbg] %s\n", message);
    }
}

int fuji_apply_apple_socket_options(struct PtpRuntime *r, int sockfd) {
    FujiBridgeSession *session = fuji_session_from_runtime(r);

    // Prevent SIGPIPE from terminating the app when the camera drops Wi-Fi
#ifdef SO_NOSIGPIPE
    int nosigpipe = 1;
    (void)setsockopt(sockfd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
#endif

    // Optional interface binding (e.g., "en0") so iOS/macOS never routes camera IP over cellular/LAN
#ifdef IP_BOUND_IF
    if (session != NULL && session->interface_name[0] != '\0') {
        unsigned int ifindex = if_nametoindex(session->interface_name);
        if (ifindex == 0) {
            snprintf(
                session->last_error,
                sizeof(session->last_error),
                "Netzwerk-Interface '%s' nicht gefunden",
                session->interface_name
            );
            return -1;
        }
        if (setsockopt(sockfd, IPPROTO_IP, IP_BOUND_IF, &ifindex, sizeof(ifindex)) < 0) {
            snprintf(
                session->last_error,
                sizeof(session->last_error),
                "IP_BOUND_IF fuer '%s' fehlgeschlagen (errno=%d)",
                session->interface_name,
                errno
            );
            return -1;
        }
    }
#endif

    return 0;
}

/* ---------- libpict & libfuji frontend hooks (required by app.h / libpict.h) ---------- */

void ptp_verbose_log(struct PtpRuntime *r, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fuji_bridge_emit_log(fuji_session_from_runtime(r), FUJI_LOG_VERBOSE, fmt, args);
    va_end(args);
}

void ptp_error_log(struct PtpRuntime *r, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fuji_bridge_emit_log(fuji_session_from_runtime(r), FUJI_LOG_ERROR, fmt, args);
    va_end(args);
}

void ptp_panic(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[fuji-panic] ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
    fflush(stderr);
    abort();
}

void plat_dbg(char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fuji_bridge_emit_log(NULL, FUJI_LOG_VERBOSE, fmt, args);
    va_end(args);
}

void app_print(struct PtpRuntime *r, char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fuji_bridge_emit_log(fuji_session_from_runtime(r), FUJI_LOG_INFO, fmt, args);
    va_end(args);
}

void app_send_cam_name(struct PtpRuntime *r, const char *name) {
    FujiBridgeSession *session = fuji_session_from_runtime(r);
    if (session != NULL && name != NULL) {
        snprintf(session->camera_name, sizeof(session->camera_name), "%s", name);
    }
}

void app_update_storage_info(struct PtpRuntime *r) {
    (void)r;
}

void app_report_download_speed(struct PtpRuntime *r, long time, size_t size) {
    (void)r;
    (void)time;
    (void)size;
}

int app_check_thread_cancel(struct PtpRuntime *r) {
    FujiBridgeSession *session = fuji_session_from_runtime(r);
    if (session == NULL) {
        return 0;
    }
    return atomic_load(&session->cancel_requested) ? 1 : 0;
}

int plat_update_object_info(struct PtpRuntime *r, int handle, const struct PtpObjectInfo *oi) {
    (void)r;
    (void)handle;
    (void)oi;
    return 0;
}

int app_ptp_download_file(
    struct PtpRuntime *r,
    struct PtpObjectInfo *oi,
    int object_id,
    unsigned int max_chunk_size,
    int index
) {
    (void)r;
    (void)oi;
    (void)object_id;
    (void)max_chunk_size;
    (void)index;
    return 0;
}

int app_queue_file_for_download(struct PtpRuntime *r, int object_id) {
    (void)r;
    (void)object_id;
    return 0;
}

int fuji_discovery_check_cancel(struct PtpRuntime *r) {
    return app_check_thread_cancel(r);
}
