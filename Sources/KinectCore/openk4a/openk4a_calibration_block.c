/*=============================================================================
  The IR sensor's calibration block (NV tag 2).

  The device hands over one file: a 16-byte file header, a 240-byte header
  record, then a run of records, each starting with a 24-byte record header
  (id, version, size at +4). The layout was learned from the type information
  the depth engine's Linux build ships with (see docs/calibration-block.md);
  nothing of the engine's code is reproduced here, only the shape of the
  data the camera stores.

  What the depth pass needs from it is the P0 record set: per mode and per
  modulation frequency, the sensor's own phase offsets, as a profile per row
  and a profile per column, in radians.
=============================================================================*/

#include "openk4a.h"

/* Held to the fixtures bit for bit at every optimisation level, like the
 * depth pass: no fused multiply-adds. */
#pragma STDC FP_CONTRACT OFF

#define CALBLOCK_FILE_HEADER_BYTES 16
#define CALBLOCK_RECORD_HEADER_BYTES 24
#define CALBLOCK_HEADER_RECORD_BYTES 240
#define CALBLOCK_ID_HEADER 0xFF
#define CALBLOCK_ID_P0 0x50
#define CALBLOCK_ID_SPATIAL_TEMP 0x53
#define CALBLOCK_ID_GLOBAL_TEMP 0x54
#define CALBLOCK_ID_FOI_MASK 0x46
#define CALBLOCK_SPATIAL_TEMP_BYTES 0x92
#define CALBLOCK_GLOBAL_TEMP_BYTES 0x60
#define CALBLOCK_P0_COEFFS_AT 48

static uint16_t le16(const uint8_t *bytes)
{
    return (uint16_t)(bytes[0] | (bytes[1] << 8));
}

static void copy_text(char *out, size_t out_size, const uint8_t *bytes, size_t count)
{
    size_t n = 0;
    while (n < count && n + 1 < out_size && bytes[n] != '\0')
    {
        out[n] = (char)bytes[n];
        n++;
    }
    out[n] = '\0';
}

bool openk4a_calblock_parse(const uint8_t *block,
                            size_t size,
                            openk4a_calblock_info_t *info,
                            char *why,
                            size_t why_size)
{
    if (info != NULL)
    {
        memset(info, 0, sizeof(*info));
    }
    if (block == NULL || size < CALBLOCK_FILE_HEADER_BYTES + CALBLOCK_HEADER_RECORD_BYTES)
    {
        snprintf(why, why_size, "the block is %zu bytes, too short for its headers", size);
        return false;
    }
    const uint32_t claimed = openk4a_le32(block + 8);
    if (claimed != size)
    {
        snprintf(why, why_size, "the block says it is %u bytes and %zu arrived", (unsigned)claimed, size);
        return false;
    }
    const uint8_t *header = block + CALBLOCK_FILE_HEADER_BYTES;
    if (header[0] != CALBLOCK_ID_HEADER || openk4a_le32(header + 4) != CALBLOCK_HEADER_RECORD_BYTES)
    {
        snprintf(why, why_size, "the header record is not where it should be (id %02X, size %u)",
                 header[0], (unsigned)openk4a_le32(header + 4));
        return false;
    }

    openk4a_calblock_info_t parsed;
    memset(&parsed, 0, sizeof(parsed));
    parsed.file_version = le16(block + 0);
    parsed.calibration_version = le16(block + 2);
    parsed.file_size = claimed;
    parsed.record_count = le16(header + 0x18);
    parsed.chip_id = le16(header + 0x1a);
    parsed.sensor_rows = le16(header + 0x1c);
    parsed.sensor_cols = le16(header + 0x1e);
    copy_text(parsed.config_version, sizeof(parsed.config_version), header + 0x20, 128);
    copy_text(parsed.serial, sizeof(parsed.serial), header + 0xa0, 32);
    copy_text(parsed.chip_unique_id, sizeof(parsed.chip_unique_id), header + 0xc0, 32);

    /* Every record, checked to tile the block exactly. */
    size_t offset = CALBLOCK_FILE_HEADER_BYTES + CALBLOCK_HEADER_RECORD_BYTES;
    unsigned records = 0; /* the header counts the records after it */
    while (offset + CALBLOCK_RECORD_HEADER_BYTES <= size)
    {
        const uint32_t record_size = openk4a_le32(block + offset + 4);
        if (record_size < CALBLOCK_RECORD_HEADER_BYTES || offset + record_size > size)
        {
            snprintf(why, why_size, "record %u at %zu claims %u bytes", records, offset, (unsigned)record_size);
            return false;
        }
        if (block[offset] == CALBLOCK_ID_P0)
        {
            parsed.p0_records++;
        }
        records++;
        offset += record_size;
    }
    if (offset != size)
    {
        snprintf(why, why_size, "the records end at %zu of %zu bytes", offset, size);
        return false;
    }
    if (records != parsed.record_count)
    {
        snprintf(why, why_size, "the header counts %u records and %u were found", (unsigned)parsed.record_count, records);
        return false;
    }
    parsed.records_found = records;
    if (info != NULL)
    {
        *info = parsed;
    }
    why[0] = '\0';
    return true;
}

