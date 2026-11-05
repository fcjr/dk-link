/*=============================================================================
  k4arecord: writing.

  The file is laid out the way the SDK's own recorder lays it out, so the
  SDK, ffmpeg and this tree all read it: EBML head; Segment with an 8-byte
  size (unknown until the end); a Void reserving 1 KB for the SeekHead and
  256 bytes for the Info, both written at flush; Tracks; Attachments; Tags
  followed by a 1 KB Void so the tags can grow (K4A_START_OFFSET_NS is only
  known at the first cluster); then Clusters of at most 32 ms, each block's
  timestamp relative to the first written one; Cues at the end.

  Video tracks are V_MS/VFW/FOURCC with a BITMAPINFOHEADER: b16g (big-endian
  16-bit grey) for depth and IR, the colour format's FOURCC for colour. The
  IMU is a subtitle track S_K4A/IMU whose samples are laced, one BlockGroup
  per cluster with a BlockDuration, 40 bytes a sample.
=============================================================================*/

#include "openk4a.h"
#include "openk4a_matroska.h"

#include <k4arecord/record.h>

#include <time.h>

#define RECORD_TIMECODE_SCALE_NS 1000ULL
#define RECORD_MAX_CLUSTER_NS 32000000ULL
#define RECORD_CLUSTER_WRITE_DELAY_NS 2000000000ULL
#define RECORD_CUE_GAP_NS 1000000000ULL
#define RECORD_SEEK_VOID 1024
#define RECORD_INFO_VOID 256
#define RECORD_TAGS_VOID 1024
#define RECORD_MAX_TRACKS 32
#define RECORD_MAX_TAGS 256
#define RECORD_MAX_ATTACHMENTS 32

typedef enum
{
    TAG_TARGET_NONE,
    TAG_TARGET_TRACK,
    TAG_TARGET_ATTACHMENT
} tag_target_t;

typedef struct
{
    char *name;
    char *value;
    tag_target_t target;
    uint64_t target_uid;
} record_tag_t;

typedef struct
{
    char *file_name;
    char *mime_type;
    uint8_t *data;
    size_t size;
    uint64_t uid;
} record_attachment_t;

typedef struct
{
    char *name;
    uint64_t number;
    uint64_t uid;
    int type;
    char *codec_id;
    uint8_t *codec_private;
    size_t codec_private_size;
    uint64_t width, height, default_duration_ns;
    bool custom;
    bool high_freq;
} record_track_t;

typedef struct record_data
{
    record_track_t *track;
    uint64_t timestamp_ns;
    uint8_t *data;
    size_t size;
    struct record_data *next;
} record_data_t;

typedef struct record_cluster
{
    uint64_t start_ns;
    uint64_t end_ns;
    record_data_t *first; /* unsorted; sorted at write */
    size_t count;
    struct record_cluster *next;
} record_cluster_t;

typedef struct
{
    uint64_t time_ns;      /* relative to start offset */
    uint64_t position;     /* cluster position relative to the segment's data */
    uint64_t block_number;
} record_cue_t;

typedef struct
{
    char *path;
    FILE *file;
    k4a_device_configuration_t config;
    uint32_t fps;

    record_track_t tracks[RECORD_MAX_TRACKS];
    size_t track_count;
    record_track_t *color_track, *depth_track, *ir_track, *imu_track;

    record_tag_t tags[RECORD_MAX_TAGS];
    size_t tag_count;
    record_attachment_t attachments[RECORD_MAX_ATTACHMENTS];
    size_t attachment_count;

    bool header_written;
    uint64_t segment_data_offset;  /* file offset where the segment's data begins */
    uint64_t seek_void_offset;
    uint64_t info_void_offset;
    uint64_t tracks_offset;
    uint64_t attachments_offset;
    uint64_t tags_offset;
    size_t tags_region_size;       /* tags + void, available for rewriting */
    uint64_t data_end_offset;      /* where the next cluster goes */

    record_cluster_t *pending;
    uint64_t most_recent_ns;
    uint64_t last_written_ns;
    bool first_cluster_written;
    uint64_t start_offset_ns;
    bool start_offset_tag_added;

    record_cue_t *cues;
    size_t cue_count, cue_capacity;
    uint64_t last_cue_ns;
    bool have_cue;
} record_context_t;

/*-----------------------------------------------------------------------------
  small helpers
---------------------------------------------------------------------------*/

static char *dup_string(const char *text)
{
    const size_t n = strlen(text) + 1;
    char *copy = (char *)openk4a_alloc(n);
    if (copy != NULL)
    {
        memcpy(copy, text, n);
    }
    return copy;
}

static uint64_t new_uid(void)
{
    static bool seeded;
    if (!seeded)
    {
        srand((unsigned)time(NULL) ^ (unsigned)(uintptr_t)&seeded);
        seeded = true;
    }
    uint64_t value = 0;
    do
    {
        for (int i = 0; i < 4; i++)
        {
            value = (value << 15) | (uint64_t)(rand() & 0x7FFF);
        }
    } while (value == 0);
    return value;
}

static bool valid_name(const char *name)
{
    for (const char *c = name; *c != '\0'; c++)
    {
        if (!(*c == '-' || *c == '_' || (*c >= '0' && *c <= '9') || (*c >= 'A' && *c <= 'Z')))
        {
            openk4a_log(OPENK4A_LOG_ERROR, "names must be ALL CAPS and only A-Z, 0-9, '-' and '_': %s", name);
            return false;
        }
    }
    return true;
}

static bool add_tag(record_context_t *context, const char *name, const char *value, tag_target_t target, uint64_t uid)
{
    if (context->tag_count >= RECORD_MAX_TAGS || !valid_name(name))
    {
        return false;
    }
    record_tag_t *tag = &context->tags[context->tag_count];
    tag->name = dup_string(name);
    tag->value = dup_string(value);
    tag->target = target;
    tag->target_uid = uid;
    if (tag->name == NULL || tag->value == NULL)
    {
        return false;
    }
    context->tag_count++;
    return true;
}

static record_track_t *add_track(record_context_t *context, const char *name, int type, const char *codec,
                                 const uint8_t *codec_private, size_t codec_private_size)
{
    if (context->header_written || !valid_name(name) || context->track_count >= RECORD_MAX_TRACKS)
    {
        return NULL;
    }
    for (size_t i = 0; i < context->track_count; i++)
    {
        if (strcmp(context->tracks[i].name, name) == 0)
        {
            openk4a_log(OPENK4A_LOG_ERROR, "a track already exists with the name %s", name);
            return NULL;
        }
    }
    record_track_t *track = &context->tracks[context->track_count];
    memset(track, 0, sizeof(*track));
    track->name = dup_string(name);
    track->codec_id = dup_string(codec);
    track->number = context->track_count + 1;
    track->uid = new_uid();
    track->type = type;
    if (codec_private != NULL && codec_private_size > 0)
    {
        track->codec_private = (uint8_t *)openk4a_alloc(codec_private_size);
        if (track->codec_private == NULL)
        {
            return NULL;
        }
        memcpy(track->codec_private, codec_private, codec_private_size);
        track->codec_private_size = codec_private_size;
    }
    if (track->name == NULL || track->codec_id == NULL)
    {
        return NULL;
    }
    context->track_count++;
    return track;
}

