#include "fuji_bridge_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <fuji.h>
#include <fujiptp.h>

/* Forward declarations of libfuji helpers compiled into CLibFuji */
int fuji_get_property_descriptors(struct PtpRuntime *r);
int fuji_capture(struct PtpRuntime *r);

/* ---------- Internal event parser (captures extended Live-View telemetry) ---------- */

static int poll_events_extended(FujiBridgeSession *session) {
    struct PtpRuntime *r = session->runtime;
    fujipriv_t *fuji = fuji_get(r);

    ptp_mutex_lock(r);
    int rc = ptp_get_prop_value(r, PTP_DPC_FUJI_EventsList_D212);
    if (rc == PTP_CHECK_CODE) {
        ptp_mutex_unlock(r);
        return PTP_OK;
    } else if (rc != 0) {
        ptp_mutex_unlock(r);
        return rc;
    }

    uint8_t *payload = ptp_get_payload(r);
    unsigned int payload_len = ptp_get_payload_length(r);
    if (payload == NULL || payload_len < 2) {
        ptp_mutex_unlock(r);
        return PTP_OK;
    }

    struct PtpFujiEvents *ev = (struct PtpFujiEvents *)payload;
    uint16_t count = 0;
    ptp_read_u16(&ev->length, &count);

    unsigned int max_entries = (payload_len - 2) / sizeof(struct PtpFujiEventsEntry);
    if (count > max_entries) {
        count = (uint16_t)max_entries;
    }

    for (uint16_t i = 0; i < count; i++) {
        uint16_t code = 0;
        uint32_t value = 0;
        ptp_read_u16(&ev->events[i].code, &code);
        ptp_read_u32(&ev->events[i].value, &value);

        switch (code) {
            case PTP_DPC_FUJI_CameraState_DF00:
                fuji->camera_state = (int)value;
                break;
            case PTP_DPC_FUJI_SelectedImgsMode_D220:
                fuji->selected_imgs_mode = (int)value;
                break;
            case PTP_DPC_FUJI_ObjectCount_D222:
                fuji->num_objects = (int)value;
                break;
            case PTP_DPC_FNumber:
                fuji->fnumber = value;
                break;
            case PTP_DPC_FUJI_ExposureIndex:
                fuji->iso = value;
                break;
            case PTP_DPC_FUJI_ShutterSpeed2:
                fuji->shutterspeed = value;
                break;
            case PTP_DPC_FUJI_FilmSimulation:
                fuji->filmsilm = value;
                break;
            case PTP_DPC_ExposureBiasCompensation:
                session->exposure_bias = (int32_t)(int16_t)(value & 0xFFFF);
                session->has_exposure_bias = true;
                break;
            case PTP_DPC_WhiteBalance:
                session->white_balance = value;
                break;
            case PTP_DPC_FUJI_BatteryLevel:
                session->battery_level = value;
                break;
            case PTP_DPC_FUJI_CaptureRemaining:
                session->shots_remaining = value;
                break;
            case PTP_DPC_FUJI_MovieRemainingTime:
                session->movie_remaining_sec = value;
                break;
            default:
                break;
        }
    }

    ptp_mutex_unlock(r);
    return PTP_OK;
}

static void fill_liveview_status(FujiBridgeSession *session, FujiBridgeLiveViewStatus *out_status) {
    if (out_status == NULL || session == NULL || session->runtime == NULL || session->runtime->priv == NULL) {
        return;
    }
    fujipriv_t *fuji = fuji_get(session->runtime);
    memset(out_status, 0, sizeof(*out_status));
    out_status->iso = fuji->iso;
    out_status->fnumber = fuji->fnumber;
    out_status->shutter_speed = fuji->shutterspeed;
    out_status->film_simulation = fuji->filmsilm;
    out_status->exposure_bias = session->exposure_bias;
    out_status->has_exposure_bias = session->has_exposure_bias;
    out_status->white_balance = session->white_balance;
    out_status->battery_level = session->battery_level;
    out_status->shots_remaining = session->shots_remaining;
    out_status->movie_remaining_sec = session->movie_remaining_sec;
    out_status->liveview_active = session->liveview_active;
}

/* ---------- Live-View Lifecycle ---------- */

static void drain_video_socket(struct PtpRuntime *r) {
    if (r == NULL || r->priv == NULL || !r->priv->opened_liveview_sockets) {
        return;
    }
    uint8_t scratch[4096];
    for (int i = 0; i < 64; i++) {
        int n = ptpip_video_read(r, scratch, sizeof(scratch));
        if (n <= 0) {
            break;
        }
    }
}

