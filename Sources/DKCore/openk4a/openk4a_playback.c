/*=============================================================================
  k4arecord: playback.

  The whole file is indexed once when it is opened: every block of every
  track with its timestamp and where its bytes are, which for a long
  recording is a few megabytes of index and no re-reading of cues. Reads then
  seek straight to a block. Captures are assembled the way the SDK assembles
  them: the next block of each of the colour, depth and IR tracks, kept
  together when they fall within half a frame period of the earliest.
=============================================================================*/

#include "openk4a.h"
#include "openk4a_matroska.h"

#include <k4arecord/playback.h>

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <math.h>

#define PLAYBACK_MAX_TRACKS 64
#define PLAYBACK_MAX_TAGS 512
#define PLAYBACK_MAX_ATTACHMENTS 64

typedef struct
{
    uint64_t timestamp_ns;  /* as written: relative to the recording start */
    uint64_t duration_ns;   /* a BlockGroup's BlockDuration, else 0 */
    uint64_t payload_offset; /* file offset of the block body */
    uint64_t payload_size;
} block_entry_t;

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
    uint64_t sync_delay_ns;
    k4a_image_format_t format;
    int stride;

    block_entry_t *blocks;
    size_t block_count, block_capacity;

    /* Where the reader stands: unpositioned (use the seek point), or at an
     * index, which may be -1 (before the first) or block_count (past the last). */
    bool positioned;
    int64_t position;
    int sub_index;

    /* The last block loaded, with its frames. */
    int64_t loaded_index;
    uint8_t *loaded;
    size_t loaded_size;
    uint32_t loaded_frames;
    size_t frame_offsets[256];
    size_t frame_sizes[256];
} playback_track_t;

typedef struct
{
    char *name;
    char *value;
    char *target_type;
    uint64_t target_uid;
} playback_tag_t;

typedef struct
{
    char *file_name;
    uint8_t *data;
    size_t size;
    uint64_t uid;
} playback_attachment_t;

typedef struct
{
    char *path;
    FILE *file;
    uint64_t timecode_scale;
    playback_track_t tracks[PLAYBACK_MAX_TRACKS];
    size_t track_count;
    size_t sorted[PLAYBACK_MAX_TRACKS]; /* indices by name */
    playback_tag_t tags[PLAYBACK_MAX_TAGS];
    size_t tag_count;
    playback_attachment_t attachments[PLAYBACK_MAX_ATTACHMENTS];
    size_t attachment_count;

    playback_track_t *color_track, *depth_track, *ir_track, *imu_track;
    playback_attachment_t *calibration_attachment;
    k4a_record_configuration_t config;
    k4a_image_format_t color_conversion;
    uint64_t sync_period_ns;
    uint64_t start_offset_ns;
    uint64_t last_timestamp_ns;
    uint64_t seek_timestamp_ns;
    bool have_calibration;
    k4a_calibration_t calibration;
} playback_context_t;

typedef struct
{
    uint64_t device_timestamp_usec;
    uint8_t *data;
    size_t size;
} playback_block_t;

#pragma pack(push, 1)
typedef struct
{
    uint64_t acc_timestamp_ns;
    float acc_data[3];
    uint64_t gyro_timestamp_ns;
    float gyro_data[3];
} matroska_imu_sample_t;
#pragma pack(pop)

/*-----------------------------------------------------------------------------
  helpers
---------------------------------------------------------------------------*/

static char *dup_bytes(const uint8_t *data, size_t size)
{
    char *copy = (char *)openk4a_alloc(size + 1);
    if (copy != NULL)
    {
        memcpy(copy, data, size);
        copy[size] = '\0';
    }
    return copy;
}

static uint8_t *read_range(playback_context_t *context, uint64_t offset, size_t size)
{
    uint8_t *data = (uint8_t *)openk4a_alloc(size > 0 ? size : 1);
    if (data == NULL)
    {
        return NULL;
    }
    if (fseeko(context->file, (off_t)offset, SEEK_SET) != 0 || fread(data, 1, size, context->file) != size)
    {
        openk4a_free(data);
        return NULL;
    }
    return data;
}

static bool track_add_block(playback_track_t *track, const block_entry_t *entry)
{
    if (track->block_count == track->block_capacity)
    {
        const size_t capacity = track->block_capacity == 0 ? 256 : track->block_capacity * 2;
        block_entry_t *blocks = (block_entry_t *)realloc(track->blocks, capacity * sizeof(block_entry_t));
        if (blocks == NULL)
        {
            return false;
        }
        track->blocks = blocks;
        track->block_capacity = capacity;
    }
    track->blocks[track->block_count++] = *entry;
    return true;
}

static playback_track_t *track_by_number(playback_context_t *context, uint64_t number)
{
    for (size_t i = 0; i < context->track_count; i++)
    {
        if (context->tracks[i].number == number)
        {
            return &context->tracks[i];
        }
    }
    return NULL;
}

static playback_track_t *track_by_name(playback_context_t *context, const char *name)
{
    for (size_t i = 0; i < context->track_count; i++)
    {
        if (strcmp(context->tracks[i].name, name) == 0)
        {
            return &context->tracks[i];
        }
    }
    return NULL;
}

static playback_tag_t *tag_by_name(playback_context_t *context, const char *name)
{
    for (size_t i = 0; i < context->tag_count; i++)
    {
        if (strcmp(context->tags[i].name, name) == 0)
        {
            return &context->tags[i];
        }
    }
    return NULL;
}

/*=============================================================================
  Parsing the header elements
=============================================================================*/

static bool parse_info(playback_context_t *context, const uint8_t *data, size_t size)
{
    mkv_cursor_t cursor = { data, size, 0 };
    mkv_header_t header;
    const uint8_t *payload;
    while (mkv_next(&cursor, &header, &payload))
    {
        if (header.id == MKV_ID_TIMECODE_SCALE)
        {
            context->timecode_scale = mkv_parse_uint(payload, (size_t)header.size);
        }
    }
    if (context->timecode_scale == 0)
    {
        context->timecode_scale = 1000000;
    }
    return true;
}

static bool parse_tracks(playback_context_t *context, const uint8_t *data, size_t size)
{
    mkv_cursor_t cursor = { data, size, 0 };
    mkv_header_t header;
    const uint8_t *payload;
    while (mkv_next(&cursor, &header, &payload))
    {
        if (header.id != MKV_ID_TRACK_ENTRY || context->track_count >= PLAYBACK_MAX_TRACKS)
        {
            continue;
        }
        playback_track_t *track = &context->tracks[context->track_count];
        memset(track, 0, sizeof(*track));
        track->format = K4A_IMAGE_FORMAT_CUSTOM;
        track->loaded_index = -1;
        mkv_cursor_t entry = { payload, (size_t)header.size, 0 };
        mkv_header_t child;
        const uint8_t *value;
        while (mkv_next(&entry, &child, &value))
        {
            const size_t n = (size_t)child.size;
            switch (child.id)
            {
            case MKV_ID_TRACK_NUMBER: track->number = mkv_parse_uint(value, n); break;
            case MKV_ID_TRACK_UID: track->uid = mkv_parse_uint(value, n); break;
            case MKV_ID_TRACK_TYPE: track->type = (int)mkv_parse_uint(value, n); break;
            case MKV_ID_DEFAULT_DURATION: track->default_duration_ns = mkv_parse_uint(value, n); break;
            case MKV_ID_TRACK_NAME: track->name = dup_bytes(value, n); break;
            case MKV_ID_CODEC_ID: track->codec_id = dup_bytes(value, n); break;
            case MKV_ID_CODEC_PRIVATE:
                track->codec_private = (uint8_t *)openk4a_alloc(n > 0 ? n : 1);
                if (track->codec_private != NULL)
                {
                    memcpy(track->codec_private, value, n);
                    track->codec_private_size = n;
                }
                break;
            case MKV_ID_VIDEO: {
                mkv_cursor_t video = { value, n, 0 };
                mkv_header_t v;
                const uint8_t *vv;
                while (mkv_next(&video, &v, &vv))
                {
                    if (v.id == MKV_ID_PIXEL_WIDTH) track->width = mkv_parse_uint(vv, (size_t)v.size);
                    if (v.id == MKV_ID_PIXEL_HEIGHT) track->height = mkv_parse_uint(vv, (size_t)v.size);
                }
                break;
            }
            default:
                break;
            }
        }
        if (track->name == NULL)
        {
            track->name = dup_bytes((const uint8_t *)"", 0);
        }
        if (track->codec_id == NULL)
        {
            track->codec_id = dup_bytes((const uint8_t *)"", 0);
        }
        context->track_count++;
    }
    return true;
}

