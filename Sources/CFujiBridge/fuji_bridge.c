#include "fuji_bridge_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fuji.h>
#include <fujiptp.h>

/* ---------- Internal struct converters ---------- */

void fuji_bridge_populate_session_info(FujiBridgeSession *session, FujiBridgeSessionInfo *out_info) {
    if (out_info == NULL || session == NULL || session->runtime == NULL || session->runtime->priv == NULL) {
        return;
    }

    memset(out_info, 0, sizeof(*out_info));
    fujipriv_t *fuji = fuji_get(session->runtime);

    snprintf(out_info->camera_name, sizeof(out_info->camera_name), "%s", session->camera_name);
    out_info->camera_state = fuji->camera_state;
    out_info->remote_version = fuji->remote_version;
    out_info->remote_image_view_version = fuji->remote_image_view_version;
    out_info->remote_image_view_ex_version = fuji->remote_image_view_ex_version;
    out_info->active_card_id = fuji->card_id;
    out_info->effective_mode = (fuji->transport == FUJI_FEATURE_XAPP_WIRELESS_COMM)
        ? FUJI_BRIDGE_MODE_XAPP
        : FUJI_BRIDGE_MODE_WIRELESS_COMM;

    struct FujiCard *active_card = fuji_get_card(session->runtime);
    out_info->has_explicit_handle_list = (active_card != NULL && active_card->object_handle_list != NULL);
    out_info->total_object_count = fuji_bridge_get_object_count(session);

    uint32_t valid_cards = 0;
    for (int i = 0; i < 2; i++) {
        if (fuji->cards[i].name[0] != '\0' || fuji->cards[i].id != 0 || fuji->cards[i].n_available_objects > 0) {
            out_info->cards[valid_cards].card_id = fuji->cards[i].id;
            snprintf(
                out_info->cards[valid_cards].name,
                sizeof(out_info->cards[valid_cards].name),
                "%s",
                fuji->cards[i].name[0] != '\0' ? fuji->cards[i].name : "Card"
            );
            out_info->cards[valid_cards].object_count = fuji->cards[i].n_available_objects;
            valid_cards++;
        }
    }
    out_info->card_count = valid_cards;
}

static void convert_object_info(
    uint32_t handle,
    const struct PtpObjectInfo *src,
    FujiBridgeObjectInfo *dst
) {
    memset(dst, 0, sizeof(*dst));
    dst->handle = handle;
    dst->storage_id = src->storage_id;
    dst->object_format = src->obj_format;
    dst->compressed_size = src->compressed_size;
    dst->image_width = src->img_width;
    dst->image_height = src->img_height;
    snprintf(dst->filename, sizeof(dst->filename), "%s", src->filename);
    snprintf(dst->date_created, sizeof(dst->date_created), "%s", src->date_created);
}

/* ---------- Public C Bridge API ---------- */

FujiBridgeSession *fuji_bridge_create(
    bool verbose,
    FujiBridgeLogCallback log_cb,
    void *log_ctx
) {
    FujiBridgeSession *session = calloc(1, sizeof(FujiBridgeSession));
    if (session == NULL) {
        return NULL;
    }
    session->verbose = verbose;
    session->log_cb = log_cb;
    session->log_ctx = log_ctx;
    atomic_init(&session->cancel_requested, false);
    return session;
}

void fuji_bridge_destroy(FujiBridgeSession *session) {
    if (session == NULL) {
        return;
    }
    fuji_bridge_disconnect(session);
    free(session);
}

void fuji_bridge_set_interface(FujiBridgeSession *session, const char *interface_name) {
    if (session == NULL) {
        return;
    }
    if (interface_name == NULL) {
        session->interface_name[0] = '\0';
    } else {
        snprintf(session->interface_name, sizeof(session->interface_name), "%s", interface_name);
    }
}

void fuji_bridge_request_cancel(FujiBridgeSession *session, bool cancel) {
    if (session == NULL) {
        return;
    }
    atomic_store(&session->cancel_requested, cancel);
}