int32_t fuji_bridge_enter_liveview(FujiBridgeSession *session) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }
    if (session->liveview_active) {
        return PTP_OK;
    }

    struct PtpRuntime *r = session->runtime;
    fujipriv_t *fuji = fuji_get(r);
    session->last_error[0] = '\0';

    int rc = 0;
    if (fuji->transport == FUJI_FEATURE_XAPP_WIRELESS_COMM && fuji->opened_liveview_sockets) {
        /* Re-entering Live-View in XApp mode: keep FUJI_MODE_REMOTE_LIVE_VIEW_XAPP (22)
           instead of libfuji's legacy FUJI_REMOTE_MODE (5) branch. */
        rc = ptp_set_prop_value16(r, PTP_DPC_FUJI_CameraState_DF00, FUJI_REMOTE_ACCESS);
        if (rc != 0) return rc;
        rc = ptp_set_prop_value16(r, PTP_DPC_FUJI_ClientState_DF01, FUJI_MODE_REMOTE_LIVE_VIEW_XAPP);
        if (rc != 0) return rc;
        rc = ptp_get_prop_value(r, PTP_DPC_FUJI_Unknown_DF2A);
        if (rc == 0) {
            uint32_t df2a = (uint32_t)ptp_parse_prop_value(r);
            (void)ptp_set_prop_value(r, PTP_DPC_FUJI_Unknown_DF2A, (int)df2a);
        }
        (void)fuji_get_property_descriptors(r);
        fuji->open_capture_trans_id = r->transaction;
        rc = ptp_init_open_capture(r, 0, 0);
        if (rc != 0) {
            snprintf(session->last_error, sizeof(session->last_error), "OpenCapture fehlgeschlagen (rc=%d)", rc);
            return rc;
        }
    } else {
        rc = fuji_config_liveview(r);
        if (rc != 0) {
            snprintf(session->last_error, sizeof(session->last_error), "Live-View-Start fehlgeschlagen (rc=%d)", rc);
            return rc;
        }
    }

    session->liveview_active = true;
    drain_video_socket(r);
    /* Poll events twice so initial telemetry (ISO/Blende/Zeit/Akku/Restfotos) is populated immediately. */
    (void)poll_events_extended(session);
    usleep(30 * 1000);
    (void)poll_events_extended(session);
    return PTP_OK;
}

int32_t fuji_bridge_exit_liveview(
    FujiBridgeSession *session,
    FujiBridgeSessionInfo *out_info
) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }

    struct PtpRuntime *r = session->runtime;
    if (!session->liveview_active) {
        fuji_bridge_populate_session_info(session, out_info);
        return PTP_OK;
    }

    int rc = fuji_end_liveview(r);
    if (rc != 0 && rc != PTP_CHECK_CODE) {
        snprintf(session->last_error, sizeof(session->last_error), "Live-View-Ende fehlgeschlagen (rc=%d)", rc);
    }

    session->liveview_active = false;
    drain_video_socket(r);

    int gal_rc = fuji_config_image_gallery(r);
    if (gal_rc != 0 && gal_rc != PTP_CHECK_CODE) {
        snprintf(session->last_error, sizeof(session->last_error), "Rueckkehr in Galerie fehlgeschlagen (rc=%d)", gal_rc);
        return gal_rc;
    }

    fuji_bridge_populate_session_info(session, out_info);
    return PTP_OK;
}

/* ---------- Live-View Frame Reader (Safe Non-Blocking TCP Port 55742) ---------- */

static int read_exact_video_bytes(struct PtpRuntime *r, uint8_t *dst, uint32_t expected, int max_wait_ms) {
    uint32_t offset = 0;
    int waited_ms = 0;
    while (offset < expected) {
        int n = ptpip_video_read(r, dst + offset, expected - offset);
        if (n < 0) {
            return n;
        }
        if (n == 0) {
            if (waited_ms >= max_wait_ms) {
                return (offset == 0) ? 0 : PTP_IO_ERR;
            }
            usleep(2000);
            waited_ms += 2;
            continue;
        }
        offset += (uint32_t)n;
        waited_ms = 0;
    }
    return (int)offset;
}

