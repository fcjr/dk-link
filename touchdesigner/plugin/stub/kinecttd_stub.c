/* A stand-in for libKinectTD: synthetic images, one fake body, plausible
 * stats. Lets the TouchDesigner operators be built and tested without a
 * camera or the real library. Built into a libKinectTD.dylib with the same
 * install name, so the plugin layout is identical. */
#include "../kinecttd.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct ktd_session {
    int refs;
    ktd_config config;
    bool active;
    uint64_t start_ns;
};

static struct ktd_session *shared;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

ktd_session *ktd_session_acquire(void) {
    pthread_mutex_lock(&lock);
    if (!shared) {
        shared = calloc(1, sizeof *shared);
        shared->start_ns = now_ns();
        shared->config.depth_mode = KTD_DEPTH_NFOV_UNBINNED;
        shared->config.color_resolution = KTD_COLOR_720P;
        shared->config.fps = KTD_FPS_30;
    }
    shared->refs++;
    pthread_mutex_unlock(&lock);
    return shared;
}

void ktd_session_release(ktd_session *s) {
    pthread_mutex_lock(&lock);
    if (s && s == shared && --shared->refs == 0) { free(shared); shared = NULL; }
    pthread_mutex_unlock(&lock);
}

int ktd_session_configure(ktd_session *s, const ktd_config *config, bool active) {
    if (!s || !config) return 1;
    s->config = *config;
    s->active = active;
    return 0;
}

static void depth_size(const ktd_config *c, int32_t *w, int32_t *h) {
    switch (c->depth_mode) {
    case KTD_DEPTH_NFOV_2X2BINNED: *w = 320; *h = 288; break;
    case KTD_DEPTH_NFOV_UNBINNED: *w = 640; *h = 576; break;
    case KTD_DEPTH_WFOV_2X2BINNED: *w = 512; *h = 512; break;
    case KTD_DEPTH_WFOV_UNBINNED: case KTD_DEPTH_PASSIVE_IR: *w = 1024; *h = 1024; break;
    default: *w = 0; *h = 0; break;
    }
}

static void color_size(const ktd_config *c, int32_t *w, int32_t *h) {
    switch (c->color_resolution) {
    case KTD_COLOR_720P: *w = 1280; *h = 720; break;
    case KTD_COLOR_1080P: *w = 1920; *h = 1080; break;
    case KTD_COLOR_1440P: *w = 2560; *h = 1440; break;
    case KTD_COLOR_1536P: *w = 2048; *h = 1536; break;
    case KTD_COLOR_2160P: *w = 3840; *h = 2160; break;
    case KTD_COLOR_3072P: *w = 4096; *h = 3072; break;
    default: *w = 0; *h = 0; break;
    }
}

/* A frame every 33 ms of wall time. */
static uint64_t frame_now(const ktd_session *s) { return (now_ns() - s->start_ns) / 33333333ull + 1; }

uint64_t ktd_session_latest_image(ktd_session *s, ktd_image_kind kind, uint64_t since,
                                  ktd_image_info *info, void *dst, size_t cap) {
    if (!s || !info || !s->active) return 0;
    int32_t w = 0, h = 0; ktd_pixel_format fmt; size_t bpp;
    switch (kind) {
    case KTD_IMAGE_COLOR: color_size(&s->config, &w, &h); fmt = KTD_PIXEL_BGRA8; bpp = 4; break;
    case KTD_IMAGE_COLOR_POINT_CLOUD: color_size(&s->config, &w, &h); fmt = KTD_PIXEL_RGBA32F; bpp = 16; break;
    case KTD_IMAGE_DEPTH_IN_COLOR: color_size(&s->config, &w, &h); fmt = KTD_PIXEL_R32F; bpp = 4; break;
    case KTD_IMAGE_DEPTH: depth_size(&s->config, &w, &h); fmt = KTD_PIXEL_R32F; bpp = 4; break;
    case KTD_IMAGE_DEPTH_MM: depth_size(&s->config, &w, &h); fmt = KTD_PIXEL_R16; bpp = 2; break;
    case KTD_IMAGE_IR: depth_size(&s->config, &w, &h); fmt = KTD_PIXEL_R32F; bpp = 4; break;
    case KTD_IMAGE_POINT_CLOUD: depth_size(&s->config, &w, &h); fmt = KTD_PIXEL_RGBA32F; bpp = 16; break;
    case KTD_IMAGE_COLOR_IN_DEPTH: depth_size(&s->config, &w, &h); fmt = KTD_PIXEL_BGRA8; bpp = 4; break;
    case KTD_IMAGE_PLAYER_INDEX: depth_size(&s->config, &w, &h); fmt = KTD_PIXEL_R8; bpp = 1; break;
    default: return 0;
    }
    if (w == 0 || h == 0) return 0;
    uint64_t frame = frame_now(s);
    memset(info, 0, sizeof *info);
    info->width = w; info->height = h; info->pixel_format = fmt;
    info->bytes = (size_t)w * h * bpp; info->frame_id = frame;
    info->device_timestamp_usec = frame * 33333ull;
    if (frame <= since) return 0;
    if (!dst) return frame;
    if (cap < info->bytes) return 0;
    const float t = (float)(frame % 300) / 300.0f; /* a bar that sweeps across every 10 s */
    for (int32_t y = 0; y < h; y++) {
        for (int32_t x = 0; x < w; x++) {
            size_t i = (size_t)y * w + x;
            float fx = (float)x / (float)w, fy = (float)y / (float)h;
            bool bar = fabsf(fx - t) < 0.02f;
            switch (fmt) {
            case KTD_PIXEL_BGRA8: {
                uint8_t *p = (uint8_t *)dst + i * 4;
                p[0] = (uint8_t)(fy * 255); p[1] = (uint8_t)(fx * 255); p[2] = bar ? 255 : 40; p[3] = 255; break; }
            case KTD_PIXEL_R16: ((uint16_t *)dst)[i] = (uint16_t)(500 + fx * 4000 + (bar ? 1000 : 0)); break;
            case KTD_PIXEL_R32F: ((float *)dst)[i] = kind == KTD_IMAGE_IR ? fx * fy : 0.5f + fx * 4.0f + (bar ? 1.0f : 0.0f); break;
            case KTD_PIXEL_RGBA32F: { float *p = (float *)dst + i * 4; float z = 0.5f + fx * 4.0f;
                p[0] = (fx - 0.5f) * z; p[1] = (fy - 0.5f) * z; p[2] = z; p[3] = 1.0f; break; }
            case KTD_PIXEL_R8: ((uint8_t *)dst)[i] = (fx > 0.4f && fx < 0.6f && fy > 0.2f && fy < 0.9f) ? 1 : 0; break;
            }
        }
    }
    return frame;
}