static bool parse_attachments(playback_context_t *context, const uint8_t *data, size_t size)
{
    mkv_cursor_t cursor = { data, size, 0 };
    mkv_header_t header;
    const uint8_t *payload;
    while (mkv_next(&cursor, &header, &payload))
    {
        if (header.id != MKV_ID_ATTACHED_FILE || context->attachment_count >= PLAYBACK_MAX_ATTACHMENTS)
        {
            continue;
        }
        playback_attachment_t *attachment = &context->attachments[context->attachment_count];
        memset(attachment, 0, sizeof(*attachment));
        mkv_cursor_t entry = { payload, (size_t)header.size, 0 };
        mkv_header_t child;
        const uint8_t *value;
        while (mkv_next(&entry, &child, &value))
        {
            const size_t n = (size_t)child.size;
            switch (child.id)
            {
            case MKV_ID_FILE_NAME: attachment->file_name = dup_bytes(value, n); break;
            case MKV_ID_FILE_UID: attachment->uid = mkv_parse_uint(value, n); break;
            case MKV_ID_FILE_DATA:
                attachment->data = (uint8_t *)openk4a_alloc(n > 0 ? n : 1);
                if (attachment->data != NULL)
                {
                    memcpy(attachment->data, value, n);
                    attachment->size = n;
                }
                break;
            default:
                break;
            }
        }
        if (attachment->file_name == NULL)
        {
            attachment->file_name = dup_bytes((const uint8_t *)"", 0);
        }
        context->attachment_count++;
    }
    return true;
}

static bool parse_tags(playback_context_t *context, const uint8_t *data, size_t size)
{
    mkv_cursor_t cursor = { data, size, 0 };
    mkv_header_t header;
    const uint8_t *payload;
    while (mkv_next(&cursor, &header, &payload))
    {
        if (header.id != MKV_ID_TAG || context->tag_count >= PLAYBACK_MAX_TAGS)
        {
            continue;
        }
        playback_tag_t *tag = &context->tags[context->tag_count];
        memset(tag, 0, sizeof(*tag));
        mkv_cursor_t entry = { payload, (size_t)header.size, 0 };
        mkv_header_t child;
        const uint8_t *value;
        while (mkv_next(&entry, &child, &value))
        {
            if (child.id == MKV_ID_TARGETS)
            {
                mkv_cursor_t targets = { value, (size_t)child.size, 0 };
                mkv_header_t t;
                const uint8_t *tv;
                while (mkv_next(&targets, &t, &tv))
                {
                    if (t.id == MKV_ID_TARGET_TYPE) tag->target_type = dup_bytes(tv, (size_t)t.size);
                    if (t.id == MKV_ID_TAG_TRACK_UID || t.id == MKV_ID_TAG_ATTACHMENT_UID) tag->target_uid = mkv_parse_uint(tv, (size_t)t.size);
                }
            }
            else if (child.id == MKV_ID_SIMPLE_TAG && tag->name == NULL)
            {
                mkv_cursor_t simple = { value, (size_t)child.size, 0 };
                mkv_header_t s;
                const uint8_t *sv;
                while (mkv_next(&simple, &s, &sv))
                {
                    if (s.id == MKV_ID_TAG_NAME) tag->name = dup_bytes(sv, (size_t)s.size);
                    if (s.id == MKV_ID_TAG_STRING) tag->value = dup_bytes(sv, (size_t)s.size);
                }
            }
        }
        if (tag->name == NULL || tag->value == NULL)
        {
            openk4a_free(tag->name);
            openk4a_free(tag->value);
            openk4a_free(tag->target_type);
            memset(tag, 0, sizeof(*tag));
            continue;
        }
        context->tag_count++;
    }
    return true;
}

/* A cluster: its timecode, then every block, indexed by track. */
static bool parse_cluster(playback_context_t *context, uint64_t cluster_offset, uint64_t cluster_size)
{
    uint64_t at = cluster_offset;
    const uint64_t end = cluster_offset + cluster_size;
    uint64_t cluster_timecode = 0;
    while (at < end)
    {
        if (fseeko(context->file, (off_t)at, SEEK_SET) != 0)
        {
            return false;
        }
        mkv_header_t header;
        if (!mkv_read_header(context->file, &header) || header.unknown_size)
        {
            return false;
        }
        const uint64_t data_at = at + header.header_size;
        if (header.id == MKV_ID_TIMECODE)
        {
            uint8_t bytes[8];
            const size_t n = header.size > 8 ? 8 : (size_t)header.size;
            if (fread(bytes, 1, n, context->file) != n)
            {
                return false;
            }
            cluster_timecode = mkv_parse_uint(bytes, n);
        }
        else if (header.id == MKV_ID_SIMPLE_BLOCK || header.id == MKV_ID_BLOCK_GROUP)
        {
            uint64_t block_at = data_at;
            uint64_t block_size = header.size;
            uint64_t duration = 0;
            if (header.id == MKV_ID_BLOCK_GROUP)
            {
                /* Find the Block and the BlockDuration among the group's children. */
                uint64_t child_at = data_at;
                block_at = 0;
                while (child_at < data_at + header.size)
                {
                    fseeko(context->file, (off_t)child_at, SEEK_SET);
                    mkv_header_t child;
                    if (!mkv_read_header(context->file, &child) || child.unknown_size)
                    {
                        return false;
                    }
                    if (child.id == MKV_ID_BLOCK)
                    {
                        block_at = child_at + child.header_size;
                        block_size = child.size;
                    }
                    else if (child.id == MKV_ID_BLOCK_DURATION)
                    {
                        uint8_t bytes[8];
                        const size_t n = child.size > 8 ? 8 : (size_t)child.size;
                        if (fread(bytes, 1, n, context->file) != n)
                        {
                            return false;
                        }
                        duration = mkv_parse_uint(bytes, n) * context->timecode_scale;
                    }
                    child_at += child.header_size + child.size;
                }
            }
            if (block_at != 0)
            {
                uint8_t head[12];
                fseeko(context->file, (off_t)block_at, SEEK_SET);
                const size_t got = fread(head, 1, sizeof(head), context->file);
                mkv_block_info_t info;
                size_t offsets[1], sizes[1];
                /* Only the header is needed here; lacing is parsed when the block is loaded. */
                if (got >= 4)
                {
                    size_t n = 0;
                    info.track_number = mkv_parse_vint(head, got, &n, true);
                    if (n > 0 && got >= n + 3)
                    {
                        info.timecode = (int16_t)(((uint16_t)head[n] << 8) | head[n + 1]);
                        playback_track_t *track = track_by_number(context, info.track_number);
                        if (track != NULL)
                        {
                            block_entry_t entry;
                            const int64_t timecode = (int64_t)cluster_timecode + info.timecode;
                            entry.timestamp_ns = timecode > 0 ? (uint64_t)timecode * context->timecode_scale : 0;
                            entry.duration_ns = duration;
                            entry.payload_offset = block_at;
                            entry.payload_size = block_size;
                            if (!track_add_block(track, &entry))
                            {
                                return false;
                            }
                            const uint64_t last = entry.timestamp_ns + (duration > 0 ? duration - 1 : 0);
                            if (last > context->last_timestamp_ns)
                            {
                                context->last_timestamp_ns = last;
                            }
                        }
                    }
                }
                (void)offsets;
                (void)sizes;
            }
        }
        at = data_at + header.size;
    }
    return true;
}

static int compare_blocks(const void *a, const void *b)
{
    const block_entry_t *x = (const block_entry_t *)a;
    const block_entry_t *y = (const block_entry_t *)b;
    return x->timestamp_ns < y->timestamp_ns ? -1 : (x->timestamp_ns > y->timestamp_ns ? 1 : 0);
}