#pragma pack(push, 1)
typedef struct
{
    uint32_t biSize;
    uint32_t biWidth;
    uint32_t biHeight;
    uint16_t biPlanes;
    uint16_t biBitCount;
    uint32_t biCompression;
    uint32_t biSizeImage;
    uint32_t biXPelsPerMeter;
    uint32_t biYPelsPerMeter;
    uint32_t biClrUsed;
    uint32_t biClrImportant;
} bitmap_info_header_t;

typedef struct
{
    uint64_t acc_timestamp_ns;
    float acc_data[3];
    uint64_t gyro_timestamp_ns;
    float gyro_data[3];
} matroska_imu_sample_t;
#pragma pack(pop)

static bool bitmap_header(bitmap_info_header_t *header, uint32_t width, uint32_t height, k4a_image_format_t format)
{
    memset(header, 0, sizeof(*header));
    header->biSize = sizeof(*header);
    header->biWidth = width;
    header->biHeight = height;
    header->biPlanes = 1;
    switch (format)
    {
    case K4A_IMAGE_FORMAT_COLOR_NV12:
        header->biBitCount = 12;
        header->biCompression = 0x3231564E;
        header->biSizeImage = width * height * 3 / 2;
        break;
    case K4A_IMAGE_FORMAT_COLOR_YUY2:
        header->biBitCount = 16;
        header->biCompression = 0x32595559;
        header->biSizeImage = width * height * 2;
        break;
    case K4A_IMAGE_FORMAT_COLOR_MJPG:
        header->biBitCount = 24;
        header->biCompression = 0x47504A4D;
        header->biSizeImage = 0;
        break;
    case K4A_IMAGE_FORMAT_DEPTH16:
    case K4A_IMAGE_FORMAT_IR16:
        header->biBitCount = 16;
        header->biCompression = 0x67363162; /* b16g */
        header->biSizeImage = width * height * 2;
        break;
    case K4A_IMAGE_FORMAT_COLOR_BGRA32:
        header->biBitCount = 32;
        header->biCompression = 0x41524742;
        header->biSizeImage = width * height * 4;
        break;
    default:
        openk4a_log(OPENK4A_LOG_ERROR, "unsupported colour format in recording: %d", (int)format);
        return false;
    }
    return true;
}

static uint32_t fps_of(k4a_fps_t fps)
{
    switch (fps)
    {
    case K4A_FRAMES_PER_SECOND_5:
        return 5;
    case K4A_FRAMES_PER_SECOND_15:
        return 15;
    default:
        return 30;
    }
}

static const char *depth_mode_name(k4a_depth_mode_t mode)
{
    switch (mode)
    {
    case K4A_DEPTH_MODE_NFOV_2X2BINNED:
        return "NFOV_2X2BINNED";
    case K4A_DEPTH_MODE_NFOV_UNBINNED:
        return "NFOV_UNBINNED";
    case K4A_DEPTH_MODE_WFOV_2X2BINNED:
        return "WFOV_2X2BINNED";
    case K4A_DEPTH_MODE_WFOV_UNBINNED:
        return "WFOV_UNBINNED";
    case K4A_DEPTH_MODE_PASSIVE_IR:
        return "PASSIVE_IR";
    default:
        return "OFF";
    }
}

static void add_track_uid_tag(record_context_t *context, const char *tag_name, record_track_t *track)
{
    char uid[32];
    snprintf(uid, sizeof(uid), "%llu", (unsigned long long)track->uid);
    add_tag(context, tag_name, uid, TAG_TARGET_TRACK, track->uid);
}

/*=============================================================================
  Create
=============================================================================*/

static void context_free(record_context_t *context)
{
    if (context == NULL)
    {
        return;
    }
    for (size_t i = 0; i < context->track_count; i++)
    {
        openk4a_free(context->tracks[i].name);
        openk4a_free(context->tracks[i].codec_id);
        openk4a_free(context->tracks[i].codec_private);
    }
    for (size_t i = 0; i < context->tag_count; i++)
    {
        openk4a_free(context->tags[i].name);
        openk4a_free(context->tags[i].value);
    }
    for (size_t i = 0; i < context->attachment_count; i++)
    {
        openk4a_free(context->attachments[i].file_name);
        openk4a_free(context->attachments[i].mime_type);
        openk4a_free(context->attachments[i].data);
    }
    while (context->pending != NULL)
    {
        record_cluster_t *cluster = context->pending;
        context->pending = cluster->next;
        while (cluster->first != NULL)
        {
            record_data_t *data = cluster->first;
            cluster->first = data->next;
            openk4a_free(data->data);
            openk4a_free(data);
        }
        openk4a_free(cluster);
    }
    openk4a_free(context->cues);
    openk4a_free(context->path);
    if (context->file != NULL)
    {
        fclose(context->file);
    }
    openk4a_free(context);
}