int32_t fuji_bridge_read_liveview_frame(
    FujiBridgeSession *session,
    uint8_t **out_data,
    uint32_t *out_length
) {
    if (session == NULL || session->runtime == NULL || out_data == NULL || out_length == NULL) {
        return PTP_RUNTIME_ERR;
    }
    *out_data = NULL;
    *out_length = 0;

    struct PtpRuntime *r = session->runtime;
    if (!session->liveview_active || !r->priv->opened_liveview_sockets) {
        return PTP_OK;
    }

    uint8_t header[18];
    int first = ptpip_video_read(r, header, sizeof(header));
    if (first == 0) {
        /* No frame buffered right now (EAGAIN). */
        return PTP_OK;
    }
    if (first < 0) {
        return first;
    }
    if (first < (int)sizeof(header)) {
        int rem = read_exact_video_bytes(r, header + first, (uint32_t)(sizeof(header) - (size_t)first), 250);
        if (rem <= 0) {
            return (rem < 0) ? rem : PTP_IO_ERR;
        }
    }

    uint32_t packet_len = 0;
    ptp_read_u32(header, &packet_len);
    if (packet_len <= sizeof(header) || packet_len > (4U * 1024U * 1024U)) {
        snprintf(session->last_error, sizeof(session->last_error), "Ungueltige Live-View-Framegroesse (%u)", packet_len);
        return PTP_RUNTIME_ERR;
    }

    uint32_t payload_len = packet_len - (uint32_t)sizeof(header);
    uint8_t *buf = malloc(payload_len);
    if (buf == NULL) {
        return PTP_OUT_OF_MEM;
    }

    int got = read_exact_video_bytes(r, buf, payload_len, 1500);
    if (got != (int)payload_len) {
        free(buf);
        return (got < 0) ? got : PTP_IO_ERR;
    }

    /* Locate JPEG SOI (0xFF 0xD8) in case the camera prepends extra framing bytes. */
    uint32_t soi_offset = 0;
    uint32_t scan_limit = (payload_len < 64) ? payload_len : 64;
    if (payload_len >= 2 && !(buf[0] == 0xFF && buf[1] == 0xD8)) {
        for (uint32_t i = 1; i + 1 < scan_limit; i++) {
            if (buf[i] == 0xFF && buf[i + 1] == 0xD8) {
                soi_offset = i;
                break;
            }
        }
    }

    if (soi_offset > 0) {
        uint32_t trimmed_len = payload_len - soi_offset;
        memmove(buf, buf + soi_offset, trimmed_len);
        payload_len = trimmed_len;
    }

    *out_data = buf;
    *out_length = payload_len;
    return PTP_OK;
}

/* ---------- Live-View Controls & Telemetry ---------- */

int32_t fuji_bridge_get_liveview_status(
    FujiBridgeSession *session,
    FujiBridgeLiveViewStatus *out_status
) {
    if (session == NULL || session->runtime == NULL || out_status == NULL) {
        return PTP_RUNTIME_ERR;
    }
    int rc = poll_events_extended(session);
    fill_liveview_status(session, out_status);
    return rc;
}

int32_t fuji_bridge_capture_photo(FujiBridgeSession *session) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }
    int rc = fuji_capture(session->runtime);
    if (rc != 0) {
        snprintf(session->last_error, sizeof(session->last_error), "Foto-Ausloesung fehlgeschlagen (rc=%d)", rc);
        return rc;
    }
    (void)poll_events_extended(session);
    return PTP_OK;
}

int32_t fuji_bridge_set_movie_recording(FujiBridgeSession *session, bool start) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }
    struct PtpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.code = start ? PTP_OC_FUJI_InitiateMovieCapture : PTP_OC_FUJI_TerminateMovieCapture;
    cmd.param_length = 0;

    int rc = ptp_send(session->runtime, &cmd);
    if (rc != 0) {
        snprintf(
            session->last_error,
            sizeof(session->last_error),
            "Video-%s fehlgeschlagen (rc=%d, Ret=0x%X)",
            start ? "Start" : "Stopp",
            rc,
            ptp_get_return_code(session->runtime)
        );
        return rc;
    }
    (void)poll_events_extended(session);
    return PTP_OK;
}

int32_t fuji_bridge_step_control(
    FujiBridgeSession *session,
    FujiBridgeStepKind kind,
    bool step_up
) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }
    uint16_t opcode = PTP_OC_FUJI_StepShutterSpeed;
    switch (kind) {
        case FUJI_BRIDGE_STEP_SHUTTER: opcode = PTP_OC_FUJI_StepShutterSpeed; break;
        case FUJI_BRIDGE_STEP_FNUMBER: opcode = PTP_OC_FUJI_StepFNumber; break;
        case FUJI_BRIDGE_STEP_EXPOSURE_BIAS: opcode = PTP_OC_FUJI_StepExposureBias; break;
    }

    struct PtpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.code = opcode;
    cmd.param_length = 1;
    cmd.params[0] = step_up ? 1 : 0;

    int rc = ptp_send(session->runtime, &cmd);
    if (rc != 0) {
        snprintf(session->last_error, sizeof(session->last_error), "Belichtungs-Schritt abgelehnt (rc=%d)", rc);
        return rc;
    }
    (void)poll_events_extended(session);
    return PTP_OK;
}