void openk4a_calblock_each(const uint8_t *block, size_t size, openk4a_calblock_visit_fn *visit, void *context)
{
    size_t offset = CALBLOCK_FILE_HEADER_BYTES;
    while (offset + CALBLOCK_RECORD_HEADER_BYTES <= size)
    {
        const uint32_t record_size = openk4a_le32(block + offset + 4);
        if (record_size < CALBLOCK_RECORD_HEADER_BYTES || offset + record_size > size)
        {
            return;
        }
        visit(block[offset], block[offset + 1], block + offset, record_size, context);
        offset += record_size;
    }
}

typedef struct
{
    uint8_t mode;
    uint8_t freq_index;
    openk4a_calblock_p0_t *out;
    bool found;
} p0_search_t;

static void p0_visit(uint8_t id, uint8_t version, const uint8_t *record, size_t size, void *context)
{
    p0_search_t *search = (p0_search_t *)context;
    if (search->found || id != CALBLOCK_ID_P0 || version != 4 || size < CALBLOCK_P0_COEFFS_AT)
    {
        return;
    }
    const uint8_t *fields = record + CALBLOCK_RECORD_HEADER_BYTES;
    if (fields[0] != search->mode || fields[1] != search->freq_index)
    {
        return;
    }
    openk4a_calblock_p0_t p0;
    memset(&p0, 0, sizeof(p0));
    p0.mode = fields[0];
    p0.freq_index = fields[1];
    p0.freq_10khz = le16(fields + 2);
    p0.integration_time = le16(fields + 4);
    p0.row_coeff_count = fields[6];
    p0.col_coeff_count = fields[7];
    p0.analog_bin_rows = fields[8];
    p0.analog_bin_cols = fields[9];
    p0.digital_bin_rows = fields[10];
    p0.digital_bin_cols = fields[11];
    p0.rows = le16(fields + 16);
    p0.cols = le16(fields + 18);
    p0.offset_rows = le16(fields + 20);
    p0.offset_cols = le16(fields + 22);
    const size_t wanted = ((size_t)p0.rows * p0.row_coeff_count + (size_t)p0.cols * p0.col_coeff_count) * sizeof(float);
    if (CALBLOCK_P0_COEFFS_AT + wanted > size)
    {
        return;
    }
    p0.row_coeffs = record + CALBLOCK_P0_COEFFS_AT;
    p0.col_coeffs = p0.row_coeffs + (size_t)p0.rows * p0.row_coeff_count * sizeof(float);
    *search->out = p0;
    search->found = true;
}

bool openk4a_calblock_find_p0(const uint8_t *block, size_t size, uint8_t mode, uint8_t freq_index, openk4a_calblock_p0_t *out)
{
    p0_search_t search = { mode, freq_index, out, false };
    if (block == NULL || out == NULL)
    {
        return false;
    }
    openk4a_calblock_each(block, size, p0_visit, &search);
    return search.found;
}

float openk4a_calblock_row_coeff(const openk4a_calblock_p0_t *p0, int row, int index)
{
    return openk4a_le_float(p0->row_coeffs + ((size_t)row * p0->row_coeff_count + (size_t)index) * sizeof(float));
}