k4a_result_t k4a_record_create(const char *path,
                               k4a_device_t device,
                               const k4a_device_configuration_t device_config,
                               k4a_record_t *recording_handle)
{
    if (path == NULL || recording_handle == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    record_context_t *context = (record_context_t *)openk4a_alloc_zero(sizeof(record_context_t));
    if (context == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    context->path = dup_string(path);
    context->file = fopen(path, "w+b");
    if (context->path == NULL || context->file == NULL)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "unable to open file '%s' for recording", path);
        context_free(context);
        return K4A_RESULT_FAILED;
    }
    context->config = device_config;
    context->fps = fps_of(device_config.camera_fps);

    bool ok = true;
    int color_width = 0, color_height = 0;
    char color_mode[32] = "OFF";
    if (device_config.color_resolution != K4A_COLOR_RESOLUTION_OFF)
    {
        ok = openk4a_color_grid(device_config.color_resolution, &color_width, &color_height);
        const char *prefix = NULL;
        switch (device_config.color_format)
        {
        case K4A_IMAGE_FORMAT_COLOR_NV12: prefix = "NV12"; break;
        case K4A_IMAGE_FORMAT_COLOR_YUY2: prefix = "YUY2"; break;
        case K4A_IMAGE_FORMAT_COLOR_MJPG: prefix = "MJPG"; break;
        case K4A_IMAGE_FORMAT_COLOR_BGRA32: prefix = "BGRA"; break;
        default: ok = false; break;
        }
        if (ok)
        {
            snprintf(color_mode, sizeof(color_mode), "%s_%dP", prefix, color_height);
        }
    }
    int depth_width = 0, depth_height = 0;
    if (ok && device_config.depth_mode != K4A_DEPTH_MODE_OFF)
    {
        ok = openk4a_calibration_grid(device_config.depth_mode, &depth_width, &depth_height);
    }
    if (!ok)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "unsupported configuration in recording");
        context_free(context);
        return K4A_RESULT_FAILED;
    }

    bitmap_info_header_t info;
    if (device_config.color_resolution != K4A_COLOR_RESOLUTION_OFF)
    {
        ok = bitmap_header(&info, (uint32_t)color_width, (uint32_t)color_height, device_config.color_format);
        context->color_track = ok ? add_track(context, K4A_TRACK_NAME_COLOR, MKV_TRACK_TYPE_VIDEO, "V_MS/VFW/FOURCC",
                                              (const uint8_t *)&info, sizeof(info))
                                  : NULL;
        if (context->color_track == NULL)
        {
            context_free(context);
            return K4A_RESULT_FAILED;
        }
        context->color_track->width = (uint64_t)color_width;
        context->color_track->height = (uint64_t)color_height;
        context->color_track->default_duration_ns = 1000000000ULL / context->fps;
        add_track_uid_tag(context, "K4A_COLOR_TRACK", context->color_track);
        add_tag(context, "K4A_COLOR_MODE", color_mode, TAG_TARGET_TRACK, context->color_track->uid);
    }
    if (device_config.depth_mode == K4A_DEPTH_MODE_PASSIVE_IR)
    {
        add_tag(context, "K4A_DEPTH_MODE", depth_mode_name(device_config.depth_mode), TAG_TARGET_NONE, 0);
    }
    else if (device_config.depth_mode != K4A_DEPTH_MODE_OFF)
    {
        bitmap_header(&info, (uint32_t)depth_width, (uint32_t)depth_height, K4A_IMAGE_FORMAT_DEPTH16);
        context->depth_track = add_track(context, K4A_TRACK_NAME_DEPTH, MKV_TRACK_TYPE_VIDEO, "V_MS/VFW/FOURCC",
                                         (const uint8_t *)&info, sizeof(info));
        if (context->depth_track == NULL)
        {
            context_free(context);
            return K4A_RESULT_FAILED;
        }
        context->depth_track->width = (uint64_t)depth_width;
        context->depth_track->height = (uint64_t)depth_height;
        context->depth_track->default_duration_ns = 1000000000ULL / context->fps;
        add_track_uid_tag(context, "K4A_DEPTH_TRACK", context->depth_track);
        add_tag(context, "K4A_DEPTH_MODE", depth_mode_name(device_config.depth_mode), TAG_TARGET_TRACK, context->depth_track->uid);
    }
    if (device_config.depth_mode != K4A_DEPTH_MODE_OFF)
    {
        bitmap_header(&info, (uint32_t)depth_width, (uint32_t)depth_height, K4A_IMAGE_FORMAT_IR16);
        context->ir_track = add_track(context, K4A_TRACK_NAME_IR, MKV_TRACK_TYPE_VIDEO, "V_MS/VFW/FOURCC",
                                      (const uint8_t *)&info, sizeof(info));
        if (context->ir_track == NULL)
        {
            context_free(context);
            return K4A_RESULT_FAILED;
        }
        context->ir_track->width = (uint64_t)depth_width;
        context->ir_track->height = (uint64_t)depth_height;
        context->ir_track->default_duration_ns = 1000000000ULL / context->fps;
        add_track_uid_tag(context, "K4A_IR_TRACK", context->ir_track);
        add_tag(context, "K4A_IR_MODE", device_config.depth_mode == K4A_DEPTH_MODE_PASSIVE_IR ? "PASSIVE" : "ACTIVE",
                TAG_TARGET_TRACK, context->ir_track->uid);
    }
    if (device_config.color_resolution != K4A_COLOR_RESOLUTION_OFF && device_config.depth_mode != K4A_DEPTH_MODE_OFF)
    {
        char delay[32];
        snprintf(delay, sizeof(delay), "%lld", (long long)device_config.depth_delay_off_color_usec * 1000);
        add_tag(context, "K4A_DEPTH_DELAY_NS", delay, TAG_TARGET_NONE, 0);
    }
    switch (device_config.wired_sync_mode)
    {
    case K4A_WIRED_SYNC_MODE_MASTER:
        add_tag(context, "K4A_WIRED_SYNC_MODE", "MASTER", TAG_TARGET_NONE, 0);
        break;
    case K4A_WIRED_SYNC_MODE_SUBORDINATE: {
        add_tag(context, "K4A_WIRED_SYNC_MODE", "SUBORDINATE", TAG_TARGET_NONE, 0);
        char delay[32];
        snprintf(delay, sizeof(delay), "%llu", (unsigned long long)device_config.subordinate_delay_off_master_usec * 1000ULL);
        add_tag(context, "K4A_SUBORDINATE_DELAY_NS", delay, TAG_TARGET_NONE, 0);
        break;
    }
    default:
        add_tag(context, "K4A_WIRED_SYNC_MODE", "STANDALONE", TAG_TARGET_NONE, 0);
        break;
    }

    if (device != NULL)
    {
        k4a_hardware_version_t version;
        if (k4a_device_get_version(device, &version) == K4A_RESULT_SUCCEEDED)
        {
            char text[64];
            snprintf(text, sizeof(text), "%u.%u.%u", version.rgb.major, version.rgb.minor, version.rgb.iteration);
            add_tag(context, "K4A_COLOR_FIRMWARE_VERSION", text, TAG_TARGET_NONE, 0);
            snprintf(text, sizeof(text), "%u.%u.%u", version.depth.major, version.depth.minor, version.depth.iteration);
            add_tag(context, "K4A_DEPTH_FIRMWARE_VERSION", text, TAG_TARGET_NONE, 0);
        }
        char serial[256];
        size_t serial_size = sizeof(serial);
        if (k4a_device_get_serialnum(device, serial, &serial_size) == K4A_BUFFER_RESULT_SUCCEEDED)
        {
            add_tag(context, "K4A_DEVICE_SERIAL_NUMBER", serial, TAG_TARGET_NONE, 0);
        }
        size_t calibration_size = 0;
        if (k4a_device_get_raw_calibration(device, NULL, &calibration_size) == K4A_BUFFER_RESULT_TOO_SMALL)
        {
            uint8_t *calibration = (uint8_t *)openk4a_alloc(calibration_size);
            if (calibration != NULL &&
                k4a_device_get_raw_calibration(device, calibration, &calibration_size) == K4A_BUFFER_RESULT_SUCCEEDED)
            {
                if (calibration_size > 0 && calibration[calibration_size - 1] == '\0')
                {
                    calibration_size--;
                }
                if (k4a_record_add_attachment(*recording_handle = (k4a_record_t)context, "calibration.json", calibration,
                                              calibration_size) == K4A_RESULT_SUCCEEDED)
                {
                    const record_attachment_t *attachment = &context->attachments[context->attachment_count - 1];
                    add_tag(context, "K4A_CALIBRATION_FILE", "calibration.json", TAG_TARGET_ATTACHMENT, attachment->uid);
                }
                else
                {
                    ok = false;
                }
            }
            else
            {
                ok = false;
            }
            openk4a_free(calibration);
        }
        else
        {
            ok = false;
        }
        if (!ok)
        {
            openk4a_log(OPENK4A_LOG_ERROR, "the device's calibration could not be read for the recording");
            context_free(context);
            *recording_handle = NULL;
            return K4A_RESULT_FAILED;
        }
    }

    *recording_handle = (k4a_record_t)context;
    return K4A_RESULT_SUCCEEDED;
}

