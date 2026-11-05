/* dklinktd.h: the C interface between the DK Link library and the
 * TouchDesigner custom operators (DK Link TOP / CHOP for macOS).
 *
 * One process-wide session owns the camera; every operator instance holds a
 * reference and reads whichever image or bodies it wants. Images are handed
 * over as CPU buffers in the layout TouchDesigner's CPU-memory upload takes. */
#ifndef DKLINKTD_H
#define DKLINKTD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ktd_session ktd_session;

/* Menu orders match the operators' parameter menus; keep them in sync. */
typedef enum {
    KTD_DEPTH_OFF = 0,
    KTD_DEPTH_NFOV_2X2BINNED,
    KTD_DEPTH_NFOV_UNBINNED,
    KTD_DEPTH_WFOV_2X2BINNED,
    KTD_DEPTH_WFOV_UNBINNED,
    KTD_DEPTH_PASSIVE_IR,
} ktd_depth_mode;

typedef enum {
    KTD_COLOR_OFF = 0,
    KTD_COLOR_720P,
    KTD_COLOR_1080P,
    KTD_COLOR_1440P,
    KTD_COLOR_1536P,
    KTD_COLOR_2160P,
    KTD_COLOR_3072P,
} ktd_color_resolution;

typedef enum { KTD_FPS_5 = 0, KTD_FPS_15, KTD_FPS_30 } ktd_fps;

typedef struct {
    ktd_depth_mode depth_mode;
    ktd_color_resolution color_resolution;
    ktd_fps fps;
    bool body_tracking;
    int32_t device_index; /* which camera, by serial order */
} ktd_config;

/* Images an operator can ask for. */
typedef enum {
    KTD_IMAGE_COLOR = 0,          /* BGRA8, colour resolution */
    KTD_IMAGE_DEPTH,              /* R32F metres, depth resolution (0 = invalid) */
    KTD_IMAGE_DEPTH_MM,           /* R16 (uint16 millimetres), depth resolution */
    KTD_IMAGE_IR,                 /* R32F normalised 0..1 (IR / 65535), depth resolution */
    KTD_IMAGE_POINT_CLOUD,        /* RGBA32F xyz metres in the depth camera's frame, a = 1 valid, depth resolution */
    KTD_IMAGE_COLOR_POINT_CLOUD,  /* RGBA32F xyz metres in the colour camera's frame, colour resolution */
    KTD_IMAGE_DEPTH_IN_COLOR,     /* R32F metres, colour resolution */
    KTD_IMAGE_COLOR_IN_DEPTH,     /* BGRA8, depth resolution */
    KTD_IMAGE_PLAYER_INDEX,       /* R8: 0 = none, else body id, depth resolution (from the person boxes) */
    KTD_IMAGE_COUNT
} ktd_image_kind;

typedef enum { KTD_PIXEL_BGRA8 = 0, KTD_PIXEL_R16, KTD_PIXEL_R32F, KTD_PIXEL_RGBA32F, KTD_PIXEL_R8 } ktd_pixel_format;

typedef struct {
    int32_t width;
    int32_t height;
    ktd_pixel_format pixel_format;
    size_t bytes;                   /* width * height * bytes per pixel, tightly packed, top row first */
    uint64_t frame_id;              /* increases with every capture */
    uint64_t device_timestamp_usec; /* the depth (or colour) frame's device time */
} ktd_image_info;

/* The process-wide session, reference counted. */
ktd_session *ktd_session_acquire(void);
void ktd_session_release(ktd_session *session);

/* Applies a configuration; restarts the camera when it changed. active=false
 * stops it. Returns 0 on success, else an error you can read with ktd_status. */
int ktd_session_configure(ktd_session *session, const ktd_config *config, bool active);

/* Copies the newest image of a kind into dst when its frame_id is newer than
 * `since`. Returns the frame id delivered, or 0 when nothing newer exists (or
 * the kind is unavailable in the current configuration). With dst == NULL only
 * `info` is filled (to size a buffer). */
uint64_t ktd_session_latest_image(ktd_session *session, ktd_image_kind kind, uint64_t since,
                                  ktd_image_info *info, void *dst, size_t dst_capacity);

/* Bodies. Joint order and names follow Microsoft's k4abt where there is a
 * counterpart; joints Vision does not provide are marked invalid. */
#define KTD_JOINT_COUNT 32
typedef struct {
    float x, y, z;         /* metres, depth camera frame (x right, y down, z forward) */
    float pixel_x, pixel_y;/* colour pixels */
    float confidence;      /* 0..1 */
    bool valid;
} ktd_joint;

typedef struct {
    int32_t id;            /* stable across frames */
    bool pose;             /* true: joints from the pose detector; false: only a box + centre */
    float bbox[4];         /* colour pixels x y w h, or all 0 */
    ktd_joint joints[KTD_JOINT_COUNT];
} ktd_body;

/* Fills up to `max` bodies from the newest tracking result; returns the count
 * and the frame id it belongs to. */
int32_t ktd_session_bodies(ktd_session *session, ktd_body *out, int32_t max, uint64_t *frame_id);
const char *ktd_joint_name(int32_t index); /* k4abt name, e.g. "pelvis"; NULL past the end */

/* Diagnostics for the Info CHOP/DAT. */
typedef enum {
    KTD_STAT_CAPTURES_PER_SECOND = 0,
    KTD_STAT_DECODE_MILLISECONDS,
    KTD_STAT_SENSOR_TEMPERATURE_C,
    KTD_STAT_BODY_MILLISECONDS,
    KTD_STAT_BODY_COUNT,
    KTD_STAT_DEVICES,
    KTD_STAT_COUNT
} ktd_stat;
double ktd_session_stat(ktd_session *session, ktd_stat stat);
/* A one-line status ("Streaming from 000146321712", "No Azure Kinect connected", an error). */
void ktd_session_status(ktd_session *session, char *out, size_t capacity);
void ktd_session_serial(ktd_session *session, char *out, size_t capacity);
/* The depth camera calibration as JSON text, for the Info DAT. */
size_t ktd_session_calibration_json(ktd_session *session, char *out, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif /* DKLINKTD_H */