float openk4a_calblock_col_coeff(const openk4a_calblock_p0_t *p0, int col, int index)
{
    return openk4a_le_float(p0->col_coeffs + ((size_t)col * p0->col_coeff_count + (size_t)index) * sizeof(float));
}

/*-----------------------------------------------------------------------------
  Spatial temperature correction records (0x53)
---------------------------------------------------------------------------*/

typedef struct
{
    uint8_t mode;
    uint8_t freq_index;
    openk4a_calblock_spatial_temp_t *out;
    bool found;
} spatial_search_t;

static void read_floats(float *out, const uint8_t *bytes, int count)
{
    for (int i = 0; i < count; i++)
    {
        out[i] = openk4a_le_float(bytes + (size_t)i * sizeof(float));
    }
}

static void spatial_visit(uint8_t id, uint8_t version, const uint8_t *record, size_t size, void *context)
{
    spatial_search_t *search = (spatial_search_t *)context;
    (void)version;
    if (search->found || id != CALBLOCK_ID_SPATIAL_TEMP || size < CALBLOCK_SPATIAL_TEMP_BYTES)
    {
        return;
    }
    if (record[0x18] != search->mode || record[0x19] != search->freq_index)
    {
        return;
    }
    openk4a_calblock_spatial_temp_t st;
    memset(&st, 0, sizeof(st));
    st.mode = record[0x18];
    st.freq_index = record[0x19];
    st.freq_10khz = le16(record + 0x1a);
    st.integration_time = le16(record + 0x1c);
    st.calibration_phase = le16(record + 0x1e);
    st.rows = le16(record + 0x20);
    st.cols = le16(record + 0x22);
    st.offset_rows = le16(record + 0x24);
    st.offset_cols = le16(record + 0x26);
    read_floats(st.simple_row_model, record + 0x28, 2);
    read_floats(st.simple_column_model, record + 0x30, 5);
    st.calibrations = le16(record + 0x44);
    read_floats(st.row_temp_coeff, record + 0x48, 4);
    read_floats(st.column_temp_coeff, record + 0x58, 10);
    read_floats(st.base_cal_temperature, record + 0x80, 3);
    st.per_column_offsets = size >= 0x90 + (size_t)st.cols * 2 ? record + 0x90 : NULL;
    *search->out = st;
    search->found = true;
}

bool openk4a_calblock_find_spatial_temp(const uint8_t *block, size_t size, uint8_t mode, uint8_t freq_index, openk4a_calblock_spatial_temp_t *out)
{
    spatial_search_t search = { mode, freq_index, out, false };
    if (block == NULL || out == NULL)
    {
        return false;
    }
    openk4a_calblock_each(block, size, spatial_visit, &search);
    return search.found;
}

/*-----------------------------------------------------------------------------
  Global temperature correction records (0x54)
---------------------------------------------------------------------------*/

typedef struct
{
    uint8_t mode;
    uint8_t capture;
    openk4a_calblock_global_temp_t *out;
    bool found;
} global_search_t;

static void global_visit(uint8_t id, uint8_t version, const uint8_t *record, size_t size, void *context)
{
    global_search_t *search = (global_search_t *)context;
    (void)version;
    if (search->found || id != CALBLOCK_ID_GLOBAL_TEMP || size < CALBLOCK_GLOBAL_TEMP_BYTES)
    {
        return;
    }
    if (record[0x18] != search->mode || record[0x1a] != search->capture)
    {
        return;
    }
    openk4a_calblock_global_temp_t gt;
    memset(&gt, 0, sizeof(gt));
    gt.mode = record[0x18];
    gt.freq_index = record[0x19];
    gt.capture = record[0x1a];
    gt.laser_id = record[0x1b];
    read_floats(gt.amplitude_coeff, record + 0x20, 8);
    read_floats(gt.phase_coeff, record + 0x40, 8);
    *search->out = gt;
    search->found = true;
}

bool openk4a_calblock_find_global_temp(const uint8_t *block, size_t size, uint8_t mode, uint8_t capture, openk4a_calblock_global_temp_t *out)
{
    global_search_t search = { mode, capture, out, false };
    if (block == NULL || out == NULL)
    {
        return false;
    }
    openk4a_calblock_each(block, size, global_visit, &search);
    return search.found;
}