/*=============================================================================
  Tags, attachments and tracks before the header
=============================================================================*/

k4a_result_t k4a_record_add_tag(k4a_record_t recording_handle, const char *name, const char *value)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL || name == NULL || value == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (context->header_written)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "tags must be added before the recording header is written");
        return K4A_RESULT_FAILED;
    }
    return add_tag(context, name, value, TAG_TARGET_NONE, 0) ? K4A_RESULT_SUCCEEDED : K4A_RESULT_FAILED;
}

k4a_result_t k4a_record_add_attachment(const k4a_record_t recording_handle,
                                       const char *attachment_name,
                                       const uint8_t *buffer,
                                       size_t buffer_size)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL || attachment_name == NULL || buffer == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (context->header_written || context->attachment_count >= RECORD_MAX_ATTACHMENTS)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "attachments must be added before the recording header is written");
        return K4A_RESULT_FAILED;
    }
    record_attachment_t *attachment = &context->attachments[context->attachment_count];
    attachment->file_name = dup_string(attachment_name);
    attachment->mime_type = dup_string("application/octet-stream");
    attachment->data = (uint8_t *)openk4a_alloc(buffer_size > 0 ? buffer_size : 1);
    attachment->size = buffer_size;
    attachment->uid = new_uid();
    if (attachment->file_name == NULL || attachment->mime_type == NULL || attachment->data == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    memcpy(attachment->data, buffer, buffer_size);
    context->attachment_count++;
    return K4A_RESULT_SUCCEEDED;
}

k4a_result_t k4a_record_add_imu_track(k4a_record_t recording_handle)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (context->header_written || context->imu_track != NULL)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the IMU track must be added once, before the recording header is written");
        return K4A_RESULT_FAILED;
    }
    context->imu_track = add_track(context, K4A_TRACK_NAME_IMU, MKV_TRACK_TYPE_SUBTITLE, "S_K4A/IMU", NULL, 0);
    if (context->imu_track == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    context->imu_track->high_freq = true;
    add_track_uid_tag(context, "K4A_IMU_TRACK", context->imu_track);
    add_tag(context, "K4A_IMU_MODE", "ON", TAG_TARGET_TRACK, context->imu_track->uid);
    return K4A_RESULT_SUCCEEDED;
}

k4a_result_t k4a_record_add_custom_video_track(const k4a_record_t recording_handle,
                                               const char *track_name,
                                               const char *codec_id,
                                               const uint8_t *codec_context,
                                               size_t codec_context_size,
                                               const k4a_record_video_settings_t *track_settings)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL || track_name == NULL || codec_id == NULL || track_settings == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    record_track_t *track = add_track(context, track_name, MKV_TRACK_TYPE_VIDEO, codec_id, codec_context, codec_context_size);
    if (track == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    track->width = track_settings->width;
    track->height = track_settings->height;
    track->default_duration_ns = track_settings->frame_rate != 0 ? 1000000000ULL / track_settings->frame_rate : 0;
    track->custom = true;
    char tag_name[128];
    snprintf(tag_name, sizeof(tag_name), "K4A_CUSTOM_TRACK_%s", track_name);
    add_track_uid_tag(context, tag_name, track);
    return K4A_RESULT_SUCCEEDED;
}

k4a_result_t k4a_record_add_custom_subtitle_track(const k4a_record_t recording_handle,
                                                  const char *track_name,
                                                  const char *codec_id,
                                                  const uint8_t *codec_context,
                                                  size_t codec_context_size,
                                                  const k4a_record_subtitle_settings_t *track_settings)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL || track_name == NULL || codec_id == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    record_track_t *track = add_track(context, track_name, MKV_TRACK_TYPE_SUBTITLE, codec_id, codec_context, codec_context_size);
    if (track == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    track->high_freq = track_settings != NULL && track_settings->high_freq_data;
    track->custom = true;
    char tag_name[128];
    snprintf(tag_name, sizeof(tag_name), "K4A_CUSTOM_TRACK_%s", track_name);
    add_track_uid_tag(context, tag_name, track);
    return K4A_RESULT_SUCCEEDED;
}

/*=============================================================================
  Rendering the header pieces
=============================================================================*/

static bool render_tracks(record_context_t *context, mkv_buf_t *out)
{
    mkv_buf_t tracks;
    mkv_buf_init(&tracks);
    for (size_t i = 0; i < context->track_count; i++)
    {
        const record_track_t *track = &context->tracks[i];
        mkv_buf_t entry;
        mkv_buf_init(&entry);
        mkv_put_uint(&entry, MKV_ID_TRACK_NUMBER, track->number);
        mkv_put_uint(&entry, MKV_ID_TRACK_UID, track->uid);
        mkv_put_uint(&entry, MKV_ID_TRACK_TYPE, (uint64_t)track->type);
        mkv_put_uint(&entry, MKV_ID_FLAG_LACING, 1);
        if (track->default_duration_ns != 0)
        {
            mkv_put_uint(&entry, MKV_ID_DEFAULT_DURATION, track->default_duration_ns);
        }
        mkv_put_string(&entry, MKV_ID_TRACK_NAME, track->name);
        mkv_put_string(&entry, MKV_ID_CODEC_ID, track->codec_id);
        if (track->codec_private != NULL)
        {
            mkv_put_binary(&entry, MKV_ID_CODEC_PRIVATE, track->codec_private, track->codec_private_size);
        }
        if (track->type == MKV_TRACK_TYPE_VIDEO)
        {
            mkv_buf_t video;
            mkv_buf_init(&video);
            mkv_put_uint(&video, MKV_ID_PIXEL_WIDTH, track->width);
            mkv_put_uint(&video, MKV_ID_PIXEL_HEIGHT, track->height);
            mkv_put_master(&entry, MKV_ID_VIDEO, &video);
            mkv_buf_free(&video);
        }
        mkv_put_master(&tracks, MKV_ID_TRACK_ENTRY, &entry);
        mkv_buf_free(&entry);
    }
    const bool ok = mkv_put_master(out, MKV_ID_TRACKS, &tracks);
    mkv_buf_free(&tracks);
    return ok;
}