/* macOS's qsort_r passes the context first. */
static int compare_track_names(void *arg, const void *a, const void *b)
{
    playback_context_t *context = (playback_context_t *)arg;
    return strcmp(context->tracks[*(const size_t *)a].name, context->tracks[*(const size_t *)b].name);
}

static bool parse_file(playback_context_t *context)
{
    fseeko(context->file, 0, SEEK_END);
    const uint64_t file_size = (uint64_t)ftello(context->file);
    fseeko(context->file, 0, SEEK_SET);

    mkv_header_t header;
    if (!mkv_read_header(context->file, &header) || header.id != MKV_ID_EBML)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "'%s' is not an EBML file", context->path);
        return false;
    }
    {
        uint8_t *head = read_range(context, header.header_size, (size_t)header.size);
        if (head == NULL)
        {
            return false;
        }
        mkv_cursor_t cursor = { head, (size_t)header.size, 0 };
        mkv_header_t child;
        const uint8_t *value;
        bool matroska = false;
        while (mkv_next(&cursor, &child, &value))
        {
            if (child.id == MKV_ID_DOCTYPE)
            {
                matroska = child.size == 8 && memcmp(value, "matroska", 8) == 0;
            }
        }
        openk4a_free(head);
        if (!matroska)
        {
            openk4a_log(OPENK4A_LOG_ERROR, "'%s' is not a Matroska file", context->path);
            return false;
        }
    }
    uint64_t at = header.header_size + header.size;
    fseeko(context->file, (off_t)at, SEEK_SET);
    if (!mkv_read_header(context->file, &header) || header.id != MKV_ID_SEGMENT)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "'%s' has no Segment", context->path);
        return false;
    }
    at += header.header_size;
    const uint64_t segment_end = header.unknown_size ? file_size : at + header.size;
    context->timecode_scale = 1000000;

    while (at < segment_end && at < file_size)
    {
        fseeko(context->file, (off_t)at, SEEK_SET);
        mkv_header_t element;
        if (!mkv_read_header(context->file, &element))
        {
            break;
        }
        const uint64_t data_at = at + element.header_size;
        uint64_t size = element.unknown_size ? segment_end - data_at : element.size;
        if (data_at + size > file_size)
        {
            size = file_size - data_at; /* a recording that was cut short */
        }
        switch (element.id)
        {
        case MKV_ID_INFO:
        case MKV_ID_TRACKS:
        case MKV_ID_ATTACHMENTS:
        case MKV_ID_TAGS: {
            uint8_t *data = read_range(context, data_at, (size_t)size);
            if (data == NULL)
            {
                return false;
            }
            bool ok = true;
            if (element.id == MKV_ID_INFO) ok = parse_info(context, data, (size_t)size);
            if (element.id == MKV_ID_TRACKS) ok = parse_tracks(context, data, (size_t)size);
            if (element.id == MKV_ID_ATTACHMENTS) ok = parse_attachments(context, data, (size_t)size);
            if (element.id == MKV_ID_TAGS) ok = parse_tags(context, data, (size_t)size);
            openk4a_free(data);
            if (!ok)
            {
                return false;
            }
            break;
        }
        case MKV_ID_CLUSTER:
            if (!parse_cluster(context, data_at, size))
            {
                openk4a_log(OPENK4A_LOG_WARNING, "'%s': a cluster could not be read; the recording ends there", context->path);
                at = file_size;
                continue;
            }
            break;
        default:
            break;
        }
        at = data_at + size;
    }
    for (size_t i = 0; i < context->track_count; i++)
    {
        qsort(context->tracks[i].blocks, context->tracks[i].block_count, sizeof(block_entry_t), compare_blocks);
        context->sorted[i] = i;
    }
    qsort_r(context->sorted, context->track_count, sizeof(size_t), context, compare_track_names);
    return true;
}

/*=============================================================================
  The recording's configuration, from tracks and tags
=============================================================================*/

static playback_track_t *find_track(playback_context_t *context, const char *name, const char *tag_name)
{
    uint64_t uid = 0;
    if (tag_name != NULL)
    {
        playback_tag_t *tag = tag_by_name(context, tag_name);
        if (tag != NULL)
        {
            if (tag->target_type != NULL && strcmp(tag->target_type, "TRACK") == 0)
            {
                uid = tag->target_uid;
            }
            if (uid == 0)
            {
                uid = strtoull(tag->value, NULL, 10);
            }
        }
    }
    playback_track_t *found = NULL;
    for (size_t i = 0; i < context->track_count; i++)
    {
        playback_track_t *track = &context->tracks[i];
        if (uid != 0 && track->uid == uid)
        {
            return track;
        }
        if (strcmp(track->name, name) == 0)
        {
            found = track;
        }
    }
    return found;
}

static bool read_bitmap_header(playback_track_t *track)
{
    if (strcmp(track->codec_id, "V_MS/VFW/FOURCC") != 0 || track->codec_private_size < 40)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "track %s has codec %s, not the V_MS/VFW/FOURCC the SDK writes", track->name, track->codec_id);
        return false;
    }
    const uint32_t compression = (uint32_t)track->codec_private[16] | ((uint32_t)track->codec_private[17] << 8) |
                                 ((uint32_t)track->codec_private[18] << 16) | ((uint32_t)track->codec_private[19] << 24);
    switch (compression)
    {
    case 0x3231564E: track->format = K4A_IMAGE_FORMAT_COLOR_NV12; track->stride = (int)track->width; break;
    case 0x32595559: track->format = K4A_IMAGE_FORMAT_COLOR_YUY2; track->stride = (int)track->width * 2; break;
    case 0x47504A4D: track->format = K4A_IMAGE_FORMAT_COLOR_MJPG; track->stride = 0; break;
    case 0x67363162: track->format = K4A_IMAGE_FORMAT_DEPTH16; track->stride = (int)track->width * 2; break;
    case 0x41524742: track->format = K4A_IMAGE_FORMAT_COLOR_BGRA32; track->stride = (int)track->width * 4; break;
    default:
        openk4a_log(OPENK4A_LOG_ERROR, "track %s has an unknown FOURCC %08X", track->name, compression);
        return false;
    }
    return true;
}

