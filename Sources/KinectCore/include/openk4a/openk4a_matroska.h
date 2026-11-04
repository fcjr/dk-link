/*=============================================================================
  EBML and Matroska, the little that k4arecord files use.

  A recording is a Matroska file: an EBML head, then one Segment holding a
  SeekHead, Info, Tracks, Attachments, Tags, Clusters of blocks and Cues.
  This is a writer that builds elements in memory and a reader that walks
  element headers in a file, with the element ids the SDK's layout uses.
=============================================================================*/

#ifndef OPENK4A_MATROSKA_H
#define OPENK4A_MATROSKA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* Element ids, written as their raw bytes. */
#define MKV_ID_EBML 0x1A45DFA3u
#define MKV_ID_EBML_VERSION 0x4286u
#define MKV_ID_EBML_READ_VERSION 0x42F7u
#define MKV_ID_EBML_MAX_ID_LENGTH 0x42F2u
#define MKV_ID_EBML_MAX_SIZE_LENGTH 0x42F3u
#define MKV_ID_DOCTYPE 0x4282u
#define MKV_ID_DOCTYPE_VERSION 0x4287u
#define MKV_ID_DOCTYPE_READ_VERSION 0x4285u
#define MKV_ID_VOID 0xECu
#define MKV_ID_CRC32 0xBFu
#define MKV_ID_SEGMENT 0x18538067u
#define MKV_ID_SEEK_HEAD 0x114D9B74u
#define MKV_ID_SEEK 0x4DBBu
#define MKV_ID_SEEK_ID 0x53ABu
#define MKV_ID_SEEK_POSITION 0x53ACu
#define MKV_ID_INFO 0x1549A966u
#define MKV_ID_TIMECODE_SCALE 0x2AD7B1u
#define MKV_ID_DURATION 0x4489u
#define MKV_ID_DATE_UTC 0x4461u
#define MKV_ID_TITLE 0x7BA9u
#define MKV_ID_MUXING_APP 0x4D80u
#define MKV_ID_WRITING_APP 0x5741u
#define MKV_ID_TRACKS 0x1654AE6Bu
#define MKV_ID_TRACK_ENTRY 0xAEu
#define MKV_ID_TRACK_NUMBER 0xD7u
#define MKV_ID_TRACK_UID 0x73C5u
#define MKV_ID_TRACK_TYPE 0x83u
#define MKV_ID_FLAG_LACING 0x9Cu
#define MKV_ID_DEFAULT_DURATION 0x23E383u
#define MKV_ID_TRACK_NAME 0x536Eu
#define MKV_ID_CODEC_ID 0x86u
#define MKV_ID_CODEC_PRIVATE 0x63A2u
#define MKV_ID_VIDEO 0xE0u
#define MKV_ID_PIXEL_WIDTH 0xB0u
#define MKV_ID_PIXEL_HEIGHT 0xBAu
#define MKV_ID_ATTACHMENTS 0x1941A469u
#define MKV_ID_ATTACHED_FILE 0x61A7u
#define MKV_ID_FILE_NAME 0x466Eu
#define MKV_ID_FILE_MIME_TYPE 0x4660u
#define MKV_ID_FILE_DATA 0x465Cu
#define MKV_ID_FILE_UID 0x46AEu
#define MKV_ID_TAGS 0x1254C367u
#define MKV_ID_TAG 0x7373u
#define MKV_ID_TARGETS 0x63C0u
#define MKV_ID_TARGET_TYPE 0x63CAu
#define MKV_ID_TAG_TRACK_UID 0x63C5u
#define MKV_ID_TAG_ATTACHMENT_UID 0x63C6u
#define MKV_ID_SIMPLE_TAG 0x67C8u
#define MKV_ID_TAG_NAME 0x45A3u
#define MKV_ID_TAG_STRING 0x4487u
#define MKV_ID_CLUSTER 0x1F43B675u
#define MKV_ID_TIMECODE 0xE7u
#define MKV_ID_SIMPLE_BLOCK 0xA3u
#define MKV_ID_BLOCK_GROUP 0xA0u
#define MKV_ID_BLOCK 0xA1u
#define MKV_ID_BLOCK_DURATION 0x9Bu
#define MKV_ID_CUES 0x1C53BB6Bu
#define MKV_ID_CUE_POINT 0xBBu
#define MKV_ID_CUE_TIME 0xB3u
#define MKV_ID_CUE_TRACK_POSITIONS 0xB7u
#define MKV_ID_CUE_TRACK 0xF7u
#define MKV_ID_CUE_CLUSTER_POSITION 0xF1u
#define MKV_ID_CUE_BLOCK_NUMBER 0x5378u

