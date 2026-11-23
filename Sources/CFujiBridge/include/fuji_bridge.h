#ifndef FUJI_BRIDGE_H
#define FUJI_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque session handle wrapping libfuji / libpict runtime state.
typedef struct FujiBridgeSession FujiBridgeSession;

/// Fujifilm Wi-Fi protocol variant to use during setup.
typedef enum {
    /// Manual Wi-Fi / legacy "Wireless Communication" / Camera Remote flow.
    FUJI_BRIDGE_MODE_WIRELESS_COMM = 0,
    /// Modern Fujifilm XApp flow (typically after Bluetooth Wi-Fi handover).
    FUJI_BRIDGE_MODE_XAPP = 1
} FujiBridgeMode;

/// Log severity emitted by the C bridge.
typedef enum {
    FUJI_LOG_VERBOSE = 0,
    FUJI_LOG_INFO = 1,
    FUJI_LOG_ERROR = 2
} FujiBridgeLogLevel;

/// Callback for routing C-level protocol logs back into Swift.
typedef void (*FujiBridgeLogCallback)(
    void *user_ctx,
    FujiBridgeLogLevel level,
    const char *message
);

/// Callback invoked for each downloaded chunk of an object.
/// Return 0 to continue, non-zero to cancel.
typedef int (*FujiBridgeChunkCallback)(
    void *user_ctx,
    const uint8_t *bytes,
    uint32_t length,
    uint32_t offset,
    uint32_t total_size
);

/// Information about a single SD card slot reported by the camera.
typedef struct {
    int32_t card_id;
    char name[64];
    uint32_t object_count;
} FujiBridgeCardInfo;

/// Diagnostic summary collected immediately after connecting to the camera.
typedef struct {
    char camera_name[64];
    int32_t camera_state;
    int32_t remote_version;
    int32_t remote_image_view_version;
    int32_t remote_image_view_ex_version;
    int32_t active_card_id;
    int32_t total_object_count;
    bool has_explicit_handle_list;
    FujiBridgeMode effective_mode;
    FujiBridgeCardInfo cards[2];
    uint32_t card_count;
} FujiBridgeSessionInfo;

/// Metadata for a single image/file stored on the camera SD card.
typedef struct {
    uint32_t handle;
    uint32_t storage_id;
    uint16_t object_format;
    uint32_t compressed_size;
    uint32_t image_width;
    uint32_t image_height;
    char filename[64];
    char date_created[32];
} FujiBridgeObjectInfo;

/// Allocates a new bridge session. Must be destroyed with `fuji_bridge_destroy`.
FujiBridgeSession *fuji_bridge_create(
    bool verbose,
    FujiBridgeLogCallback log_cb,
    void *log_ctx
);

/// Disconnects (if connected) and frees all session resources.
void fuji_bridge_destroy(FujiBridgeSession *session);

/// Optionally binds outgoing TCP sockets to a specific BSD interface (e.g. "en0")
/// via IP_BOUND_IF on macOS/iOS so traffic stays on the camera Wi-Fi hotspot.
void fuji_bridge_set_interface(FujiBridgeSession *session, const char *interface_name);

/// Requests cancellation of an in-progress transfer or setup step.
void fuji_bridge_request_cancel(FujiBridgeSession *session, bool cancel);

/// Connects over TCP to the camera and executes the Fujifilm PTP/IP setup sequence.
/// Returns 0 on success or a negative PtpRuntimeError code on failure.
int32_t fuji_bridge_connect(
    FujiBridgeSession *session,
    const char *ip_address,
    int32_t port,
    FujiBridgeMode mode,
    const char *client_name,
    FujiBridgeSessionInfo *out_info
);

/// Cleanly closes the PTP session and TCP sockets.
void fuji_bridge_disconnect(FujiBridgeSession *session);

/// Returns the number of accessible objects on the currently active card.
int32_t fuji_bridge_get_object_count(FujiBridgeSession *session);

/// Resolves a 0-based index into a Fujifilm PTP object handle (returns -1 if out of range).
int32_t fuji_bridge_get_handle_at(FujiBridgeSession *session, int32_t index);

/// Fetches metadata (filename, resolution, size, date) for a specific object handle.
int32_t fuji_bridge_get_object_info(
    FujiBridgeSession *session,
    uint32_t handle,
    FujiBridgeObjectInfo *out_info
);

/// Fetches the JPEG thumbnail for an object handle.
/// On success, `*out_data` points to a heap buffer that must be freed via `fuji_bridge_free_buffer`.
int32_t fuji_bridge_get_thumbnail(
    FujiBridgeSession *session,
    uint32_t handle,
    uint8_t **out_data,
    uint32_t *out_length
);

