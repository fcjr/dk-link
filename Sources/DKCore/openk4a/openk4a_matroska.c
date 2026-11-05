#include "openk4a_matroska.h"

#include <stdlib.h>
#include <string.h>

/*=============================================================================
  Buffers
=============================================================================*/

void mkv_buf_init(mkv_buf_t *buf)
{
    memset(buf, 0, sizeof(*buf));
}

void mkv_buf_free(mkv_buf_t *buf)
{
    free(buf->data);
    memset(buf, 0, sizeof(*buf));
}

bool mkv_buf_reserve(mkv_buf_t *buf, size_t size)
{
    if (buf->failed)
    {
        return false;
    }
    if (buf->size + size <= buf->capacity)
    {
        return true;
    }
    size_t capacity = buf->capacity == 0 ? 256 : buf->capacity;
    while (capacity < buf->size + size)
    {
        capacity *= 2;
    }
    uint8_t *data = (uint8_t *)realloc(buf->data, capacity);
    if (data == NULL)
    {
        buf->failed = true;
        return false;
    }
    buf->data = data;
    buf->capacity = capacity;
    return true;
}

bool mkv_buf_append(mkv_buf_t *buf, const void *data, size_t size)
{
    if (!mkv_buf_reserve(buf, size))
    {
        return false;
    }
    if (size > 0)
    {
        memcpy(buf->data + buf->size, data, size);
    }
    buf->size += size;
    return true;
}

/*=============================================================================
  Variable-size integers and ids
=============================================================================*/

size_t mkv_vint_length(uint64_t value)
{
    /* A length-n vint holds 7n bits, less the all-ones reserved value. */
    for (size_t length = 1; length <= 8; length++)
    {
        const uint64_t limit = (1ULL << (7 * length)) - 1;
        if (value < limit)
        {
            return length;
        }
    }
    return 8;
}

size_t mkv_write_vint(uint8_t *out, uint64_t value, size_t length)
{
    if (length == 0)
    {
        length = mkv_vint_length(value);
    }
    for (size_t i = 0; i < length; i++)
    {
        out[length - 1 - i] = (uint8_t)(value & 0xFF);
        value >>= 8;
    }
    out[0] |= (uint8_t)(0x80 >> (length - 1));
    return length;
}

size_t mkv_id_length(uint32_t id)
{
    if (id >= 0x01000000u)
    {
        return 4;
    }
    if (id >= 0x00010000u)
    {
        return 3;
    }
    if (id >= 0x00000100u)
    {
        return 2;
    }
    return 1;
}

size_t mkv_write_id(uint8_t *out, uint32_t id)
{
    const size_t length = mkv_id_length(id);
    for (size_t i = 0; i < length; i++)
    {
        out[length - 1 - i] = (uint8_t)(id & 0xFF);
        id >>= 8;
    }
    return length;
}

bool mkv_put_header(mkv_buf_t *buf, uint32_t id, uint64_t size, size_t size_length)
{
    uint8_t header[12];
    size_t n = mkv_write_id(header, id);
    n += mkv_write_vint(header + n, size, size_length);
    return mkv_buf_append(buf, header, n);
}

static bool put_element(mkv_buf_t *buf, uint32_t id, const void *data, size_t size)
{
    return mkv_put_header(buf, id, size, 0) && mkv_buf_append(buf, data, size);
}

bool mkv_put_uint(mkv_buf_t *buf, uint32_t id, uint64_t value)
{
    uint8_t bytes[8];
    size_t length = 1;
    while (length < 8 && (value >> (8 * length)) != 0)
    {
        length++;
    }
    for (size_t i = 0; i < length; i++)
    {
        bytes[length - 1 - i] = (uint8_t)((value >> (8 * i)) & 0xFF);
    }
    return put_element(buf, id, bytes, length);
}

bool mkv_put_sint(mkv_buf_t *buf, uint32_t id, int64_t value)
{
    uint8_t bytes[8];
    size_t length = 1;
    while (length < 8)
    {
        const int64_t shifted = value >> (8 * length - 1);
        if (shifted == 0 || shifted == -1)
        {
            break;
        }
        length++;
    }
    for (size_t i = 0; i < length; i++)
    {
        bytes[length - 1 - i] = (uint8_t)(((uint64_t)value >> (8 * i)) & 0xFF);
    }
    return put_element(buf, id, bytes, length);
}