int32_t fuji_bridge_connect(
    FujiBridgeSession *session,
    const char *ip_address,
    int32_t port,
    FujiBridgeMode mode,
    const char *client_name,
    FujiBridgeSessionInfo *out_info
) {
    if (session == NULL || ip_address == NULL || client_name == NULL) {
        return PTP_RUNTIME_ERR;
    }

    fuji_bridge_disconnect(session);
    session->last_error[0] = '\0';
    session->camera_name[0] = '\0';
    atomic_store(&session->cancel_requested, false);

    struct PtpRuntime *r = fuji_ptp_new(PTP_IP_USB);
    if (r == NULL) {
        return PTP_OUT_OF_MEM;
    }
    r->userdata = session;
    r->set_extra_socket_settings = fuji_apply_apple_socket_options;

    fujipriv_t *fuji = fuji_get(r);
    fuji->transport = (mode == FUJI_BRIDGE_MODE_XAPP)
        ? FUJI_FEATURE_XAPP_WIRELESS_COMM
        : FUJI_FEATURE_WIRELESS_COMM;
    snprintf(fuji->ip_address, sizeof(fuji->ip_address), "%s", ip_address);

    session->runtime = r;

    int rc = ptpip_connect(r, ip_address, port, 3);
    if (rc != 0) {
        snprintf(
            session->last_error,
            sizeof(session->last_error),
            "TCP-Verbindung zu %s:%d fehlgeschlagen (rc=%d)",
            ip_address,
            port,
            rc
        );
        fuji_bridge_disconnect(session);
        return PTP_OPEN_FAIL;
    }

    rc = fuji_setup(r, client_name);
    if (rc != 0) {
        ptp_mutex_unlock_thread(r);
        if (session->last_error[0] == '\0') {
            snprintf(
                session->last_error,
                sizeof(session->last_error),
                "fuji_setup fehlgeschlagen (%s, rc=%d)",
                fuji_bridge_error_string(rc),
                rc
            );
        }
        fuji_bridge_disconnect(session);
        return rc;
    }

    session->connected = true;
    session->liveview_active = false;
    session->has_exposure_bias = false;
    fuji_bridge_populate_session_info(session, out_info);
    return PTP_OK;
}

void fuji_bridge_disconnect(FujiBridgeSession *session) {
    if (session == NULL || session->runtime == NULL) {
        return;
    }
    struct PtpRuntime *r = session->runtime;
    if (session->connected && !r->io_kill_switch) {
        ptp_report_error(r, "Session beendet", 0);
    } else {
        ptpip_device_close(r);
    }
    ptp_mutex_unlock_thread(r);
    ptpip_comm_deinit(r);
    if (r->priv != NULL) {
        free(r->priv->cards[0].object_handle_list);
        free(r->priv->cards[1].object_handle_list);
        if (r->priv->prop_desc_list.items != NULL) {
            for (unsigned int i = 0; i < r->priv->prop_desc_list.length; i++) {
                free(r->priv->prop_desc_list.items[i]);
            }
            free(r->priv->prop_desc_list.items);
        }
        free(r->priv);
        r->priv = NULL;
    }
    ptp_close(r);
    session->runtime = NULL;
    session->connected = false;
    session->liveview_active = false;
}

int32_t fuji_bridge_get_object_count(FujiBridgeSession *session) {
    if (session == NULL || session->runtime == NULL || session->runtime->priv == NULL) {
        return 0;
    }
    fujipriv_t *fuji = fuji_get(session->runtime);
    struct FujiCard *card = fuji_get_card(session->runtime);
    if (card != NULL && card->object_handle_list != NULL) {
        return (int32_t)card->n_available_objects;
    }
    int32_t card_count = (card != NULL) ? (int32_t)card->n_available_objects : 0;
    int32_t fuji_count = (fuji->num_objects > 0) ? fuji->num_objects : 0;
    return (card_count > fuji_count) ? card_count : fuji_count;
}

int32_t fuji_bridge_get_handle_at(FujiBridgeSession *session, int32_t index) {
    if (session == NULL || session->runtime == NULL || index < 0) {
        return -1;
    }
    return fuji_to_oh(session->runtime, index);
}

int32_t fuji_bridge_get_object_info(
    FujiBridgeSession *session,
    uint32_t handle,
    FujiBridgeObjectInfo *out_info
) {
    if (session == NULL || session->runtime == NULL || out_info == NULL) {
        return PTP_RUNTIME_ERR;
    }
    struct PtpObjectInfo oi;
    memset(&oi, 0, sizeof(oi));
    int rc = ptp_get_object_info(session->runtime, handle, &oi);
    if (rc != 0) {
        return rc;
    }
    convert_object_info(handle, &oi, out_info);
    return PTP_OK;
}