static bool parse_config(playback_context_t *context)
{
    context->color_track = find_track(context, "COLOR", "K4A_COLOR_TRACK");
    context->depth_track = find_track(context, "DEPTH", "K4A_DEPTH_TRACK");
    context->ir_track = find_track(context, "IR", "K4A_IR_TRACK");
    if (context->ir_track == NULL)
    {
        context->ir_track = find_track(context, "DEPTH_IR", NULL);
    }
    context->imu_track = find_track(context, "IMU", "K4A_IMU_TRACK");

    playback_tag_t *calibration_tag = tag_by_name(context, "K4A_CALIBRATION_FILE");
    for (size_t i = 0; i < context->attachment_count; i++)
    {
        playback_attachment_t *attachment = &context->attachments[i];
        if (calibration_tag != NULL && calibration_tag->target_uid != 0 && attachment->uid == calibration_tag->target_uid)
        {
            context->calibration_attachment = attachment;
            break;
        }
        if (strcmp(attachment->file_name, calibration_tag != NULL ? calibration_tag->value : "calibration.json") == 0)
        {
            context->calibration_attachment = attachment;
        }
    }

    memset(&context->config, 0, sizeof(context->config));
    uint64_t frame_period_ns = 0;
    if (context->color_track != NULL)
    {
        if (context->color_track->type != MKV_TRACK_TYPE_VIDEO || !read_bitmap_header(context->color_track))
        {
            return false;
        }
        frame_period_ns = context->color_track->default_duration_ns;
        context->config.color_resolution = K4A_COLOR_RESOLUTION_OFF;
        static const k4a_color_resolution_t resolutions[] = { K4A_COLOR_RESOLUTION_720P, K4A_COLOR_RESOLUTION_1080P, K4A_COLOR_RESOLUTION_1440P,
                                                             K4A_COLOR_RESOLUTION_1536P, K4A_COLOR_RESOLUTION_2160P, K4A_COLOR_RESOLUTION_3072P };
        for (size_t i = 0; i < sizeof(resolutions) / sizeof(resolutions[0]); i++)
        {
            int width, height;
            if (openk4a_color_grid(resolutions[i], &width, &height) && (uint64_t)width == context->color_track->width &&
                (uint64_t)height == context->color_track->height)
            {
                context->config.color_resolution = resolutions[i];
            }
        }
        context->config.color_track_enabled = true;
        context->config.color_format = context->color_track->format;
        context->color_conversion = context->color_track->format;
    }
    else
    {
        context->config.color_format = K4A_IMAGE_FORMAT_CUSTOM;
        context->color_conversion = K4A_IMAGE_FORMAT_CUSTOM;
    }

    playback_tag_t *depth_mode_tag = tag_by_name(context, "K4A_DEPTH_MODE");
    if (depth_mode_tag == NULL && (context->depth_track != NULL || context->ir_track != NULL))
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the recording has depth tracks but no K4A_DEPTH_MODE tag");
        return false;
    }
    context->config.depth_mode = K4A_DEPTH_MODE_OFF;
    int depth_width = 0, depth_height = 0;
    if (depth_mode_tag != NULL)
    {
        static const struct { k4a_depth_mode_t mode; const char *name; } modes[] = {
            { K4A_DEPTH_MODE_NFOV_2X2BINNED, "NFOV_2X2BINNED" }, { K4A_DEPTH_MODE_NFOV_UNBINNED, "NFOV_UNBINNED" },
            { K4A_DEPTH_MODE_WFOV_2X2BINNED, "WFOV_2X2BINNED" }, { K4A_DEPTH_MODE_WFOV_UNBINNED, "WFOV_UNBINNED" },
            { K4A_DEPTH_MODE_PASSIVE_IR, "PASSIVE_IR" },
            { K4A_DEPTH_MODE_NFOV_2X2BINNED, "NFOV_2x2BINNED" }, { K4A_DEPTH_MODE_WFOV_2X2BINNED, "WFOV_2x2BINNED" },
        };
        for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++)
        {
            if (strcmp(depth_mode_tag->value, modes[i].name) == 0)
            {
                context->config.depth_mode = modes[i].mode;
                break;
            }
        }
        if (context->config.depth_mode == K4A_DEPTH_MODE_OFF || !openk4a_calibration_grid(context->config.depth_mode, &depth_width, &depth_height))
        {
            openk4a_log(OPENK4A_LOG_ERROR, "unknown depth mode in recording: %s", depth_mode_tag->value);
            return false;
        }
    }
    if (context->depth_track != NULL)
    {
        if (context->depth_track->type != MKV_TRACK_TYPE_VIDEO || !read_bitmap_header(context->depth_track))
        {
            return false;
        }
        if (frame_period_ns == 0)
        {
            frame_period_ns = context->depth_track->default_duration_ns;
        }
        if ((int)context->depth_track->width != depth_width || (int)context->depth_track->height != depth_height)
        {
            openk4a_log(OPENK4A_LOG_ERROR, "the depth track's size does not match its mode");
            return false;
        }
        context->config.depth_track_enabled = true;
    }
    if (context->ir_track != NULL)
    {
        if (context->ir_track->type != MKV_TRACK_TYPE_VIDEO || !read_bitmap_header(context->ir_track))
        {
            return false;
        }
        if (frame_period_ns == 0)
        {
            frame_period_ns = context->ir_track->default_duration_ns;
        }
        if (context->ir_track->format == K4A_IMAGE_FORMAT_DEPTH16)
        {
            context->ir_track->format = K4A_IMAGE_FORMAT_IR16;
        }
        context->config.ir_track_enabled = true;
    }
    context->sync_period_ns = frame_period_ns;
    context->config.camera_fps = K4A_FRAMES_PER_SECOND_30;
    if (frame_period_ns > 0)
    {
        switch (1000000000ULL / frame_period_ns)
        {
        case 5: context->config.camera_fps = K4A_FRAMES_PER_SECOND_5; break;
        case 15: context->config.camera_fps = K4A_FRAMES_PER_SECOND_15; break;
        case 30: context->config.camera_fps = K4A_FRAMES_PER_SECOND_30; break;
        default:
            openk4a_log(OPENK4A_LOG_ERROR, "the recording's frame rate is not one the camera has");
            return false;
        }
    }
    playback_tag_t *delay_tag = tag_by_name(context, "K4A_DEPTH_DELAY_NS");
    if (delay_tag != NULL)
    {
        const int64_t delay_ns = strtoll(delay_tag->value, NULL, 10);
        context->config.depth_delay_off_color_usec = (int32_t)(delay_ns / 1000);
        if (delay_ns > 0 && context->color_track != NULL)
        {
            context->color_track->sync_delay_ns = (uint64_t)delay_ns;
        }
        else if (delay_ns < 0)
        {
            if (context->depth_track != NULL) context->depth_track->sync_delay_ns = (uint64_t)(-delay_ns);
            if (context->ir_track != NULL) context->ir_track->sync_delay_ns = (uint64_t)(-delay_ns);
        }
    }
    if (context->imu_track != NULL)
    {
        if (context->imu_track->type == MKV_TRACK_TYPE_SUBTITLE)
        {
            context->config.imu_track_enabled = true;
        }
        else
        {
            context->imu_track = NULL;
        }
    }
    context->config.wired_sync_mode = K4A_WIRED_SYNC_MODE_STANDALONE;
    playback_tag_t *sync_tag = tag_by_name(context, "K4A_WIRED_SYNC_MODE");
    if (sync_tag != NULL)
    {
        if (strcmp(sync_tag->value, "MASTER") == 0) context->config.wired_sync_mode = K4A_WIRED_SYNC_MODE_MASTER;
        else if (strcmp(sync_tag->value, "SUBORDINATE") == 0) context->config.wired_sync_mode = K4A_WIRED_SYNC_MODE_SUBORDINATE;
        else if (strcmp(sync_tag->value, "STANDALONE") != 0)
        {
            openk4a_log(OPENK4A_LOG_ERROR, "unknown wired sync mode in recording: %s", sync_tag->value);
            return false;
        }
        if (context->config.wired_sync_mode == K4A_WIRED_SYNC_MODE_SUBORDINATE)
        {
            playback_tag_t *sub = tag_by_name(context, "K4A_SUBORDINATE_DELAY_NS");
            context->config.subordinate_delay_off_master_usec = sub != NULL ? (uint32_t)(strtoull(sub->value, NULL, 10) / 1000) : 0;
        }
    }
    playback_tag_t *start_tag = tag_by_name(context, "K4A_START_OFFSET_NS");
    if (start_tag != NULL)
    {
        context->start_offset_ns = strtoull(start_tag->value, NULL, 10);
        context->config.start_timestamp_offset_usec = (uint32_t)(context->start_offset_ns / 1000);
    }
    return true;
}

/*=============================================================================
  Open and close
=============================================================================*/

static void context_free(playback_context_t *context)
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
        openk4a_free(context->tracks[i].loaded);
        free(context->tracks[i].blocks);
    }
    for (size_t i = 0; i < context->tag_count; i++)
    {
        openk4a_free(context->tags[i].name);
        openk4a_free(context->tags[i].value);
        openk4a_free(context->tags[i].target_type);
    }
    for (size_t i = 0; i < context->attachment_count; i++)
    {
        openk4a_free(context->attachments[i].file_name);
        openk4a_free(context->attachments[i].data);
    }
    if (context->file != NULL)
    {
        fclose(context->file);
    }
    openk4a_free(context->path);
    openk4a_free(context);
}

k4a_result_t k4a_playback_open(const char *path, k4a_playback_t *playback_handle)
{
    if (path == NULL || playback_handle == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    playback_context_t *context = (playback_context_t *)openk4a_alloc_zero(sizeof(playback_context_t));
    if (context == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    context->path = dup_bytes((const uint8_t *)path, strlen(path));
    context->file = fopen(path, "rb");
    if (context->path == NULL || context->file == NULL)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "unable to open recording '%s'", path);
        context_free(context);
        return K4A_RESULT_FAILED;
    }
    if (!parse_file(context) || !parse_config(context))
    {
        context_free(context);
        return K4A_RESULT_FAILED;
    }
    *playback_handle = (k4a_playback_t)context;
    return K4A_RESULT_SUCCEEDED;
}