static bool render_attachments(record_context_t *context, mkv_buf_t *out)
{
    if (context->attachment_count == 0)
    {
        return true;
    }
    mkv_buf_t list;
    mkv_buf_init(&list);
    for (size_t i = 0; i < context->attachment_count; i++)
    {
        const record_attachment_t *attachment = &context->attachments[i];
        mkv_buf_t file;
        mkv_buf_init(&file);
        mkv_put_string(&file, MKV_ID_FILE_NAME, attachment->file_name);
        mkv_put_string(&file, MKV_ID_FILE_MIME_TYPE, attachment->mime_type);
        mkv_put_binary(&file, MKV_ID_FILE_DATA, attachment->data, attachment->size);
        mkv_put_uint(&file, MKV_ID_FILE_UID, attachment->uid);
        mkv_put_master(&list, MKV_ID_ATTACHED_FILE, &file);
        mkv_buf_free(&file);
    }
    const bool ok = mkv_put_master(out, MKV_ID_ATTACHMENTS, &list);
    mkv_buf_free(&list);
    return ok;
}

static bool render_tags(record_context_t *context, mkv_buf_t *out)
{
    mkv_buf_t tags;
    mkv_buf_init(&tags);
    for (size_t i = 0; i < context->tag_count; i++)
    {
        const record_tag_t *tag = &context->tags[i];
        mkv_buf_t entry, targets, simple;
        mkv_buf_init(&entry);
        mkv_buf_init(&targets);
        mkv_buf_init(&simple);
        switch (tag->target)
        {
        case TAG_TARGET_TRACK:
            mkv_put_string(&targets, MKV_ID_TARGET_TYPE, "TRACK");
            mkv_put_uint(&targets, MKV_ID_TAG_TRACK_UID, tag->target_uid);
            break;
        case TAG_TARGET_ATTACHMENT:
            mkv_put_string(&targets, MKV_ID_TARGET_TYPE, "ATTACHMENT");
            mkv_put_uint(&targets, MKV_ID_TAG_ATTACHMENT_UID, tag->target_uid);
            break;
        default:
            mkv_put_uint(&targets, MKV_ID_TAG_TRACK_UID, 0);
            break;
        }
        mkv_put_master(&entry, MKV_ID_TARGETS, &targets);
        mkv_put_string(&simple, MKV_ID_TAG_NAME, tag->name);
        mkv_put_string(&simple, MKV_ID_TAG_STRING, tag->value);
        mkv_put_master(&entry, MKV_ID_SIMPLE_TAG, &simple);
        mkv_put_master(&tags, MKV_ID_TAG, &entry);
        mkv_buf_free(&entry);
        mkv_buf_free(&targets);
        mkv_buf_free(&simple);
    }
    const bool ok = mkv_put_master(out, MKV_ID_TAGS, &tags);
    mkv_buf_free(&tags);
    return ok;
}

static bool render_info(record_context_t *context, mkv_buf_t *out, bool with_duration)
{
    mkv_buf_t info;
    mkv_buf_init(&info);
    mkv_put_uint(&info, MKV_ID_TIMECODE_SCALE, RECORD_TIMECODE_SCALE_NS);
    mkv_put_string(&info, MKV_ID_MUXING_APP, "openk4a-matroska");
    mkv_put_string(&info, MKV_ID_WRITING_APP, "k4arecord-1.4.2-openk4a");
    /* DateUTC: nanoseconds since 2001-01-01, as a signed 8-byte integer. */
    const int64_t date = ((int64_t)time(NULL) - 978307200LL) * 1000000000LL;
    uint8_t date_bytes[8];
    for (int i = 0; i < 8; i++)
    {
        date_bytes[7 - i] = (uint8_t)(((uint64_t)date >> (8 * i)) & 0xFF);
    }
    mkv_put_binary(&info, MKV_ID_DATE_UTC, date_bytes, 8);
    mkv_put_string(&info, MKV_ID_TITLE, "Azure Kinect");
    if (with_duration)
    {
        const uint64_t span = context->most_recent_ns > context->start_offset_ns ? context->most_recent_ns - context->start_offset_ns : 0;
        mkv_put_float(&info, MKV_ID_DURATION, (double)(span / RECORD_TIMECODE_SCALE_NS));
    }
    const bool ok = mkv_put_master(out, MKV_ID_INFO, &info);
    mkv_buf_free(&info);
    return ok;
}

static bool write_at(record_context_t *context, uint64_t offset, const void *data, size_t size)
{
    if (fseeko(context->file, (off_t)offset, SEEK_SET) != 0)
    {
        return false;
    }
    return fwrite(data, 1, size, context->file) == size;
}

k4a_result_t k4a_record_write_header(k4a_record_t recording_handle)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (context->header_written)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the header for this recording has already been written");
        return K4A_RESULT_FAILED;
    }

    mkv_buf_t out;
    mkv_buf_init(&out);
    {
        mkv_buf_t head;
        mkv_buf_init(&head);
        mkv_put_uint(&head, MKV_ID_EBML_VERSION, 1);
        mkv_put_uint(&head, MKV_ID_EBML_READ_VERSION, 1);
        mkv_put_uint(&head, MKV_ID_EBML_MAX_ID_LENGTH, 4);
        mkv_put_uint(&head, MKV_ID_EBML_MAX_SIZE_LENGTH, 8);
        mkv_put_string(&head, MKV_ID_DOCTYPE, "matroska");
        mkv_put_uint(&head, MKV_ID_DOCTYPE_VERSION, 2);
        mkv_put_uint(&head, MKV_ID_DOCTYPE_READ_VERSION, 2);
        mkv_put_master(&out, MKV_ID_EBML, &head);
        mkv_buf_free(&head);
    }
    /* The segment, with an 8-byte size that says "unknown" until flush. */
    mkv_put_header(&out, MKV_ID_SEGMENT, (1ULL << 56) - 1, 8);
    context->segment_data_offset = out.size;
    context->seek_void_offset = out.size;
    mkv_put_void(&out, RECORD_SEEK_VOID);
    context->info_void_offset = out.size;
    mkv_put_void(&out, RECORD_INFO_VOID);
    context->tracks_offset = out.size;
    render_tracks(context, &out);
    context->attachments_offset = context->attachment_count > 0 ? out.size : 0;
    render_attachments(context, &out);
    context->tags_offset = out.size;
    render_tags(context, &out);
    const size_t tags_size = out.size - context->tags_offset;
    mkv_put_void(&out, RECORD_TAGS_VOID);
    context->tags_region_size = tags_size + RECORD_TAGS_VOID;
    if (out.failed || !write_at(context, 0, out.data, out.size))
    {
        openk4a_log(OPENK4A_LOG_ERROR, "failed to write the recording header to '%s'", context->path);
        mkv_buf_free(&out);
        return K4A_RESULT_FAILED;
    }
    context->data_end_offset = out.size;
    mkv_buf_free(&out);
    context->header_written = true;
    return K4A_RESULT_SUCCEEDED;
}