static const char *const joint_names[KTD_JOINT_COUNT] = {
    "pelvis", "spine_navel", "spine_chest", "neck", "clavicle_left", "shoulder_left", "elbow_left", "wrist_left",
    "hand_left", "handtip_left", "thumb_left", "clavicle_right", "shoulder_right", "elbow_right", "wrist_right",
    "hand_right", "handtip_right", "thumb_right", "hip_left", "knee_left", "ankle_left", "foot_left", "hip_right",
    "knee_right", "ankle_right", "foot_right", "head", "nose", "eye_left", "ear_left", "eye_right", "ear_right",
};

const char *ktd_joint_name(int32_t index) {
    return index >= 0 && index < KTD_JOINT_COUNT ? joint_names[index] : NULL;
}

int32_t ktd_session_bodies(ktd_session *s, ktd_body *out, int32_t max, uint64_t *frame_id) {
    if (!s || !out || max < 1 || !s->active || !s->config.body_tracking) { if (frame_id) *frame_id = 0; return 0; }
    uint64_t frame = frame_now(s);
    if (frame_id) *frame_id = frame;
    int32_t cw, ch; color_size(&s->config, &cw, &ch);
    if (cw == 0) { cw = 1280; ch = 720; }
    const float a = (float)(frame % 180) / 180.0f * 6.2831853f;
    memset(out, 0, sizeof *out);
    out->id = 1;
    out->pose = true;
    const float cx = 0.5f + 0.2f * cosf(a), cy = 0.5f + 0.1f * sinf(a);
    out->bbox[0] = (cx - 0.1f) * cw; out->bbox[1] = (cy - 0.3f) * ch; out->bbox[2] = 0.2f * cw; out->bbox[3] = 0.6f * ch;
    for (int32_t j = 0; j < KTD_JOINT_COUNT; j++) {
        ktd_joint *jt = &out->joints[j];
        const float fy = cy - 0.3f + 0.6f * (float)j / (KTD_JOINT_COUNT - 1);
        jt->pixel_x = cx * cw + 20.0f * sinf((float)j); jt->pixel_y = fy * ch;
        jt->z = 2.0f; jt->x = (cx - 0.5f) * 2.0f; jt->y = (fy - 0.5f) * 1.2f;
        jt->confidence = 0.9f; jt->valid = true;
    }
    return 1;
}

double ktd_session_stat(ktd_session *s, ktd_stat stat) {
    if (!s) return 0;
    switch (stat) {
    case KTD_STAT_CAPTURES_PER_SECOND: return s->active ? 30.0 : 0.0;
    case KTD_STAT_DECODE_MILLISECONDS: return 1.4;
    case KTD_STAT_SENSOR_TEMPERATURE_C: return 31.5;
    case KTD_STAT_BODY_MILLISECONDS: return 12.0;
    case KTD_STAT_BODY_COUNT: return s->config.body_tracking ? 1 : 0;
    case KTD_STAT_DEVICES: return 1;
    default: return 0;
    }
}

void ktd_session_status(ktd_session *s, char *out, size_t cap) {
    snprintf(out, cap, "%s", s && s->active ? "Streaming from STUB00000000 (stub library)" : "Stub library, inactive");
}

void ktd_session_serial(ktd_session *s, char *out, size_t cap) { (void)s; snprintf(out, cap, "STUB00000000"); }

size_t ktd_session_calibration_json(ktd_session *s, char *out, size_t cap) {
    (void)s; return (size_t)snprintf(out, cap, "{\"stub\":true}");
}