void k4a_playback_close(k4a_playback_t playback_handle)
{
    context_free((playback_context_t *)playback_handle);
}

/*=============================================================================
  Metadata
=============================================================================*/

k4a_buffer_result_t k4a_playback_get_raw_calibration(k4a_playback_t playback_handle, uint8_t *data, size_t *data_size)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || data_size == NULL)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    const playback_attachment_t *attachment = context->calibration_attachment;
    if (attachment == NULL)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    const size_t zero = attachment->size > 0 && attachment->data[attachment->size - 1] == '\0' ? 0 : 1;
    const size_t needed = attachment->size + zero;
    if (data != NULL && *data_size >= needed)
    {
        memcpy(data, attachment->data, attachment->size);
        if (zero)
        {
            data[attachment->size] = '\0';
        }
        *data_size = needed;
        return K4A_BUFFER_RESULT_SUCCEEDED;
    }
    *data_size = needed;
    return K4A_BUFFER_RESULT_TOO_SMALL;
}

k4a_result_t k4a_playback_get_calibration(k4a_playback_t playback_handle, k4a_calibration_t *calibration)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || calibration == NULL || context->calibration_attachment == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (!context->have_calibration)
    {
        const size_t size = context->calibration_attachment->size;
        char *text = (char *)openk4a_alloc(size + 1);
        if (text == NULL)
        {
            return K4A_RESULT_FAILED;
        }
        memcpy(text, context->calibration_attachment->data, size);
        text[size] = '\0';
        const k4a_result_t result = k4a_calibration_get_from_raw(text, size + 1, context->config.depth_mode,
                                                                 context->config.color_resolution, &context->calibration);
        openk4a_free(text);
        if (result != K4A_RESULT_SUCCEEDED)
        {
            return result;
        }
        context->have_calibration = true;
    }
    *calibration = context->calibration;
    return K4A_RESULT_SUCCEEDED;
}

k4a_result_t k4a_playback_get_record_configuration(k4a_playback_t playback_handle, k4a_record_configuration_t *config)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || config == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    *config = context->config;
    return K4A_RESULT_SUCCEEDED;
}

bool k4a_playback_check_track_exists(k4a_playback_t playback_handle, const char *track_name)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    return context != NULL && track_name != NULL && track_by_name(context, track_name) != NULL;
}

size_t k4a_playback_get_track_count(k4a_playback_t playback_handle)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    return context != NULL ? context->track_count : 0;
}

static k4a_buffer_result_t copy_text(const char *text, char *out, size_t *out_size)
{
    const size_t needed = strlen(text) + 1;
    if (out != NULL && *out_size >= needed)
    {
        memcpy(out, text, needed);
        *out_size = needed;
        return K4A_BUFFER_RESULT_SUCCEEDED;
    }
    *out_size = needed;
    return K4A_BUFFER_RESULT_TOO_SMALL;
}

k4a_buffer_result_t k4a_playback_get_track_name(k4a_playback_t playback_handle, size_t track_index, char *track_name, size_t *track_name_size)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || track_name_size == NULL || track_index >= context->track_count)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    return copy_text(context->tracks[context->sorted[track_index]].name, track_name, track_name_size);
}

bool k4a_playback_track_is_builtin(k4a_playback_t playback_handle, const char *track_name)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || track_name == NULL)
    {
        return false;
    }
    playback_track_t *track = track_by_name(context, track_name);
    return track != NULL && (track == context->color_track || track == context->depth_track || track == context->ir_track || track == context->imu_track);
}

k4a_result_t k4a_playback_track_get_video_settings(k4a_playback_t playback_handle, const char *track_name, k4a_record_video_settings_t *video_settings)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || track_name == NULL || video_settings == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    playback_track_t *track = track_by_name(context, track_name);
    if (track == NULL || track->type != MKV_TRACK_TYPE_VIDEO)
    {
        return K4A_RESULT_FAILED;
    }
    video_settings->width = track->width;
    video_settings->height = track->height;
    video_settings->frame_rate = track->default_duration_ns != 0 ? 1000000000ULL / track->default_duration_ns : 0;
    return K4A_RESULT_SUCCEEDED;
}

k4a_buffer_result_t k4a_playback_track_get_codec_id(k4a_playback_t playback_handle, const char *track_name, char *codec_id, size_t *codec_id_size)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || track_name == NULL || codec_id_size == NULL)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    playback_track_t *track = track_by_name(context, track_name);
    return track != NULL ? copy_text(track->codec_id, codec_id, codec_id_size) : K4A_BUFFER_RESULT_FAILED;
}

k4a_buffer_result_t k4a_playback_track_get_codec_context(k4a_playback_t playback_handle, const char *track_name, uint8_t *codec_context, size_t *codec_context_size)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || track_name == NULL || codec_context_size == NULL)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    playback_track_t *track = track_by_name(context, track_name);
    if (track == NULL)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    if (codec_context != NULL && *codec_context_size >= track->codec_private_size)
    {
        memcpy(codec_context, track->codec_private, track->codec_private_size);
        *codec_context_size = track->codec_private_size;
        return K4A_BUFFER_RESULT_SUCCEEDED;
    }
    *codec_context_size = track->codec_private_size;
    return K4A_BUFFER_RESULT_TOO_SMALL;
}

k4a_buffer_result_t k4a_playback_get_tag(k4a_playback_t playback_handle, const char *name, char *value, size_t *value_size)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || name == NULL || value_size == NULL)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    playback_tag_t *tag = tag_by_name(context, name);
    return tag != NULL ? copy_text(tag->value, value, value_size) : K4A_BUFFER_RESULT_FAILED;
}

k4a_result_t k4a_playback_set_color_conversion(k4a_playback_t playback_handle, k4a_image_format_t target_format)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || context->color_track == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    switch (target_format)
    {
    case K4A_IMAGE_FORMAT_COLOR_MJPG:
        if (context->color_track->format != K4A_IMAGE_FORMAT_COLOR_MJPG)
        {
            return K4A_RESULT_FAILED;
        }
        break;
    case K4A_IMAGE_FORMAT_COLOR_NV12:
    case K4A_IMAGE_FORMAT_COLOR_YUY2:
    case K4A_IMAGE_FORMAT_COLOR_BGRA32:
        break;
    default:
        return K4A_RESULT_FAILED;
    }
    context->color_conversion = target_format;
    return K4A_RESULT_SUCCEEDED;
}

k4a_buffer_result_t k4a_playback_get_attachment(k4a_playback_t playback_handle, const char *file_name, uint8_t *data, size_t *data_size)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || file_name == NULL || data_size == NULL)
    {
        return K4A_BUFFER_RESULT_FAILED;
    }
    for (size_t i = 0; i < context->attachment_count; i++)
    {
        const playback_attachment_t *attachment = &context->attachments[i];
        if (strcmp(attachment->file_name, file_name) != 0)
        {
            continue;
        }
        if (data != NULL && *data_size >= attachment->size)
        {
            memcpy(data, attachment->data, attachment->size);
            *data_size = attachment->size;
            return K4A_BUFFER_RESULT_SUCCEEDED;
        }
        *data_size = attachment->size;
        return K4A_BUFFER_RESULT_TOO_SMALL;
    }
    return K4A_BUFFER_RESULT_FAILED;
}

uint64_t k4a_playback_get_recording_length_usec(k4a_playback_t playback_handle)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    return context != NULL ? context->last_timestamp_ns / 1000 : 0;
}

/*=============================================================================
  Blocks
=============================================================================*/

static uint64_t block_sync_ns(const playback_track_t *track, int64_t index)
{
    return track->blocks[index].timestamp_ns + track->sync_delay_ns;
}

/* The first block at or after a timestamp, as an index (block_count when none). */
static int64_t lower_bound(const playback_track_t *track, uint64_t sync_ns)
{
    int64_t low = 0, high = (int64_t)track->block_count;
    while (low < high)
    {
        const int64_t mid = (low + high) / 2;
        if (block_sync_ns(track, mid) < sync_ns)
        {
            low = mid + 1;
        }
        else
        {
            high = mid;
        }
    }
    return low;
}