/// Downloads an object in chunks using Fujifilm's GetPartialObject protocol.
/// Set `compress_for_smartphone` to false for full-resolution JPEGs.
int32_t fuji_bridge_download_object(
    FujiBridgeSession *session,
    uint32_t handle,
    bool compress_for_smartphone,
    FujiBridgeObjectInfo *out_info,
    FujiBridgeChunkCallback chunk_cb,
    void *user_ctx
);

/// Switches active SD card slot (e.g., 1 or 2 on dual-slot bodies like the X-T4).
int32_t fuji_bridge_switch_card(
    FujiBridgeSession *session,
    int32_t card_id,
    FujiBridgeSessionInfo *out_info
);

/* ---------- Wi-Fi Live-View & Camera Controls ---------- */

/// Exposure step direction target for Fujifilm step opcodes (0x902C..0x902E).
typedef enum {
    FUJI_BRIDGE_STEP_SHUTTER = 0,
    FUJI_BRIDGE_STEP_FNUMBER = 1,
    FUJI_BRIDGE_STEP_EXPOSURE_BIAS = 2
} FujiBridgeStepKind;

/// Live exposure & camera status parsed from PTP_DPC_FUJI_EventsList_D212.
typedef struct {
    uint32_t iso;
    uint32_t fnumber;
    uint32_t shutter_speed;
    uint32_t film_simulation;
    int32_t exposure_bias;
    bool has_exposure_bias;
    uint32_t white_balance;
    uint32_t battery_level;
    uint32_t shots_remaining;
    uint32_t movie_remaining_sec;
    bool liveview_active;
} FujiBridgeLiveViewStatus;

/// Switches the active Wi-Fi session into Live-View mode and opens event/video sockets.
int32_t fuji_bridge_enter_liveview(FujiBridgeSession *session);

/// Exits Live-View mode cleanly and switches back to the image gallery without dropping Wi-Fi.
int32_t fuji_bridge_exit_liveview(
    FujiBridgeSession *session,
    FujiBridgeSessionInfo *out_info
);

/// Reads the next MJPEG Live-View JPEG frame from TCP port 55742 (non-blocking check on header).
/// If no frame is ready yet, returns 0 with `*out_data = NULL` and `*out_length = 0`.
/// Otherwise `*out_data` must be freed via `fuji_bridge_free_buffer`.
int32_t fuji_bridge_read_liveview_frame(
    FujiBridgeSession *session,
    uint8_t **out_data,
    uint32_t *out_length
);

/// Polls camera events (0xD212) and returns current ISO, aperture, shutter, film sim, etc.
int32_t fuji_bridge_get_liveview_status(
    FujiBridgeSession *session,
    FujiBridgeLiveViewStatus *out_status
);

/// Triggers a still photo capture over Wi-Fi (PTP_OC_InitiateCapture).
int32_t fuji_bridge_capture_photo(FujiBridgeSession *session);

/// Starts (`start == true`) or stops (`start == false`) movie recording over Wi-Fi (0x9020/0x9021).
int32_t fuji_bridge_set_movie_recording(FujiBridgeSession *session, bool start);

/// Steps shutter speed, aperture, or exposure bias up/down by one increment.
int32_t fuji_bridge_step_control(
    FujiBridgeSession *session,
    FujiBridgeStepKind kind,
    bool step_up
);

/// Copies the camera's supported raw values for a property (from GetPropertyDescriptors 0x902B).
int32_t fuji_bridge_get_prop_options(
    FujiBridgeSession *session,
    uint16_t prop_code,
    uint32_t *out_values,
    uint32_t max_count,
    uint32_t *out_count
);

/// Sets a 16-bit PTP device property (e.g. FilmSimulation 0xD001, WhiteBalance 0x5005).
int32_t fuji_bridge_set_prop_u16(
    FujiBridgeSession *session,
    uint16_t prop_code,
    uint16_t value
);

/// Sets a 32-bit PTP device property (e.g. ExposureIndex / ISO 0xD02A).
int32_t fuji_bridge_set_prop_u32(
    FujiBridgeSession *session,
    uint16_t prop_code,
    uint32_t value
);

/// Applies a camera-side XApp star rating bitmask filter (0xD603) and reloads filtered handles (0xD621).
/// Bit 0 = 0 stars .. Bit 5 = 5 stars; 0x3F = all photos.
int32_t fuji_bridge_apply_star_filter(
    FujiBridgeSession *session,
    uint16_t star_bitmask,
    FujiBridgeSessionInfo *out_info
);

/// Copies the last error message recorded on this session into `buffer`.
void fuji_bridge_get_last_error(
    FujiBridgeSession *session,
    char *buffer,
    size_t buffer_size
);

/// Frees a heap buffer returned by `fuji_bridge_get_thumbnail`.
void fuji_bridge_free_buffer(uint8_t *buffer);

/// Returns a human-readable description for a libpict/libfuji status code.
const char *fuji_bridge_error_string(int32_t code);

#ifdef __cplusplus
}
#endif

#endif /* FUJI_BRIDGE_H */