bool mkv_put_float(mkv_buf_t *buf, uint32_t id, double value)
{
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    uint8_t bytes[8];
    for (size_t i = 0; i < 8; i++)
    {
        bytes[7 - i] = (uint8_t)((bits >> (8 * i)) & 0xFF);
    }
    return put_element(buf, id, bytes, 8);
}

bool mkv_put_string(mkv_buf_t *buf, uint32_t id, const char *text)
{
    return put_element(buf, id, text, strlen(text));
}

bool mkv_put_binary(mkv_buf_t *buf, uint32_t id, const void *data, size_t size)
{
    return put_element(buf, id, data, size);
}

bool mkv_put_master(mkv_buf_t *buf, uint32_t id, const mkv_buf_t *children)
{
    if (children->failed)
    {
        buf->failed = true;
        return false;
    }
    return put_element(buf, id, children->data, children->size);
}

bool mkv_put_void(mkv_buf_t *buf, size_t total)
{
    if (total < 2)
    {
        return false;
    }
    /* id (1 byte) + size field + padding = total. The size field is sized so
     * that the whole thing comes out exactly. */
    size_t size_length = 1;
    while (size_length < 8 && mkv_vint_length(total - 1 - size_length) > size_length)
    {
        size_length++;
    }
    if (total < 1 + size_length)
    {
        return false;
    }
    const size_t padding = total - 1 - size_length;
    uint8_t header[9];
    header[0] = (uint8_t)MKV_ID_VOID;
    mkv_write_vint(header + 1, padding, size_length);
    if (!mkv_buf_append(buf, header, 1 + size_length))
    {
        return false;
    }
    if (!mkv_buf_reserve(buf, padding))
    {
        return false;
    }
    memset(buf->data + buf->size, 0, padding);
    buf->size += padding;
    return true;
}

/*=============================================================================
  Reading
=============================================================================*/

uint64_t mkv_parse_vint(const uint8_t *data, size_t available, size_t *length, bool marker)
{
    if (available == 0 || data[0] == 0)
    {
        *length = 0;
        return 0;
    }
    size_t n = 1;
    uint8_t mask = 0x80;
    while ((data[0] & mask) == 0)
    {
        mask >>= 1;
        n++;
    }
    if (n > available)
    {
        *length = 0;
        return 0;
    }
    uint64_t value = marker ? (uint64_t)(data[0] & (uint8_t)(mask - 1)) : (uint64_t)data[0];
    for (size_t i = 1; i < n; i++)
    {
        value = (value << 8) | data[i];
    }
    *length = n;
    return value;
}

bool mkv_parse_header(const uint8_t *data, size_t length, mkv_header_t *header)
{
    size_t id_length = 0;
    const uint64_t id = mkv_parse_vint(data, length, &id_length, false);
    if (id_length == 0 || id_length > 4)
    {
        return false;
    }
    size_t size_length = 0;
    const uint64_t size = mkv_parse_vint(data + id_length, length - id_length, &size_length, true);
    if (size_length == 0)
    {
        return false;
    }
    header->id = (uint32_t)id;
    header->header_size = id_length + size_length;
    header->unknown_size = size == (1ULL << (7 * size_length)) - 1;
    header->size = header->unknown_size ? UINT64_MAX : size;
    return true;
}

bool mkv_read_header(FILE *file, mkv_header_t *header)
{
    uint8_t bytes[12];
    const long start = ftell(file);
    const size_t got = fread(bytes, 1, sizeof(bytes), file);
    if (got == 0 || !mkv_parse_header(bytes, got, header))
    {
        return false;
    }
    fseek(file, start + (long)header->header_size, SEEK_SET);
    return true;
}

uint64_t mkv_parse_uint(const uint8_t *data, size_t size)
{
    uint64_t value = 0;
    for (size_t i = 0; i < size && i < 8; i++)
    {
        value = (value << 8) | data[i];
    }
    return value;
}

int64_t mkv_parse_sint(const uint8_t *data, size_t size)
{
    if (size == 0)
    {
        return 0;
    }
    int64_t value = (data[0] & 0x80) ? -1 : 0;
    for (size_t i = 0; i < size && i < 8; i++)
    {
        value = (int64_t)(((uint64_t)value << 8) | data[i]);
    }
    return value;
}