static bool load_block(playback_context_t *context, playback_track_t *track, int64_t index)
{
    if (index < 0 || index >= (int64_t)track->block_count)
    {
        return false;
    }
    if (track->loaded_index == index && track->loaded != NULL)
    {
        return true;
    }
    const block_entry_t *entry = &track->blocks[index];
    uint8_t *payload = read_range(context, entry->payload_offset, (size_t)entry->payload_size);
    if (payload == NULL)
    {
        return false;
    }
    mkv_block_info_t info;
    if (!mkv_parse_block(payload, (size_t)entry->payload_size, &info, track->frame_offsets, track->frame_sizes, 256))
    {
        openk4a_free(payload);
        return false;
    }
    openk4a_free(track->loaded);
    track->loaded = payload;
    track->loaded_size = (size_t)entry->payload_size;
    track->loaded_frames = info.frame_count > 256 ? 256 : info.frame_count;
    track->loaded_index = index;
    return true;
}

/* A laced block's frame timestamp, spread over the block's duration. */
static uint64_t frame_timestamp_ns(const playback_track_t *track, int64_t index, int sub_index)
{
    const block_entry_t *entry = &track->blocks[index];
    uint64_t timestamp = entry->timestamp_ns + track->sync_delay_ns;
    if (sub_index > 0 && track->loaded_frames > 1 && entry->duration_ns > 0)
    {
        timestamp += (uint64_t)sub_index * (entry->duration_ns - 1) / (track->loaded_frames - 1);
    }
    return timestamp;
}

/*=============================================================================
  Images
=============================================================================*/

static inline uint8_t clamp_byte(int value)
{
    return value < 0 ? 0 : (value > 255 ? 255 : (uint8_t)value);
}

/* BT.601 limited range, as libyuv's NV12ToARGB and YUY2ToARGB do. */
static inline void yuv_to_bgra(int y, int u, int v, uint8_t *out)
{
    const int c = (y - 16) * 298;
    const int d = u - 128;
    const int e = v - 128;
    out[0] = clamp_byte((c + 516 * d + 128) >> 8);
    out[1] = clamp_byte((c - 100 * d - 208 * e + 128) >> 8);
    out[2] = clamp_byte((c + 409 * e + 128) >> 8);
    out[3] = 255;
}

static bool nv12_to_bgra(const uint8_t *in, int width, int height, uint8_t *out)
{
    const uint8_t *chroma = in + (size_t)width * (size_t)height;
    for (int y = 0; y < height; y++)
    {
        const uint8_t *luma = in + (size_t)y * (size_t)width;
        const uint8_t *uv = chroma + (size_t)(y / 2) * (size_t)width;
        uint8_t *row = out + (size_t)y * (size_t)width * 4;
        for (int x = 0; x < width; x++)
        {
            yuv_to_bgra(luma[x], uv[(x / 2) * 2], uv[(x / 2) * 2 + 1], row + (size_t)x * 4);
        }
    }
    return true;
}

static bool yuy2_to_bgra(const uint8_t *in, int width, int height, uint8_t *out)
{
    for (int y = 0; y < height; y++)
    {
        const uint8_t *line = in + (size_t)y * (size_t)width * 2;
        uint8_t *row = out + (size_t)y * (size_t)width * 4;
        for (int x = 0; x + 1 < width; x += 2)
        {
            const uint8_t *p = line + (size_t)x * 2;
            yuv_to_bgra(p[0], p[1], p[3], row + (size_t)x * 4);
            yuv_to_bgra(p[2], p[1], p[3], row + (size_t)(x + 1) * 4);
        }
    }
    return true;
}

static inline void bgra_to_yuv(const uint8_t *p, int *y, int *u, int *v)
{
    const int b = p[0], g = p[1], r = p[2];
    *y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
    *u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
    *v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
}

static bool bgra_to_nv12(const uint8_t *in, int width, int height, uint8_t *out)
{
    uint8_t *chroma = out + (size_t)width * (size_t)height;
    for (int y = 0; y < height; y++)
    {
        for (int x = 0; x < width; x++)
        {
            int yy, u, v;
            bgra_to_yuv(in + ((size_t)y * (size_t)width + (size_t)x) * 4, &yy, &u, &v);
            out[(size_t)y * (size_t)width + (size_t)x] = clamp_byte(yy);
            if ((y % 2) == 0 && (x % 2) == 0)
            {
                uint8_t *uv = chroma + (size_t)(y / 2) * (size_t)width + (size_t)(x / 2) * 2;
                uv[0] = clamp_byte(u);
                uv[1] = clamp_byte(v);
            }
        }
    }
    return true;
}

static bool bgra_to_yuy2(const uint8_t *in, int width, int height, uint8_t *out)
{
    for (int y = 0; y < height; y++)
    {
        for (int x = 0; x + 1 < width; x += 2)
        {
            int y0, u0, v0, y1, u1, v1;
            bgra_to_yuv(in + ((size_t)y * (size_t)width + (size_t)x) * 4, &y0, &u0, &v0);
            bgra_to_yuv(in + ((size_t)y * (size_t)width + (size_t)x + 1) * 4, &y1, &u1, &v1);
            uint8_t *p = out + ((size_t)y * (size_t)width + (size_t)x) * 2;
            p[0] = clamp_byte(y0);
            p[1] = clamp_byte((u0 + u1) / 2);
            p[2] = clamp_byte(y1);
            p[3] = clamp_byte((v0 + v1) / 2);
        }
    }
    return true;
}

static bool mjpg_to_bgra(const uint8_t *in, size_t size, int width, int height, uint8_t *out)
{
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, in, (CFIndex)size, kCFAllocatorNull);
    if (data == NULL)
    {
        return false;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
    CFRelease(data);
    if (source == NULL)
    {
        return false;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image == NULL)
    {
        return false;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(out, (size_t)width, (size_t)height, 8, (size_t)width * 4, space,
                                                kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(space);
    bool ok = false;
    if (bitmap != NULL)
    {
        CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), image);
        CGContextRelease(bitmap);
        for (size_t i = 3; i < (size_t)width * (size_t)height * 4; i += 4)
        {
            out[i] = 255;
        }
        ok = true;
    }
    CGImageRelease(image);
    return ok;
}