/*=============================================================================
  Clusters
=============================================================================*/

static record_cluster_t *cluster_for(record_context_t *context, uint64_t timestamp_ns)
{
    if (context->first_cluster_written && timestamp_ns < context->last_written_ns)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the cluster containing timestamp %llu ns has already been written", (unsigned long long)timestamp_ns);
        return NULL;
    }
    /* Pending clusters are ordered oldest first. Find the newest one that starts at or before this timestamp. */
    record_cluster_t *selected = NULL;
    record_cluster_t *previous = NULL; /* the one before `selected`'s successor, for insertion */
    for (record_cluster_t *cluster = context->pending; cluster != NULL; cluster = cluster->next)
    {
        if (cluster->start_ns <= timestamp_ns)
        {
            selected = cluster;
        }
        else
        {
            break;
        }
    }
    if (selected != NULL && selected->end_ns > timestamp_ns)
    {
        return selected;
    }
    uint64_t start = selected == NULL ? context->last_written_ns : selected->end_ns;
    if (start + RECORD_MAX_CLUSTER_NS <= timestamp_ns)
    {
        const uint64_t diff = timestamp_ns - start;
        start += diff - (diff % RECORD_MAX_CLUSTER_NS);
    }
    record_cluster_t *cluster = (record_cluster_t *)openk4a_alloc_zero(sizeof(record_cluster_t));
    if (cluster == NULL)
    {
        return NULL;
    }
    cluster->start_ns = start;
    cluster->end_ns = start + RECORD_MAX_CLUSTER_NS;
    /* Insert after `selected` (or at the front). */
    if (selected == NULL)
    {
        cluster->next = context->pending;
        context->pending = cluster;
    }
    else
    {
        cluster->next = selected->next;
        selected->next = cluster;
    }
    (void)previous;
    return cluster;
}

static bool queue_data(record_context_t *context, record_track_t *track, uint64_t timestamp_ns, uint8_t *data, size_t size)
{
    if (!context->header_written)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the recording header needs to be written before any data");
        return false;
    }
    if (context->most_recent_ns < timestamp_ns)
    {
        context->most_recent_ns = timestamp_ns;
    }
    record_cluster_t *cluster = cluster_for(context, timestamp_ns);
    if (cluster == NULL)
    {
        return false;
    }
    record_data_t *entry = (record_data_t *)openk4a_alloc_zero(sizeof(record_data_t));
    if (entry == NULL)
    {
        return false;
    }
    entry->track = track;
    entry->timestamp_ns = timestamp_ns;
    entry->data = data;
    entry->size = size;
    entry->next = cluster->first;
    cluster->first = entry;
    cluster->count++;
    return true;
}

static int compare_data(const void *a, const void *b)
{
    const record_data_t *x = *(record_data_t *const *)a;
    const record_data_t *y = *(record_data_t *const *)b;
    if (x->timestamp_ns != y->timestamp_ns)
    {
        return x->timestamp_ns < y->timestamp_ns ? -1 : 1;
    }
    return x->track->number < y->track->number ? -1 : (x->track->number > y->track->number ? 1 : 0);
}

static bool add_cue(record_context_t *context, uint64_t time_ns, uint64_t position, uint64_t block_number)
{
    if (context->cue_count == context->cue_capacity)
    {
        const size_t capacity = context->cue_capacity == 0 ? 64 : context->cue_capacity * 2;
        record_cue_t *cues = (record_cue_t *)realloc(context->cues, capacity * sizeof(record_cue_t));
        if (cues == NULL)
        {
            return false;
        }
        context->cues = cues;
        context->cue_capacity = capacity;
    }
    context->cues[context->cue_count].time_ns = time_ns;
    context->cues[context->cue_count].position = position;
    context->cues[context->cue_count].block_number = block_number;
    context->cue_count++;
    return true;
}

/* Writes one cluster, frees it. The data is sorted by time; frames of one
 * high-frequency track that run together go into one laced BlockGroup, the
 * way the SDK writes the IMU; everything else is a SimpleBlock each. */