/*-----------------------------------------------------------------------------
  Field-of-illumination mask records (0x46)
---------------------------------------------------------------------------*/

typedef struct
{
    uint8_t mode;
    openk4a_calblock_foi_t *out;
    bool found;
} foi_search_t;

static void foi_visit(uint8_t id, uint8_t version, const uint8_t *record, size_t size, void *context)
{
    foi_search_t *search = (foi_search_t *)context;
    (void)version;
    if (search->found || id != CALBLOCK_ID_FOI_MASK || size < 0x28 || record[0x18] != search->mode)
    {
        return;
    }
    const uint16_t rows = (uint16_t)(record[0x20] | (record[0x21] << 8));
    const uint16_t cols = (uint16_t)(record[0x22] | (record[0x23] << 8));
    if (rows == 0 || cols == 0 || size < 0x28 + (size_t)rows * 4)
    {
        return;
    }
    search->out->mode = record[0x18];
    search->out->rows = rows;
    search->out->cols = cols;
    search->out->bounds = record + 0x28;
    search->found = true;
}

bool openk4a_calblock_find_foi(const uint8_t *block, size_t size, uint8_t mode, openk4a_calblock_foi_t *out)
{
    foi_search_t search = { mode, out, false };
    if (block == NULL || out == NULL)
    {
        return false;
    }
    memset(out, 0, sizeof(*out));
    openk4a_calblock_each(block, size, foi_visit, &search);
    return search.found;
}

bool openk4a_calblock_foi_bounds(const openk4a_calblock_foi_t *foi, int row, int *first, int *last)
{
    if (foi == NULL || foi->bounds == NULL || row < 0 || row >= (int)foi->rows)
    {
        return false;
    }
    const uint8_t *pair = foi->bounds + (size_t)row * 4;
    const int a = pair[0] | (pair[1] << 8);
    const int b = pair[2] | (pair[3] << 8);
    if (a == 0xFFFF || b == 0xFFFF || a > b)
    {
        return false;
    }
    *first = a;
    *last = b < (int)foi->cols ? b : (int)foi->cols - 1;
    return true;
}

/*=============================================================================
  Illumination profile records (0x49)
=============================================================================*/

typedef struct
{
    uint8_t mode;
    openk4a_calblock_illum_t *out;
    bool found;
} illum_search_t;

static void illum_visit(uint8_t id, uint8_t version, const uint8_t *record, size_t size, void *context)
{
    (void)version;
    illum_search_t *search = (illum_search_t *)context;
    if (search->found || id != 0x49 || size < 24 + 32 || record[24] != search->mode)
    {
        return;
    }
    const uint8_t *p = record + 24;
    openk4a_calblock_illum_t *o = search->out;
    o->mode = p[0];
    o->binning = p[1];
    o->laser = p[2];
    o->profile_bytes = openk4a_le32(p + 4);
    o->ab_scale = openk4a_le_float(p + 8);
    o->target_reflectivity = openk4a_le_float(p + 12);
    for (int i = 0; i < 3; i++)
    {
        o->sensor_to_light_source[i] = (int16_t)(p[16 + 2 * i] | (p[17 + 2 * i] << 8));
    }
    o->target_distance = (int16_t)(p[22] | (p[23] << 8));
    o->rows = (uint16_t)(p[24] | (p[25] << 8));
    o->cols = (uint16_t)(p[26] | (p[27] << 8));
    o->offset_rows = (uint16_t)(p[28] | (p[29] << 8));
    o->offset_cols = (uint16_t)(p[30] | (p[31] << 8));
    search->found = true;
}

bool openk4a_calblock_find_illum(const uint8_t *block, size_t size, uint8_t mode, openk4a_calblock_illum_t *out)
{
    if (block == NULL || out == NULL)
    {
        return false;
    }
    memset(out, 0, sizeof(*out));
    illum_search_t search = { mode, out, false };
    openk4a_calblock_each(block, size, illum_visit, &search);
    return search.found;
}