double mkv_parse_float(const uint8_t *data, size_t size)
{
    if (size == 4)
    {
        uint32_t bits = (uint32_t)mkv_parse_uint(data, 4);
        float value;
        memcpy(&value, &bits, sizeof(value));
        return value;
    }
    if (size == 8)
    {
        uint64_t bits = mkv_parse_uint(data, 8);
        double value;
        memcpy(&value, &bits, sizeof(value));
        return value;
    }
    return 0.0;
}

bool mkv_next(mkv_cursor_t *cursor, mkv_header_t *header, const uint8_t **payload)
{
    if (cursor->at >= cursor->size)
    {
        return false;
    }
    if (!mkv_parse_header(cursor->data + cursor->at, cursor->size - cursor->at, header))
    {
        cursor->at = cursor->size;
        return false;
    }
    const size_t data_at = cursor->at + header->header_size;
    uint64_t size = header->size;
    if (header->unknown_size || data_at + size > cursor->size)
    {
        size = cursor->size - data_at;
        header->size = size;
    }
    *payload = cursor->data + data_at;
    cursor->at = data_at + (size_t)size;
    return true;
}

bool mkv_parse_block(const uint8_t *payload, size_t size, mkv_block_info_t *info, size_t *frame_offsets, size_t *frame_sizes, uint32_t max_frames)
{
    size_t n = 0;
    info->track_number = mkv_parse_vint(payload, size, &n, true);
    if (n == 0 || size < n + 3)
    {
        return false;
    }
    size_t at = n;
    info->timecode = (int16_t)(((uint16_t)payload[at] << 8) | payload[at + 1]);
    at += 2;
    info->flags = payload[at++];
    const uint8_t lacing = info->flags & 0x06;
    if (lacing == MKV_LACING_NONE)
    {
        info->frame_count = 1;
        info->data_offset = at;
        if (max_frames >= 1)
        {
            frame_offsets[0] = at;
            frame_sizes[0] = size - at;
        }
        return true;
    }
    if (at >= size)
    {
        return false;
    }
    const uint32_t count = (uint32_t)payload[at++] + 1;
    info->frame_count = count;
    size_t sizes[256];
    if (count > 256)
    {
        return false;
    }
    if (lacing == MKV_LACING_XIPH)
    {
        size_t total = 0;
        for (uint32_t i = 0; i + 1 < count; i++)
        {
            size_t frame = 0;
            while (at < size && payload[at] == 255)
            {
                frame += 255;
                at++;
            }
            if (at >= size)
            {
                return false;
            }
            frame += payload[at++];
            sizes[i] = frame;
            total += frame;
        }
        if (at + total > size)
        {
            return false;
        }
        sizes[count - 1] = size - at - total;
    }
    else if (lacing == MKV_LACING_EBML)
    {
        size_t total = 0;
        size_t vint_length = 0;
        const uint64_t first = mkv_parse_vint(payload + at, size - at, &vint_length, true);
        if (vint_length == 0)
        {
            return false;
        }
        at += vint_length;
        sizes[0] = (size_t)first;
        total = sizes[0];
        int64_t previous = (int64_t)first;
        for (uint32_t i = 1; i + 1 < count; i++)
        {
            const uint64_t raw = mkv_parse_vint(payload + at, size - at, &vint_length, true);
            if (vint_length == 0)
            {
                return false;
            }
            at += vint_length;
            /* A signed difference: the vint's range is centred. */
            const int64_t bias = (int64_t)((1ULL << (7 * vint_length - 1)) - 1);
            const int64_t delta = (int64_t)raw - bias;
            previous += delta;
            if (previous < 0)
            {
                return false;
            }
            sizes[i] = (size_t)previous;
            total += sizes[i];
        }
        if (at + total > size)
        {
            return false;
        }
        sizes[count - 1] = size - at - total;
    }
    else
    {
        /* fixed: equal parts of what is left */
        const size_t remaining = size - at;
        if (remaining % count != 0)
        {
            return false;
        }
        for (uint32_t i = 0; i < count; i++)
        {
            sizes[i] = remaining / count;
        }
    }
    info->data_offset = at;
    size_t offset = at;
    for (uint32_t i = 0; i < count; i++)
    {
        if (i < max_frames)
        {
            frame_offsets[i] = offset;
            frame_sizes[i] = sizes[i];
        }
        offset += sizes[i];
    }
    return offset <= size;
}