static bool write_cluster(record_context_t *context, record_cluster_t *cluster)
{
    bool ok = true;
    if (cluster->count == 0)
    {
        openk4a_free(cluster);
        return true;
    }
    record_data_t **items = (record_data_t **)openk4a_alloc(cluster->count * sizeof(record_data_t *));
    if (items == NULL)
    {
        return false;
    }
    size_t n = 0;
    for (record_data_t *d = cluster->first; d != NULL; d = d->next)
    {
        items[n++] = d;
    }
    qsort(items, n, sizeof(items[0]), compare_data);

    const uint64_t cluster_start_ns = items[0]->timestamp_ns;
    if (!context->first_cluster_written)
    {
        context->start_offset_ns = cluster_start_ns;
        context->first_cluster_written = true;
        if (!context->start_offset_tag_added)
        {
            char text[32];
            snprintf(text, sizeof(text), "%llu", (unsigned long long)context->start_offset_ns);
            add_tag(context, "K4A_START_OFFSET_NS", text, TAG_TARGET_NONE, 0);
            context->start_offset_tag_added = true;
        }
    }
    const uint64_t cluster_timecode = (cluster_start_ns - context->start_offset_ns) / RECORD_TIMECODE_SCALE_NS;

    mkv_buf_t body;
    mkv_buf_init(&body);
    mkv_put_uint(&body, MKV_ID_TIMECODE, cluster_timecode);
    const uint64_t cluster_position = context->data_end_offset - context->segment_data_offset;
    uint64_t block_number = 0;
    bool cue_added = false;

    for (size_t i = 0; i < n;)
    {
        record_data_t *first = items[i];
        const int16_t timecode = (int16_t)(((first->timestamp_ns - context->start_offset_ns) / RECORD_TIMECODE_SCALE_NS) - cluster_timecode);
        block_number++;
        if (first->track->high_freq)
        {
            /* All consecutive entries of this track into one laced block. */
            size_t count = 1;
            while (i + count < n && items[i + count]->track == first->track && count < 256)
            {
                count++;
            }
            bool fixed = true;
            for (size_t j = 1; j < count; j++)
            {
                if (items[i + j]->size != first->size)
                {
                    fixed = false;
                }
            }
            mkv_buf_t block;
            mkv_buf_init(&block);
            uint8_t head[4];
            size_t hn = mkv_write_vint(head, first->track->number, 0);
            head[hn++] = (uint8_t)((uint16_t)timecode >> 8);
            head[hn++] = (uint8_t)((uint16_t)timecode & 0xFF);
            head[hn++] = count > 1 ? (fixed ? MKV_LACING_FIXED : MKV_LACING_XIPH) : MKV_LACING_NONE;
            mkv_buf_append(&block, head, hn);
            if (count > 1)
            {
                const uint8_t lace_count = (uint8_t)(count - 1);
                mkv_buf_append(&block, &lace_count, 1);
                if (!fixed)
                {
                    for (size_t j = 0; j + 1 < count; j++)
                    {
                        size_t remaining = items[i + j]->size;
                        while (remaining >= 255)
                        {
                            const uint8_t full = 255;
                            mkv_buf_append(&block, &full, 1);
                            remaining -= 255;
                        }
                        const uint8_t last = (uint8_t)remaining;
                        mkv_buf_append(&block, &last, 1);
                    }
                }
            }
            for (size_t j = 0; j < count; j++)
            {
                mkv_buf_append(&block, items[i + j]->data, items[i + j]->size);
            }
            mkv_buf_t group;
            mkv_buf_init(&group);
            mkv_put_master(&group, MKV_ID_BLOCK, &block);
            const uint64_t duration = (items[i + count - 1]->timestamp_ns - first->timestamp_ns + RECORD_TIMECODE_SCALE_NS) / RECORD_TIMECODE_SCALE_NS;
            mkv_put_uint(&group, MKV_ID_BLOCK_DURATION, duration);
            mkv_put_master(&body, MKV_ID_BLOCK_GROUP, &group);
            mkv_buf_free(&group);
            mkv_buf_free(&block);
            i += count;
        }
        else
        {
            uint8_t head[4];
            size_t hn = mkv_write_vint(head, first->track->number, 0);
            head[hn++] = (uint8_t)((uint16_t)timecode >> 8);
            head[hn++] = (uint8_t)((uint16_t)timecode & 0xFF);
            head[hn++] = 0x80; /* keyframe, no lacing */
            mkv_put_header(&body, MKV_ID_SIMPLE_BLOCK, hn + first->size, 0);
            mkv_buf_append(&body, head, hn);
            mkv_buf_append(&body, first->data, first->size);
            i++;
        }
        /* One cue per cluster, on track 1, at most once a second. */
        if (!cue_added && first->track->number == 1)
        {
            const uint64_t relative = first->timestamp_ns - context->start_offset_ns;
            if (!context->have_cue || relative >= context->last_cue_ns + RECORD_CUE_GAP_NS)
            {
                add_cue(context, relative / RECORD_TIMECODE_SCALE_NS, cluster_position, block_number);
                context->last_cue_ns = relative;
                context->have_cue = true;
            }
            cue_added = true;
        }
    }

    mkv_buf_t out;
    mkv_buf_init(&out);
    mkv_put_master(&out, MKV_ID_CLUSTER, &body);
    if (out.failed || body.failed || !write_at(context, context->data_end_offset, out.data, out.size))
    {
        openk4a_log(OPENK4A_LOG_ERROR, "failed to write recording data to '%s'", context->path);
        ok = false;
    }
    else
    {
        context->data_end_offset += out.size;
    }
    mkv_buf_free(&out);
    mkv_buf_free(&body);

    for (size_t i = 0; i < n; i++)
    {
        openk4a_free(items[i]->data);
        openk4a_free(items[i]);
    }
    openk4a_free(items);
    context->last_written_ns = cluster->end_ns;
    openk4a_free(cluster);
    return ok;
}

/* Writes the pending clusters that are old enough to be complete. */
static bool write_settled_clusters(record_context_t *context)
{
    while (context->pending != NULL)
    {
        record_cluster_t *oldest = context->pending;
        if (context->most_recent_ns < oldest->end_ns || context->most_recent_ns - oldest->end_ns <= RECORD_CLUSTER_WRITE_DELAY_NS)
        {
            break;
        }
        context->pending = oldest->next;
        if (!write_cluster(context, oldest))
        {
            return false;
        }
    }
    return true;
}

/*=============================================================================
  Writing data
=============================================================================*/

k4a_result_t k4a_record_write_capture(k4a_record_t recording_handle, k4a_capture_t capture_handle)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL || capture_handle == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (!context->header_written)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the recording header needs to be written before any captures");
        return K4A_RESULT_FAILED;
    }
    k4a_image_t images[3] = { k4a_capture_get_color_image(capture_handle), k4a_capture_get_depth_image(capture_handle),
                              k4a_capture_get_ir_image(capture_handle) };
    const k4a_image_format_t expected[3] = { context->config.color_format, K4A_IMAGE_FORMAT_DEPTH16, K4A_IMAGE_FORMAT_IR16 };
    record_track_t *tracks[3] = { context->color_track, context->depth_track, context->ir_track };
    k4a_result_t result = K4A_RESULT_SUCCEEDED;
    for (int i = 0; i < 3; i++)
    {
        if (images[i] == NULL)
        {
            continue;
        }
        const size_t size = k4a_image_get_size(images[i]);
        const uint8_t *buffer = k4a_image_get_buffer(images[i]);
        if (buffer != NULL && size > 0 && tracks[i] != NULL)
        {
            if (k4a_image_get_format(images[i]) != expected[i])
            {
                openk4a_log(OPENK4A_LOG_ERROR, "tried to write a capture with an unexpected image format");
                result = K4A_RESULT_FAILED;
            }
            else
            {
                uint8_t *copy = (uint8_t *)openk4a_alloc(size);
                if (copy == NULL)
                {
                    result = K4A_RESULT_FAILED;
                }
                else
                {
                    memcpy(copy, buffer, size);
                    if (i != 0)
                    {
                        /* 16-bit grey is big-endian in the file. */
                        for (size_t j = 0; j + 1 < size; j += 2)
                        {
                            const uint8_t low = copy[j];
                            copy[j] = copy[j + 1];
                            copy[j + 1] = low;
                        }
                    }
                    const uint64_t timestamp_ns = k4a_image_get_device_timestamp_usec(images[i]) * 1000ULL;
                    if (!queue_data(context, tracks[i], timestamp_ns, copy, size))
                    {
                        openk4a_free(copy);
                        result = K4A_RESULT_FAILED;
                    }
                }
            }
        }
        k4a_image_release(images[i]);
    }
    if (!write_settled_clusters(context))
    {
        result = K4A_RESULT_FAILED;
    }
    return result;
}

k4a_result_t k4a_record_write_imu_sample(k4a_record_t recording_handle, k4a_imu_sample_t imu_sample)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (context->imu_track == NULL)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the IMU track needs to be added with k4a_record_add_imu_track() before IMU samples can be written");
        return K4A_RESULT_FAILED;
    }
    matroska_imu_sample_t *sample = (matroska_imu_sample_t *)openk4a_alloc(sizeof(matroska_imu_sample_t));
    if (sample == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    sample->acc_timestamp_ns = imu_sample.acc_timestamp_usec * 1000ULL;
    sample->gyro_timestamp_ns = imu_sample.gyro_timestamp_usec * 1000ULL;
    for (int i = 0; i < 3; i++)
    {
        sample->acc_data[i] = imu_sample.acc_sample.v[i];
        sample->gyro_data[i] = imu_sample.gyro_sample.v[i];
    }
    if (!queue_data(context, context->imu_track, sample->acc_timestamp_ns, (uint8_t *)sample, sizeof(*sample)))
    {
        openk4a_free(sample);
        return K4A_RESULT_FAILED;
    }
    return write_settled_clusters(context) ? K4A_RESULT_SUCCEEDED : K4A_RESULT_FAILED;
}