int32_t fuji_bridge_get_thumbnail(
    FujiBridgeSession *session,
    uint32_t handle,
    uint8_t **out_data,
    uint32_t *out_length
) {
    if (session == NULL || session->runtime == NULL || out_data == NULL || out_length == NULL) {
        return PTP_RUNTIME_ERR;
    }
    *out_data = NULL;
    *out_length = 0;

    struct PtpRuntime *r = session->runtime;
    ptp_mutex_lock(r);

    unsigned int offset = 0;
    unsigned int length = 0;
    int rc = fuji_get_thumb(r, (int)handle, &offset, &length);
    if (rc != 0 || length == 0) {
        ptp_mutex_unlock(r);
        return (rc != 0) ? rc : PTP_RUNTIME_ERR;
    }

    uint8_t *payload = ptp_get_payload(r);
    unsigned int payload_len = ptp_get_payload_length(r);
    if (offset + length > payload_len) {
        ptp_mutex_unlock(r);
        return PTP_RUNTIME_ERR;
    }

    uint8_t *copy = malloc(length);
    if (copy == NULL) {
        ptp_mutex_unlock(r);
        return PTP_OUT_OF_MEM;
    }
    memcpy(copy, payload + offset, length);
    ptp_mutex_unlock(r);

    *out_data = copy;
    *out_length = (uint32_t)length;
    return PTP_OK;
}

typedef struct {
    uint32_t handle;
    FujiBridgeObjectInfo *out_info;
    FujiBridgeChunkCallback chunk_cb;
    void *user_ctx;
    uint32_t bytes_received;
} DownloadBridgeContext;

static int download_info_trampoline(void *arg, struct PtpObjectInfo *oi) {
    DownloadBridgeContext *ctx = (DownloadBridgeContext *)arg;
    if (ctx->out_info != NULL && oi != NULL) {
        convert_object_info(ctx->handle, oi, ctx->out_info);
    }
    return 0;
}

static int download_chunk_trampoline(
    void *arg,
    void *buf,
    unsigned int len,
    unsigned int offset,
    unsigned int total_size
) {
    DownloadBridgeContext *ctx = (DownloadBridgeContext *)arg;
    ctx->bytes_received += len;
    if (ctx->chunk_cb != NULL) {
        return ctx->chunk_cb(ctx->user_ctx, (const uint8_t *)buf, len, offset, total_size);
    }
    return 0;
}

int32_t fuji_bridge_download_object(
    FujiBridgeSession *session,
    uint32_t handle,
    bool compress_for_smartphone,
    FujiBridgeObjectInfo *out_info,
    FujiBridgeChunkCallback chunk_cb,
    void *user_ctx
) {
    if (session == NULL || session->runtime == NULL) {
        return PTP_RUNTIME_ERR;
    }
    struct PtpRuntime *r = session->runtime;
    fuji_get(r)->compress_images_for_smartphone = compress_for_smartphone;

    DownloadBridgeContext ctx = {
        .handle = handle,
        .out_info = out_info,
        .chunk_cb = chunk_cb,
        .user_ctx = user_ctx,
        .bytes_received = 0
    };

    return fuji_download_file_ex(
        r,
        (int)handle,
        download_info_trampoline,
        download_chunk_trampoline,
        &ctx
    );
}

int32_t fuji_bridge_switch_card(
    FujiBridgeSession *session,
    int32_t card_id,
    FujiBridgeSessionInfo *out_info
) {
    if (session == NULL || session->runtime == NULL) {
        return PTP_RUNTIME_ERR;
    }
    int rc = fuji_switch_card(session->runtime, card_id);
    if (rc == 0) {
        fuji_bridge_populate_session_info(session, out_info);
    }
    return rc;
}

void fuji_bridge_get_last_error(
    FujiBridgeSession *session,
    char *buffer,
    size_t buffer_size
) {
    if (buffer == NULL || buffer_size == 0) {
        return;
    }
    if (session == NULL) {
        buffer[0] = '\0';
        return;
    }
    snprintf(buffer, buffer_size, "%s", session->last_error);
}

void fuji_bridge_free_buffer(uint8_t *buffer) {
    free(buffer);
}

const char *fuji_bridge_error_string(int32_t code) {
    switch (code) {
        case PTP_OK: return "OK";
        case PTP_NO_DEVICE: return "Kein Geraet gefunden";
        case PTP_NO_PERM: return "Keine Berechtigung";
        case PTP_OPEN_FAIL: return "Verbindungsaufbau fehlgeschlagen";
        case PTP_OUT_OF_MEM: return "Nicht genuegend Speicher";
        case PTP_IO_ERR: return "Netzwerk-/I/O-Fehler";
        case PTP_RUNTIME_ERR: return "Protokoll-/Laufzeitfehler";
        case PTP_UNSUPPORTED: return "Nicht unterstuetzte Operation";
        case PTP_CHECK_CODE: return "Kamera meldete PTP-Fehlercode";
        case PTP_CANCELLED: return "Abgebrochen";
        case PTP_COMMAND_IGNORED: return "Kamera antwortete nicht (Timeout)";
        case PTP_CLOSED: return "Verbindung von Kamera geschlossen";
        default: return "Unbekannter Fehler";
    }
}