#define MKV_TRACK_TYPE_VIDEO 1
#define MKV_TRACK_TYPE_AUDIO 2
#define MKV_TRACK_TYPE_SUBTITLE 0x11

#define MKV_LACING_NONE 0x00
#define MKV_LACING_XIPH 0x02
#define MKV_LACING_FIXED 0x04
#define MKV_LACING_EBML 0x06

/*-----------------------------------------------------------------------------
  A growable byte buffer, for building elements in memory.
---------------------------------------------------------------------------*/
typedef struct
{
    uint8_t *data;
    size_t size;
    size_t capacity;
    bool failed;
} mkv_buf_t;

void mkv_buf_init(mkv_buf_t *buf);
void mkv_buf_free(mkv_buf_t *buf);
bool mkv_buf_append(mkv_buf_t *buf, const void *data, size_t size);
bool mkv_buf_reserve(mkv_buf_t *buf, size_t size);

/* Variable-size integers: the length needed for a value, and writing one in
 * exactly `length` bytes (0 for the shortest). Ids are written raw. */
size_t mkv_vint_length(uint64_t value);
size_t mkv_write_vint(uint8_t *out, uint64_t value, size_t length);
size_t mkv_id_length(uint32_t id);
size_t mkv_write_id(uint8_t *out, uint32_t id);

bool mkv_put_uint(mkv_buf_t *buf, uint32_t id, uint64_t value);
bool mkv_put_sint(mkv_buf_t *buf, uint32_t id, int64_t value);
bool mkv_put_float(mkv_buf_t *buf, uint32_t id, double value);
bool mkv_put_string(mkv_buf_t *buf, uint32_t id, const char *text);
bool mkv_put_binary(mkv_buf_t *buf, uint32_t id, const void *data, size_t size);
bool mkv_put_master(mkv_buf_t *buf, uint32_t id, const mkv_buf_t *children);
/* An element header alone: id and a size in `size_length` bytes (0 = shortest). */
bool mkv_put_header(mkv_buf_t *buf, uint32_t id, uint64_t size, size_t size_length);
/* A Void element that occupies exactly `total` bytes, header included (total >= 2). */
bool mkv_put_void(mkv_buf_t *buf, size_t total);

/*-----------------------------------------------------------------------------
  Reading.
---------------------------------------------------------------------------*/
typedef struct
{
    uint32_t id;
    uint64_t size;      /* data size; UINT64_MAX when unknown */
    size_t header_size; /* id + size field */
    bool unknown_size;
} mkv_header_t;

/* Parses an element header from memory; returns false when `length` is too short. */
bool mkv_parse_header(const uint8_t *data, size_t length, mkv_header_t *header);
/* Reads an element header at the current file position, leaving the position at the data. */
bool mkv_read_header(FILE *file, mkv_header_t *header);
/* Decodes a vint at `data`; `*length` gets its byte length. `marker` says whether to strip the length marker. */
uint64_t mkv_parse_vint(const uint8_t *data, size_t available, size_t *length, bool marker);

uint64_t mkv_parse_uint(const uint8_t *data, size_t size);
int64_t mkv_parse_sint(const uint8_t *data, size_t size);
double mkv_parse_float(const uint8_t *data, size_t size);

/* Walks the children of a master element held in memory. */
typedef struct
{
    const uint8_t *data;
    size_t size;
    size_t at;
} mkv_cursor_t;

/* Moves to the next child: fills header and points *payload at its data. False at the end. */
bool mkv_next(mkv_cursor_t *cursor, mkv_header_t *header, const uint8_t **payload);

/* The frames of a block (SimpleBlock payload or Block payload): track number,
 * relative timecode, flags, and up to `max_frames` frame offsets/sizes within
 * the payload. Returns false on malformed data. */
typedef struct
{
    uint64_t track_number;
    int16_t timecode;
    uint8_t flags;
    uint32_t frame_count;
    size_t data_offset;    /* where frame data begins within the payload */
} mkv_block_info_t;

bool mkv_parse_block(const uint8_t *payload, size_t size, mkv_block_info_t *info, size_t *frame_offsets, size_t *frame_sizes, uint32_t max_frames);

#endif /* OPENK4A_MATROSKA_H */