k4a_result_t k4a_record_write_custom_track_data(const k4a_record_t recording_handle,
                                                const char *track_name,
                                                uint64_t device_timestamp_usec,
                                                uint8_t *custom_data,
                                                size_t custom_data_size)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL || track_name == NULL || custom_data == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    record_track_t *track = NULL;
    for (size_t i = 0; i < context->track_count; i++)
    {
        if (strcmp(context->tracks[i].name, track_name) == 0)
        {
            track = &context->tracks[i];
        }
    }
    if (track == NULL || !track->custom)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "no custom track named %s", track_name);
        return K4A_RESULT_FAILED;
    }
    uint8_t *copy = (uint8_t *)openk4a_alloc(custom_data_size > 0 ? custom_data_size : 1);
    if (copy == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    memcpy(copy, custom_data, custom_data_size);
    if (!queue_data(context, track, device_timestamp_usec * 1000ULL, copy, custom_data_size))
    {
        openk4a_free(copy);
        return K4A_RESULT_FAILED;
    }
    return write_settled_clusters(context) ? K4A_RESULT_SUCCEEDED : K4A_RESULT_FAILED;
}

/*=============================================================================
  Flush and close
=============================================================================*/

k4a_result_t k4a_record_flush(k4a_record_t recording_handle)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL || !context->header_written)
    {
        return K4A_RESULT_FAILED;
    }
    bool ok = true;
    while (context->pending != NULL)
    {
        record_cluster_t *cluster = context->pending;
        context->pending = cluster->next;
        if (!write_cluster(context, cluster))
        {
            ok = false;
        }
    }

    /* Info into its reserved space. */
    mkv_buf_t info;
    mkv_buf_init(&info);
    render_info(context, &info, true);
    if (info.size + 2 <= RECORD_INFO_VOID)
    {
        mkv_put_void(&info, RECORD_INFO_VOID - info.size);
        ok = write_at(context, context->info_void_offset, info.data, info.size) && ok;
    }
    else
    {
        ok = false;
    }
    mkv_buf_free(&info);

    /* Cues after the last cluster. */
    const uint64_t cues_offset = context->data_end_offset;
    bool have_cues = false;
    if (context->cue_count > 0)
    {
        mkv_buf_t cues;
        mkv_buf_init(&cues);
        for (size_t i = 0; i < context->cue_count; i++)
        {
            mkv_buf_t point, positions;
            mkv_buf_init(&point);
            mkv_buf_init(&positions);
            mkv_put_uint(&point, MKV_ID_CUE_TIME, context->cues[i].time_ns);
            mkv_put_uint(&positions, MKV_ID_CUE_TRACK, 1);
            mkv_put_uint(&positions, MKV_ID_CUE_CLUSTER_POSITION, context->cues[i].position);
            mkv_put_uint(&positions, MKV_ID_CUE_BLOCK_NUMBER, context->cues[i].block_number);
            mkv_put_master(&point, MKV_ID_CUE_TRACK_POSITIONS, &positions);
            mkv_put_master(&cues, MKV_ID_CUE_POINT, &point);
            mkv_buf_free(&point);
            mkv_buf_free(&positions);
        }
        mkv_buf_t out;
        mkv_buf_init(&out);
        mkv_put_master(&out, MKV_ID_CUES, &cues);
        ok = write_at(context, cues_offset, out.data, out.size) && ok;
        have_cues = true;
        mkv_buf_free(&out);
        mkv_buf_free(&cues);
    }

    /* Tags again, into tags + void (they may have grown by K4A_START_OFFSET_NS). */
    mkv_buf_t tags;
    mkv_buf_init(&tags);
    render_tags(context, &tags);
    if (tags.size + 2 <= context->tags_region_size)
    {
        mkv_put_void(&tags, context->tags_region_size - tags.size);
        ok = write_at(context, context->tags_offset, tags.data, tags.size) && ok;
    }
    else
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the tags outgrew their reserved space");
        ok = false;
    }
    mkv_buf_free(&tags);

    /* SeekHead into its reserved space. */
    mkv_buf_t seek;
    mkv_buf_init(&seek);
    {
        const struct
        {
            uint32_t id;
            uint64_t offset;
            bool present;
        } entries[] = {
            { MKV_ID_INFO, context->info_void_offset, true },
            { MKV_ID_TRACKS, context->tracks_offset, true },
            { MKV_ID_ATTACHMENTS, context->attachments_offset, context->attachments_offset != 0 },
            { MKV_ID_TAGS, context->tags_offset, true },
            { MKV_ID_CUES, cues_offset, have_cues },
        };
        mkv_buf_t head;
        mkv_buf_init(&head);
        for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++)
        {
            if (!entries[i].present)
            {
                continue;
            }
            mkv_buf_t entry;
            mkv_buf_init(&entry);
            uint8_t id_bytes[4];
            const size_t id_length = mkv_write_id(id_bytes, entries[i].id);
            mkv_put_binary(&entry, MKV_ID_SEEK_ID, id_bytes, id_length);
            mkv_put_uint(&entry, MKV_ID_SEEK_POSITION, entries[i].offset - context->segment_data_offset);
            mkv_put_master(&head, MKV_ID_SEEK, &entry);
            mkv_buf_free(&entry);
        }
        mkv_put_master(&seek, MKV_ID_SEEK_HEAD, &head);
        mkv_buf_free(&head);
    }
    if (seek.size + 2 <= RECORD_SEEK_VOID)
    {
        mkv_put_void(&seek, RECORD_SEEK_VOID - seek.size);
        ok = write_at(context, context->seek_void_offset, seek.data, seek.size) && ok;
    }
    mkv_buf_free(&seek);

    /* The segment's size, now known. */
    {
        fseeko(context->file, 0, SEEK_END);
        const uint64_t end = (uint64_t)ftello(context->file);
        const uint64_t segment_size = end - context->segment_data_offset;
        uint8_t size_bytes[8];
        mkv_write_vint(size_bytes, segment_size, 8);
        ok = write_at(context, context->segment_data_offset - 8, size_bytes, 8) && ok;
    }
    fflush(context->file);
    return ok ? K4A_RESULT_SUCCEEDED : K4A_RESULT_FAILED;
}

void k4a_record_close(k4a_record_t recording_handle)
{
    record_context_t *context = (record_context_t *)recording_handle;
    if (context == NULL)
    {
        return;
    }
    if (context->header_written)
    {
        (void)k4a_record_flush(recording_handle);
    }
    context_free(context);
}