static k4a_image_t block_to_image(playback_context_t *context, playback_track_t *track, int64_t index, k4a_image_format_t target)
{
    if (!load_block(context, track, index) || track->loaded_frames < 1)
    {
        return NULL;
    }
    const uint8_t *data = track->loaded + track->frame_offsets[0];
    const size_t size = track->frame_sizes[0];
    const int width = (int)track->width, height = (int)track->height;
    k4a_image_t image = NULL;

    if (target == K4A_IMAGE_FORMAT_DEPTH16 || target == K4A_IMAGE_FORMAT_IR16)
    {
        if (size != (size_t)width * (size_t)height * 2)
        {
            return NULL;
        }
        if (k4a_image_create(target, width, height, width * 2, &image) != K4A_RESULT_SUCCEEDED)
        {
            return NULL;
        }
        uint8_t *out = k4a_image_get_buffer(image);
        for (size_t i = 0; i + 1 < size; i += 2)
        {
            out[i] = data[i + 1];
            out[i + 1] = data[i];
        }
    }
    else if (target == track->format)
    {
        const int stride = track->format == K4A_IMAGE_FORMAT_COLOR_MJPG ? 0 : track->stride;
        if (k4a_image_create(target, width, height, stride, &image) != K4A_RESULT_SUCCEEDED)
        {
            return NULL;
        }
        if (k4a_image_get_size(image) < size)
        {
            /* MJPG: the SDK creates the image over the JPEG's own size. */
            k4a_image_release(image);
            image = openk4a_image_alloc(target, width, height, 0);
            if (image == NULL)
            {
                return NULL;
            }
            uint8_t *buffer = (uint8_t *)openk4a_alloc(size);
            if (buffer == NULL)
            {
                k4a_image_release(image);
                return NULL;
            }
            memcpy(buffer, data, size);
            k4a_image_release(image);
            image = openk4a_image_create(target, width, height, 0, size, buffer, NULL, NULL);
            if (image == NULL)
            {
                openk4a_free(buffer);
                return NULL;
            }
        }
        else
        {
            memcpy(k4a_image_get_buffer(image), data, size);
        }
    }
    else
    {
        /* Through BGRA. */
        uint8_t *bgra = (uint8_t *)openk4a_alloc((size_t)width * (size_t)height * 4);
        if (bgra == NULL)
        {
            return NULL;
        }
        bool ok = false;
        switch (track->format)
        {
        case K4A_IMAGE_FORMAT_COLOR_MJPG: ok = mjpg_to_bgra(data, size, width, height, bgra); break;
        case K4A_IMAGE_FORMAT_COLOR_NV12: ok = size >= (size_t)width * (size_t)height * 3 / 2 && nv12_to_bgra(data, width, height, bgra); break;
        case K4A_IMAGE_FORMAT_COLOR_YUY2: ok = size >= (size_t)width * (size_t)height * 2 && yuy2_to_bgra(data, width, height, bgra); break;
        case K4A_IMAGE_FORMAT_COLOR_BGRA32: ok = size >= (size_t)width * (size_t)height * 4; if (ok) memcpy(bgra, data, (size_t)width * (size_t)height * 4); break;
        default: break;
        }
        if (ok)
        {
            const int stride = openk4a_format_stride(target, width);
            size_t out_size = (size_t)stride * (size_t)height;
            if (target == K4A_IMAGE_FORMAT_COLOR_NV12)
            {
                out_size = (size_t)width * (size_t)height * 3 / 2; /* luma plane and interleaved chroma */
            }
            uint8_t *out = (uint8_t *)openk4a_alloc(out_size);
            image = out != NULL ? openk4a_image_create(target, width, height, stride, out_size, out, NULL, NULL) : NULL;
            if (image != NULL)
            {
                if (target == K4A_IMAGE_FORMAT_COLOR_BGRA32) memcpy(out, bgra, out_size);
                else if (target == K4A_IMAGE_FORMAT_COLOR_NV12) bgra_to_nv12(bgra, width, height, out);
                else if (target == K4A_IMAGE_FORMAT_COLOR_YUY2) bgra_to_yuy2(bgra, width, height, out);
                else { k4a_image_release(image); image = NULL; }
            }
            else
            {
                openk4a_free(out);
            }
        }
        openk4a_free(bgra);
    }
    if (image != NULL)
    {
        k4a_image_set_device_timestamp_usec(image, (track->blocks[index].timestamp_ns + context->start_offset_ns) / 1000);
    }
    return image;
}

/*=============================================================================
  Captures
=============================================================================*/

static k4a_stream_result_t get_capture(playback_context_t *context, k4a_capture_t *capture_handle, bool next)
{
    playback_track_t *tracks[3] = { context->color_track, context->depth_track, context->ir_track };
    int64_t candidate[3] = { -1, -1, -1 };
    bool has[3] = { false, false, false };
    int enabled = 0;
    uint64_t start = UINT64_MAX, end = 0;

    for (int i = 0; i < 3; i++)
    {
        playback_track_t *track = tracks[i];
        if (track == NULL)
        {
            continue;
        }
        enabled++;
        int64_t index;
        if (!track->positioned)
        {
            const int64_t bound = lower_bound(track, context->seek_timestamp_ns);
            index = next ? bound : bound - 1;
        }
        else
        {
            index = next ? track->position + 1 : track->position - 1;
            if (index > (int64_t)track->block_count) index = (int64_t)track->block_count;
            if (index < -1) index = -1;
        }
        candidate[i] = index;
        if (index >= 0 && index < (int64_t)track->block_count)
        {
            has[i] = true;
            const uint64_t ts = block_sync_ns(track, index);
            if (ts < start) start = ts;
            if (ts > end) end = ts;
        }
        else
        {
            /* Nothing that way: the reader now stands past the end (or before the start). */
            track->positioned = true;
            track->position = index;
        }
    }

    int valid = 0;
    const uint64_t half_period = context->sync_period_ns / 2;
    for (int i = 0; i < 3; i++)
    {
        if (!has[i])
        {
            continue;
        }
        const uint64_t ts = block_sync_ns(tracks[i], candidate[i]);
        const bool within = next ? (ts - start < half_period) : (end - ts < half_period);
        if (within)
        {
            valid++;
        }
        else
        {
            has[i] = false;
        }
    }

    *capture_handle = NULL;
    if (valid == 0)
    {
        return K4A_STREAM_RESULT_EOF;
    }
    if (k4a_capture_create(capture_handle) != K4A_RESULT_SUCCEEDED)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    for (int i = 0; i < 3; i++)
    {
        if (!has[i])
        {
            continue;
        }
        playback_track_t *track = tracks[i];
        track->positioned = true;
        track->position = candidate[i];
        const k4a_image_format_t target = i == 0 ? context->color_conversion : (i == 1 ? K4A_IMAGE_FORMAT_DEPTH16 : K4A_IMAGE_FORMAT_IR16);
        k4a_image_t image = block_to_image(context, track, candidate[i], target);
        if (image == NULL)
        {
            k4a_capture_release(*capture_handle);
            *capture_handle = NULL;
            return K4A_STREAM_RESULT_FAILED;
        }
        if (i == 0) k4a_capture_set_color_image(*capture_handle, image);
        else if (i == 1) k4a_capture_set_depth_image(*capture_handle, image);
        else k4a_capture_set_ir_image(*capture_handle, image);
        k4a_image_release(image);
    }
    (void)enabled;
    return K4A_STREAM_RESULT_SUCCEEDED;
}

k4a_stream_result_t k4a_playback_get_next_capture(k4a_playback_t playback_handle, k4a_capture_t *capture_handle)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || capture_handle == NULL)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    return get_capture(context, capture_handle, true);
}

k4a_stream_result_t k4a_playback_get_previous_capture(k4a_playback_t playback_handle, k4a_capture_t *capture_handle)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || capture_handle == NULL)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    return get_capture(context, capture_handle, false);
}

/*=============================================================================
  IMU samples
=============================================================================*/

static k4a_stream_result_t get_imu_sample(playback_context_t *context, k4a_imu_sample_t *imu_sample, bool next)
{
    memset(imu_sample, 0, sizeof(*imu_sample));
    playback_track_t *track = context->imu_track;
    if (track == NULL)
    {
        return K4A_STREAM_RESULT_EOF;
    }
    int64_t index;
    int sub;
    if (!track->positioned)
    {
        /* The block holding the seek point, or the first after it. */
        int64_t bound = lower_bound(track, context->seek_timestamp_ns);
        index = bound;
        sub = next ? 0 : -1;
        if (bound > 0)
        {
            const int64_t before = bound - 1;
            const block_entry_t *entry = &track->blocks[before];
            if (entry->timestamp_ns + track->sync_delay_ns + entry->duration_ns > context->seek_timestamp_ns && load_block(context, track, before))
            {
                /* Inside this block: the first sample at or after the seek point. */
                const uint64_t device_seek = context->seek_timestamp_ns + context->start_offset_ns;
                index = before;
                sub = next ? (int)track->loaded_frames : (int)track->loaded_frames - 1;
                for (uint32_t i = 0; i < track->loaded_frames; i++)
                {
                    const uint8_t *frame = track->loaded + track->frame_offsets[i];
                    uint64_t acc_ns;
                    memcpy(&acc_ns, frame, sizeof(acc_ns));
                    if (acc_ns >= device_seek)
                    {
                        sub = next ? (int)i : (int)i - 1;
                        break;
                    }
                }
            }
        }
        if (index >= 0 && index < (int64_t)track->block_count && load_block(context, track, index))
        {
            if (sub < 0)
            {
                index--;
                sub = index >= 0 && load_block(context, track, index) ? (int)track->loaded_frames - 1 : 0;
            }
            else if (sub >= (int)track->loaded_frames)
            {
                index++;
                sub = 0;
            }
        }
    }
    else
    {
        index = track->position;
        sub = track->sub_index + (next ? 1 : -1);
        if (index >= 0 && index < (int64_t)track->block_count && load_block(context, track, index))
        {
            if (sub >= (int)track->loaded_frames)
            {
                index++;
                sub = 0;
            }
            else if (sub < 0)
            {
                index--;
                sub = index >= 0 && load_block(context, track, index) ? (int)track->loaded_frames - 1 : 0;
            }
        }
        else if (index < 0 && next)
        {
            index = 0;
            sub = 0;
        }
        else if (index >= (int64_t)track->block_count && !next)
        {
            index = (int64_t)track->block_count - 1;
            sub = index >= 0 && load_block(context, track, index) ? (int)track->loaded_frames - 1 : 0;
        }
    }
    if (index < -1) index = -1;
    if (index > (int64_t)track->block_count) index = (int64_t)track->block_count;
    track->positioned = true;
    track->position = index;
    track->sub_index = sub;
    if (index < 0 || index >= (int64_t)track->block_count || !load_block(context, track, index) || sub < 0 || sub >= (int)track->loaded_frames)
    {
        return K4A_STREAM_RESULT_EOF;
    }
    if (track->frame_sizes[sub] < sizeof(matroska_imu_sample_t))
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    matroska_imu_sample_t sample;
    memcpy(&sample, track->loaded + track->frame_offsets[sub], sizeof(sample));
    imu_sample->acc_timestamp_usec = sample.acc_timestamp_ns / 1000;
    imu_sample->gyro_timestamp_usec = sample.gyro_timestamp_ns / 1000;
    imu_sample->temperature = NAN;
    for (int i = 0; i < 3; i++)
    {
        imu_sample->acc_sample.v[i] = sample.acc_data[i];
        imu_sample->gyro_sample.v[i] = sample.gyro_data[i];
    }
    return K4A_STREAM_RESULT_SUCCEEDED;
}

