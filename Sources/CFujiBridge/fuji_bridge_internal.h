#ifndef FUJI_BRIDGE_INTERNAL_H
#define FUJI_BRIDGE_INTERNAL_H

#include "fuji_bridge.h"

#include <stdarg.h>
#include <stdatomic.h>
#include <libpict.h>

struct FujiBridgeSession {
    struct PtpRuntime *runtime;
    bool verbose;
    bool connected;
    bool liveview_active;
    int32_t exposure_bias;
    bool has_exposure_bias;
    uint32_t white_balance;
    uint32_t battery_level;
    uint32_t shots_remaining;
    uint32_t movie_remaining_sec;
    atomic_bool cancel_requested;
    char interface_name[32];
    char camera_name[64];
    char last_error[256];
    FujiBridgeLogCallback log_cb;
    void *log_ctx;
};

FujiBridgeSession *fuji_session_from_runtime(struct PtpRuntime *r);

void fuji_bridge_populate_session_info(
    FujiBridgeSession *session,
    FujiBridgeSessionInfo *out_info
);

void fuji_bridge_emit_log(
    FujiBridgeSession *session,
    FujiBridgeLogLevel level,
    const char *fmt,
    va_list args
);

int fuji_apply_apple_socket_options(struct PtpRuntime *r, int sockfd);

#endif /* FUJI_BRIDGE_INTERNAL_H */