int32_t fuji_bridge_get_prop_options(
    FujiBridgeSession *session,
    uint16_t prop_code,
    uint32_t *out_values,
    uint32_t max_count,
    uint32_t *out_count
) {
    if (session == NULL || session->runtime == NULL || session->runtime->priv == NULL || out_count == NULL) {
        return PTP_RUNTIME_ERR;
    }
    *out_count = 0;

    struct FujiPropDescList *list = &fuji_get(session->runtime)->prop_desc_list;
    if (list->items == NULL) {
        return PTP_OK;
    }

    for (unsigned int i = 0; i < list->length; i++) {
        struct FujiPropDesc *desc = list->items[i];
        if (desc != NULL && (uint16_t)desc->code == prop_code) {
            uint32_t count = desc->n_items;
            if (count > max_count) {
                count = max_count;
            }
            if (out_values != NULL) {
                for (uint32_t j = 0; j < count; j++) {
                    out_values[j] = desc->items[j].raw_val;
                }
            }
            *out_count = count;
            return PTP_OK;
        }
    }
    return PTP_OK;
}

int32_t fuji_bridge_set_prop_u16(
    FujiBridgeSession *session,
    uint16_t prop_code,
    uint16_t value
) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }
    int rc = ptp_set_prop_value16(session->runtime, prop_code, value);
    if (rc != 0) {
        snprintf(session->last_error, sizeof(session->last_error), "Property 0x%04X setzen abgelehnt (rc=%d)", prop_code, rc);
        return rc;
    }
    (void)poll_events_extended(session);
    return PTP_OK;
}

int32_t fuji_bridge_set_prop_u32(
    FujiBridgeSession *session,
    uint16_t prop_code,
    uint32_t value
) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }
    int rc = ptp_set_prop_value(session->runtime, prop_code, (int)value);
    if (rc != 0) {
        snprintf(session->last_error, sizeof(session->last_error), "Property 0x%04X setzen abgelehnt (rc=%d)", prop_code, rc);
        return rc;
    }
    (void)poll_events_extended(session);
    return PTP_OK;
}

/* ---------- XApp Camera-Side Gallery Star Filter ---------- */

int32_t fuji_bridge_apply_star_filter(
    FujiBridgeSession *session,
    uint16_t star_bitmask,
    FujiBridgeSessionInfo *out_info
) {
    if (session == NULL || session->runtime == NULL || !session->connected) {
        return PTP_RUNTIME_ERR;
    }
    struct PtpRuntime *r = session->runtime;
    fujipriv_t *fuji = fuji_get(r);
    if (fuji->transport != FUJI_FEATURE_XAPP_WIRELESS_COMM) {
        snprintf(session->last_error, sizeof(session->last_error), "Kamera-Sternfilter erfordert den XApp-Modus.");
        return PTP_UNSUPPORTED;
    }

    session->last_error[0] = '\0';
    ptp_mutex_lock(r);

    int rc = ptp_set_prop_value16(r, PTP_DPC_FUJI_StarRatingFilter_D603, star_bitmask);
    if (rc != 0) {
        snprintf(
            session->last_error,
            sizeof(session->last_error),
            "Kamera lehnte Sternfilter 0xD603 ab (rc=%d, Ret=0x%X)",
            rc,
            ptp_get_return_code(r)
        );
        ptp_mutex_unlock(r);
        return rc;
    }

    /* Refresh filtered object count and filtered handle array from camera. */
    (void)ptp_get_prop_value(r, PTP_DPC_FUJI_FilteredObjectCount_D620);

    rc = ptp_get_prop_value(r, PTP_DPC_FUJI_FilteredObjectHandles_D621);
    if (rc != 0) {
        snprintf(session->last_error, sizeof(session->last_error), "Gefilterte Objektliste 0xD621 fehlgeschlagen (rc=%d)", rc);
        ptp_mutex_unlock(r);
        return rc;
    }

    uint32_t count = 0;
    unsigned int payload_len = ptp_get_payload_length(r);
    uint8_t *payload = ptp_get_payload(r);
    if (payload != NULL && payload_len >= 4) {
        ptp_read_u32(payload, &count);
    }

    struct FujiCard *card = fuji_get_card(r);
    if (card != NULL) {
        card->n_available_objects = count;
        free(card->object_handle_list);
        card->object_handle_list = NULL;
        if (count > 0) {
            card->object_handle_list = malloc(sizeof(uint32_t) * count);
            if (card->object_handle_list == NULL) {
                ptp_mutex_unlock(r);
                return PTP_OUT_OF_MEM;
            }
            unsigned int parsed_len = 0;
            ptp_read_uint32_array_s(payload, payload + payload_len, card->object_handle_list, count, &parsed_len);
            if (parsed_len < count) {
                card->n_available_objects = parsed_len;
            }
        }
    }

    ptp_mutex_unlock(r);
    fuji_bridge_populate_session_info(session, out_info);
    return PTP_OK;
}