k4a_stream_result_t k4a_playback_get_next_imu_sample(k4a_playback_t playback_handle, k4a_imu_sample_t *imu_sample)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || imu_sample == NULL)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    return get_imu_sample(context, imu_sample, true);
}

k4a_stream_result_t k4a_playback_get_previous_imu_sample(k4a_playback_t playback_handle, k4a_imu_sample_t *imu_sample)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || imu_sample == NULL)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    return get_imu_sample(context, imu_sample, false);
}

/*=============================================================================
  Custom track data blocks
=============================================================================*/

static k4a_stream_result_t get_data_block(playback_context_t *context, const char *track_name, k4a_playback_data_block_t *handle, bool next)
{
    playback_track_t *track = track_by_name(context, track_name);
    if (track == NULL || k4a_playback_track_is_builtin((k4a_playback_t)context, track_name))
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    int64_t index;
    int sub;
    if (!track->positioned)
    {
        const int64_t bound = lower_bound(track, context->seek_timestamp_ns);
        index = next ? bound : bound - 1;
        sub = 0;
        if (!next && index >= 0 && load_block(context, track, index))
        {
            sub = (int)track->loaded_frames - 1;
        }
    }
    else
    {
        index = track->position;
        sub = track->sub_index + (next ? 1 : -1);
        if (index >= 0 && index < (int64_t)track->block_count && load_block(context, track, index))
        {
            if (sub >= (int)track->loaded_frames)
            {
                index++;
                sub = 0;
            }
            else if (sub < 0)
            {
                index--;
                sub = index >= 0 && load_block(context, track, index) ? (int)track->loaded_frames - 1 : 0;
            }
        }
        else if (index < 0 && next)
        {
            index = 0;
            sub = 0;
        }
        else if (index >= (int64_t)track->block_count && !next)
        {
            index = (int64_t)track->block_count - 1;
            sub = index >= 0 && load_block(context, track, index) ? (int)track->loaded_frames - 1 : 0;
        }
    }
    if (index < -1) index = -1;
    if (index > (int64_t)track->block_count) index = (int64_t)track->block_count;
    track->positioned = true;
    track->position = index;
    track->sub_index = sub;
    if (index < 0 || index >= (int64_t)track->block_count || !load_block(context, track, index) || sub < 0 || sub >= (int)track->loaded_frames)
    {
        return K4A_STREAM_RESULT_EOF;
    }
    playback_block_t *block = (playback_block_t *)openk4a_alloc_zero(sizeof(playback_block_t));
    if (block == NULL)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    block->size = track->frame_sizes[sub];
    block->data = (uint8_t *)openk4a_alloc(block->size > 0 ? block->size : 1);
    if (block->data == NULL)
    {
        openk4a_free(block);
        return K4A_STREAM_RESULT_FAILED;
    }
    memcpy(block->data, track->loaded + track->frame_offsets[sub], block->size);
    block->device_timestamp_usec = frame_timestamp_ns(track, index, sub) / 1000 + context->start_offset_ns / 1000;
    *handle = (k4a_playback_data_block_t)block;
    return K4A_STREAM_RESULT_SUCCEEDED;
}

k4a_stream_result_t k4a_playback_get_next_data_block(k4a_playback_t playback_handle, const char *track_name, k4a_playback_data_block_t *data_block_handle)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || track_name == NULL || data_block_handle == NULL)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    return get_data_block(context, track_name, data_block_handle, true);
}

k4a_stream_result_t k4a_playback_get_previous_data_block(k4a_playback_t playback_handle, const char *track_name, k4a_playback_data_block_t *data_block_handle)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL || track_name == NULL || data_block_handle == NULL)
    {
        return K4A_STREAM_RESULT_FAILED;
    }
    return get_data_block(context, track_name, data_block_handle, false);
}

uint64_t k4a_playback_data_block_get_device_timestamp_usec(k4a_playback_data_block_t data_block_handle)
{
    const playback_block_t *block = (const playback_block_t *)data_block_handle;
    return block != NULL ? block->device_timestamp_usec : 0;
}

size_t k4a_playback_data_block_get_buffer_size(k4a_playback_data_block_t data_block_handle)
{
    const playback_block_t *block = (const playback_block_t *)data_block_handle;
    return block != NULL ? block->size : 0;
}

uint8_t *k4a_playback_data_block_get_buffer(k4a_playback_data_block_t data_block_handle)
{
    playback_block_t *block = (playback_block_t *)data_block_handle;
    return block != NULL ? block->data : NULL;
}

void k4a_playback_data_block_release(k4a_playback_data_block_t data_block_handle)
{
    playback_block_t *block = (playback_block_t *)data_block_handle;
    if (block != NULL)
    {
        openk4a_free(block->data);
        openk4a_free(block);
    }
}

/*=============================================================================
  Seeking
=============================================================================*/

k4a_result_t k4a_playback_seek_timestamp(k4a_playback_t playback_handle, int64_t offset_usec, k4a_playback_seek_origin_t origin)
{
    playback_context_t *context = (playback_context_t *)playback_handle;
    if (context == NULL)
    {
        return K4A_RESULT_FAILED;
    }
    if (origin == K4A_PLAYBACK_SEEK_DEVICE_TIME)
    {
        origin = K4A_PLAYBACK_SEEK_BEGIN;
        offset_usec -= (int64_t)context->config.start_timestamp_offset_usec;
    }
    else if (origin != K4A_PLAYBACK_SEEK_BEGIN && origin != K4A_PLAYBACK_SEEK_END)
    {
        return K4A_RESULT_FAILED;
    }
    if (origin == K4A_PLAYBACK_SEEK_BEGIN && offset_usec < 0) offset_usec = 0;
    if (origin == K4A_PLAYBACK_SEEK_END && offset_usec > 0) offset_usec = 0;
    uint64_t target_ns;
    if (origin == K4A_PLAYBACK_SEEK_END)
    {
        const uint64_t back = (uint64_t)(-offset_usec) * 1000ULL;
        target_ns = back > context->last_timestamp_ns ? 0 : context->last_timestamp_ns + 1 - back;
    }
    else
    {
        target_ns = (uint64_t)offset_usec * 1000ULL;
    }
    context->seek_timestamp_ns = target_ns;
    for (size_t i = 0; i < context->track_count; i++)
    {
        context->tracks[i].positioned = false;
        context->tracks[i].position = 0;
        context->tracks[i].sub_index = 0;
    }
    return K4A_RESULT_SUCCEEDED;
}
