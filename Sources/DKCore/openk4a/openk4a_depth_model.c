/*=============================================================================
  The depth pass, and the per-mode tables it runs on.

  The closed depth engine is a D3D11 pipeline, and both halves of what it
  runs were read off it rather than guessed: the shaders it carries
  (shader_dump.c, in the SDK tree's tools/depthengine_open) and one recording
  of the numbers it binds while it runs (capture_engine.cmd, beside it). What
  comes out is

     projection   the nine taps of one pixel -> (real, imaginary) per
                  frequency, from the inverse of the sensor's phase matrix,
                  then rotated by the per-pixel phase correction the tables
                  hold for that frequency;
     de-alias     the three phases -> three integer wrap counts out of the
                  de-alias LUT, indexed by two rounded combinations of those
                  phases -> one radial distance, a weighted mean of the three
                  single-frequency estimates;
     radial -> Z  the radialToZ table, which is the cosine of the pixel's
                  angle off the axis;
     gates        the LUT's own invalid mark, a confidence term, the radius
                  range, how far apart the three amplitudes are, the two
                  amplitude floors, and the reflectivity.

  Everything above the tables is arithmetic this file does for itself. The
  tables are the device's own numbers, and there are three places to get them
  from, tried in this order:

    1. the device's own calibration block, read over the depth MCU's command
       set - the same 506,952-byte block the closed engine is created with.
       openk4a_block.c expands it;
    2. depth_tables.bin beside the executable, in the cache beside it, or at
       the path in OPENK4A_DEPTH_TABLES - the file form depth_model.py --write
       produces, and the only way to give another unit or another mode the
       engine's own numbers;
    3. the calibration compiled into openk4a_depth_builtin.h, which is one
       device's NFOV_UNBINNED set.

  Two things make the pass fast enough to matter, and neither changes what it
  computes. The phase correction is a constant per pixel per frequency - the
  temperature factor in it is a table scalar, not the live sensor
  temperature - so its cosine and sine are computed once, when the model is
  built, and the per-frame work is a rotation instead of two transcendental
  calls per tap. And the filter's weight is exp(cJblExpTerm * (1 - cos)),
  a function of the cosine alone: 27 million of those a frame is a table
  lookup, not an exp.
=============================================================================*/

#include "openk4a.h"

#include <math.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif

/* The pass is held to its fixtures bit for bit, at every optimisation level
 * and on every machine: no fused multiply-adds, which would otherwise differ
 * between -O0 and -O2 by a millimetre on the odd pixel. */
#pragma STDC FP_CONTRACT OFF

/* The filter runs eight pixels at a time where the vector unit is there, and
 * the scalar path below is what everything else - another compiler, another
 * architecture - gets. Both are held to the same reference. */
#if defined(__AVX2__)
#include <immintrin.h>
#define OPENK4A_HAVE_AVX2 1
#else
#define OPENK4A_HAVE_AVX2 0
#endif

#define OPENK4A_DEALIAS_ENTRIES 128
#define OPENK4A_WEIGHT_ENTRIES 1024
#define OPENK4A_DEPTH_TABLES_MAGIC "OK4ADPTH"
/* The name the v2 form was written under before this tree was OpenK4A. */
#define OPENK4A_DEPTH_TABLES_MAGIC_AK2 "AK2DPTH2"
/* The first form carried one device's NFOV_UNBINNED tables and no
 * dimensions; this one names the mode and the grid, so any mode's tables can
 * sit beside the executable. ak64 wrote the same layout as v1 under its own
 * magic. All four names are read, so files written before the rename load. */
#define OPENK4A_DEPTH_TABLES_MAGIC_V1 "AK2DPTH1"
#define OPENK4A_DEPTH_TABLES_MAGIC_AK64 "AK64DPTH"
/* The phase correction's temperature term, measured on this device. */
#define OPENK4A_TEMP_SLOPE 0.0099913086f
#define OPENK4A_TEMP_INTERCEPT (-0.2786280954f)

/* The speed of light the engine's distances are built on, in mm/s: the
 * speed of light in air, 299,714,130 m/s (c / 1.000261). It is the engine's
 * own range constant: its Alpha[k] = M_k * c / (2 f_base sum(M^2)) as
 * recorded from the engine (openk4a_depth_builtin.h) gives this c from each
 * of the three frequencies to 1e-7, and the engine's radial output measured
 * against ours agrees with it to 0.01 mm/m (3e8 reads 0.96 mm/m long,
 * c in vacuum 0.27 mm/m short). See docs/calibration-block.md. */
#define OPENK4A_ENGINE_LIGHT_SPEED_MM_PER_S 2.9971413e11
/* Engine constants per mode, measured against the engine's own masks on
 * this camera's frames and not found in the block: the wide modes'
 * reflectivity gate sits at three eighths of the narrow modes'. */
#define OPENK4A_ORACLE_REFLECTIVITY_WFOV_SCALE 0.375f
#define OPENK4A_ORACLE_IR_SCALE_NFOV_UNBINNED 0.9522f
#define OPENK4A_ORACLE_IR_SCALE_NFOV_2X2BINNED 0.9338f
#define OPENK4A_ORACLE_IR_SCALE_WFOV_2X2BINNED 0.9382f
#define OPENK4A_ORACLE_IR_SCALE_WFOV_UNBINNED 0.9434f

/* OPENK4A_FITTED_RESIDUAL_*: the last difference against Microsoft's engine,
 * FITTED, not derived. After every block-derived term, engine minus ours
 * (radial, 0.1 mm resolution) is spatially uniform and flat across range
 * within a frame, and follows the laser temperature T as
 *
 *     residual_mm = C_mode + K * (T - T0)^2
 *
 * Fitted 2026-11-04 against the engine on serial 000146321712 (this unit):
 * 22 NFOV unbinned and WFOV 2x2 binned frames of a warm-up series, two cold
 * frames and the fixtures, laser 25.3 to 35.1 C; shared T0 and K (rms 0.04
 * mm over the 22 frames; T0 +/- 0.25 C, K +/- 0.004); one frame each for the
 * NFOV binned and WFOV unbinned constants. No block record predicts it (see
 * docs/calibration-block.md, "Range residual"), so it may be per unit:
 * another camera may need its own, or none. Applied on the block path only,
 * as a radial offset before the radial-to-Z step. */
#define OPENK4A_FITTED_RESIDUAL_T0_C 31.25
#define OPENK4A_FITTED_RESIDUAL_K_MM_PER_C2 0.0462
#define OPENK4A_FITTED_RESIDUAL_NFOV_UNBINNED_MM 0.168
#define OPENK4A_FITTED_RESIDUAL_NFOV_2X2BINNED_MM -0.125
#define OPENK4A_FITTED_RESIDUAL_WFOV_2X2BINNED_MM 1.414
#define OPENK4A_FITTED_RESIDUAL_WFOV_UNBINNED_MM 1.037

struct openk4a_depth_model
{
    k4a_depth_mode_t mode;
    uint32_t flags; /* bit 0: the engine's output is Z rather than radial */
    int width;
    int height;
    size_t pixels;

    float spatial_temp_factor;
    /* The phase correction's temperature term is linear in the sensor's own
     * temperature, and the factor is recomputed per frame from the footer:
     * the engine does the same, and a factor frozen at one capture's
     * temperature is a systematic phase error that grows as the sensor
     * warms. The two constants are measured - eight captures between 27.5 and
     * 31.7 degrees, an affine fit with a worst residual of 2.6e-5, which is
     * a fifth of a micron at the longest frequency. */
    float temperature_slope;
    float temperature_intercept;
    float built_factor;
    float smoothed_temperature;
    bool have_temperature;
    bool track_temperature;
    float p0_phase_conversion;
    float inv_2pi;
    float two_pi;
    float output_scale;
    float ab_multiplier;
    float ab_min_freq_threshold;
    float ab_sum_threshold;
    float ab_ratio_threshold;
    float max_conf_sq;
    float saturated_input;
    float saturated_ab;
    float reflectivity_min_threshold;
    float radial_min;
    float radial_max;
    float invalid_lut_entry;
    float jbl_exp_term;
    float jbl_edge_threshold;
    float center_low_ab_threshold;
    float neighbor_low_ab_threshold;
    float r_offset[2];
    float r_scale[2];
    float alpha[3];
    float c_m[3];
    float c_md[3];
    float t[2][3];
    float row_coeffs[3];
    float inverse_r[3][3];
    float inverse_i[3][3];

    float *col_coeffs;   /* height * 3 */
    float *lut;          /* OPENK4A_DEALIAS_ENTRIES * 3 */
    float *theta;        /* 3 * pixels, radians */
    float *rotate;       /* 3 * pixels * 2, cos then sin */
    uint16_t *radial_to_z; /* pixels */
    float *weight_table; /* OPENK4A_WEIGHT_ENTRIES */
    float weight_scale;

    /* The projection's output, where the filter reads it back: one plane per
     * frequency per component, so the three components of a neighbour are
     * three contiguous floats rather than three strides into one array. The
     * buffer belongs to the model and is written over every frame, which is
     * what keeps a frame from allocating thirteen megabytes and faulting in
     * thirteen megabytes of fresh pages on every pass. */
    float *proj;         /* 3 frequencies * 3 components * pixels */

    /* The frame unpacked into its tap planes: nine planes of companded,
     * signed magnitudes, which is what the projection reads and what makes
     * the projection a set of contiguous loads. A mode that bins 2x2 gets
     * its planes over the sub-image and a second set over the output grid;
     * the two are the same buffer when the mode does not bin. */
    float *tap;          /* OPENK4A_TAP_COUNT * pixels, the output grid */
    float *tap_sub;      /* OPENK4A_TAP_COUNT * sub_pixels, the sub-image */
    int binning;
    size_t sub_pixels;

    /* The three IR amplitudes of a pixel, summed before they are scaled and
     * rounded, because the reference rounds once at the end and the planes
     * are accumulated one frequency at a time. */
    float *ir_amp;       /* pixels */

    uint32_t source;
    char where[64];
    uint32_t rotation_generation; /* bumped whenever `rotate` is rebuilt */
    uint8_t global_source_mode;   /* which block mode's laser records are in use */
    bool block_spatial_temperature; /* the temperature terms came from the device's block */

    /* The engine's own invalidations, applied on the block path only (the
     * builtin path is held to its fixtures as it was): the field of
     * illumination mask, and the sensor's saturation code on any tap. */
    bool engine_rules;
    uint8_t *mask;      /* pixels; 1 inside the field of illumination; NULL when every pixel is */
    uint8_t *saturated; /* pixels; 1 where a tap of this frame carried the saturation code */
    float ir_scale;     /* the IR plane is the amplitude sum times this */

    /* The illuminator baseline. The phase measures the round trip from the
     * illuminator to the scene and back to the sensor; the engine reports
     * the sensor's own distance d, which for a measured (|P - L| + |P|) / 2 = p
     * along unit ray u is d = (p^2 - |L|^2 / 4) / (p - u.L / 2). Per pixel
     * u.L / 2 in millimetres; NULL when the block did not say where L is. */
    float *ls_half_dot;
    float ls_quarter_sq;

    /* The global (laser) temperature correction: per frequency and tap, a
     * polynomial in laser temperature / 100 giving a phase in turns. The
     * mean over a frequency's three taps, relative to its value at the
     * calibration temperature, is subtracted from the phase, which the
     * rotation does. */
    bool have_global;
    float global_coeff[3][3][8];
    float global_tcal;
    float global_offset[3]; /* radians, folded into the rotation */
    float smoothed_laser_temperature;
    bool have_laser;

    /* The fitted residual (OPENK4A_FITTED_RESIDUAL_*): the mode's constant,
     * and the frame's whole offset in the output's own units, recomputed
     * with the smoothed laser temperature and added to the radial distance. */
    bool fitted;
    double fitted_constant_mm;
    float fitted_residual_units;
};

enum
{
    OPENK4A_MODEL_FROM_BLOCK = 1,
    OPENK4A_MODEL_FROM_FILE,
    OPENK4A_MODEL_FROM_BUILTIN
};

#include "openk4a_depth_builtin.h"

/*=============================================================================
  Building a model
=============================================================================*/

static openk4a_depth_model_t *model_alloc(k4a_depth_mode_t mode, int width, int height)
{
    openk4a_depth_model_t *model = (openk4a_depth_model_t *)openk4a_alloc_zero(sizeof(openk4a_depth_model_t));
    if (model == NULL)
    {
        return NULL;
    }
    model->mode = mode;
    model->width = width;
    model->height = height;
    model->pixels = (size_t)width * (size_t)height;
    model->ir_scale = OPENK4A_IR_TAP_SCALE;
    return model;
}

static bool model_arrays(openk4a_depth_model_t *model)
{
    const size_t pixels = model->pixels;
    const openk4a_mode_t *mode = openk4a_mode_of(model->mode);
    model->binning = mode != NULL ? mode->binning : 1;
    model->sub_pixels = pixels * (size_t)model->binning * (size_t)model->binning;
    model->col_coeffs = (float *)openk4a_alloc_zero((size_t)model->height * 3 * sizeof(float));
    model->lut = (float *)openk4a_alloc_zero(OPENK4A_DEALIAS_ENTRIES * 3 * sizeof(float));
    model->theta = (float *)openk4a_alloc_zero(pixels * 3 * sizeof(float));
    model->rotate = (float *)openk4a_alloc_zero(pixels * 3 * 2 * sizeof(float));
    model->radial_to_z = (uint16_t *)openk4a_alloc_zero(pixels * sizeof(uint16_t));
    model->weight_table = (float *)openk4a_alloc_zero(OPENK4A_WEIGHT_ENTRIES * sizeof(float));
    model->proj = (float *)openk4a_alloc_zero(pixels * 3 * 3 * sizeof(float));
    model->tap = (float *)openk4a_alloc_zero(pixels * OPENK4A_TAP_COUNT * sizeof(float));

    /* A mode that does not bin reads its planes straight out of the sub-
     * image, which is the output grid; there is no second copy to keep. */
    model->tap_sub = model->binning == 1
                         ? model->tap
                         : (float *)openk4a_alloc_zero(model->sub_pixels * OPENK4A_TAP_COUNT * sizeof(float));
    model->ir_amp = (float *)openk4a_alloc_zero(pixels * sizeof(float));
    model->saturated = (uint8_t *)openk4a_alloc_zero(pixels);
    return model->saturated != NULL && model->col_coeffs != NULL && model->lut != NULL && model->theta != NULL &&
           model->rotate != NULL && model->radial_to_z != NULL && model->weight_table != NULL &&
           model->proj != NULL && model->tap != NULL && model->tap_sub != NULL && model->ir_amp != NULL;
}

/* The filter's weight is a function of the cosine alone, so the table is
 * built from the model's own exponent and the pass indexes into it. */
static void model_build_weight_table(openk4a_depth_model_t *model)
{
    for (int i = 0; i < OPENK4A_WEIGHT_ENTRIES; i++)
    {
        const double cosine = -1.0 + 2.0 * (double)i / (double)(OPENK4A_WEIGHT_ENTRIES - 1);
        model->weight_table[i] = (float)exp((double)model->jbl_exp_term * (1.0 - cosine));
    }
    model->weight_scale = (float)((OPENK4A_WEIGHT_ENTRIES - 1) / 2);
}

/* The phase correction is theta = p0 * c + (col * rowCoeff[f] +
 * colCoeff[row][f]) * tempFactor, and the tables are the device's. It is a
 * constant, so the cosine and sine are taken here, once, rather than eight
 * hundred thousand times a frame. */
/* theta = p0 (fixed) + the spatial term scaled by the temperature factor, so
 * the rotation depends on the factor and is rebuilt when it moves far enough
 * to matter. Rebuilding costs one fixed-point measurement per pixel per
 * frequency, which is why it is done on a threshold rather than every
 * frame. */
static void model_build_rotation(openk4a_depth_model_t *model, float factor)
{
    for (int f = 0; f < 3; f++)
    {
        float *theta = model->theta + (size_t)f * model->pixels;
        float *rotate = model->rotate + (size_t)f * model->pixels * 2;
        const float global = model->global_offset[f];
        for (int row = 0; row < model->height; row++)
        {
            const float spatial = model->col_coeffs[(size_t)row * 3 + f] * factor + global;
            const float row_step = model->row_coeffs[f] * factor;
            for (int column = 0; column < model->width; column++)
            {
                const size_t pixel = (size_t)row * model->width + (size_t)column;
                const float value = theta[pixel] + (float)column * row_step + spatial;
                /* One call for both: the optimiser merges a sinf and a cosf
                 * of the same argument into this call anyway, and the merged
                 * result differs from the separate ones in the last place
                 * for some arguments, which was enough to move a pixel by a
                 * millimetre between an -O0 and an -O2 build. Calling it
                 * directly keeps every build, and the Metal pass that reads
                 * this table, on the same numbers. */
#if defined(__APPLE__)
                __sincosf(value, &rotate[pixel * 2 + 1], &rotate[pixel * 2]);
#else
                rotate[pixel * 2] = cosf(value);
                rotate[pixel * 2 + 1] = sinf(value);
#endif
            }
        }
    }
    model->built_factor = factor;
    model->rotation_generation++;
}

/* The temperature factor for a frame, out of the frame's own footer. */
static float model_factor_for(const openk4a_depth_model_t *model, float sensor_temp_c)
{
    if (!model->track_temperature)
    {
        return model->spatial_temp_factor;
    }
    return model->temperature_slope * sensor_temp_c + model->temperature_intercept;
}

/* A quarter of a degree is what the SDK's own inertial rectifier uses for the
 * same purpose, and at that threshold the phase error it leaves is 0.06 mm at
 * the longest frequency. */
#define OPENK4A_TEMPERATURE_STEP 0.25f

void openk4a_depth_model_free(openk4a_depth_model_t *model)
{
    if (model == NULL)
    {
        return;
    }
    openk4a_free(model->col_coeffs);
    openk4a_free(model->mask);
    openk4a_free(model->saturated);
    openk4a_free(model->ls_half_dot);
    openk4a_free(model->lut);
    openk4a_free(model->theta);
    openk4a_free(model->rotate);
    openk4a_free(model->radial_to_z);
    openk4a_free(model->weight_table);
    openk4a_free(model->proj);
    if (model->tap_sub != model->tap)
    {
        openk4a_free(model->tap_sub);
    }
    openk4a_free(model->tap);
    openk4a_free(model->ir_amp);
    openk4a_free(model);
}

bool openk4a_depth_model_valid(const openk4a_depth_model_t *model)
{
    return model != NULL && model->rotate != NULL;
}

const char *openk4a_depth_model_where(const openk4a_depth_model_t *model)
{
    return model != NULL ? model->where : "";
}

/*-----------------------------------------------------------------------------
  The file form. It is the closed engine's own tables, packed once by
  depth_model.py --write; OpenK4A reads it for a unit or a mode whose block
  expansion has not been proved.
---------------------------------------------------------------------------*/

/* The file: a header, then the scalars, the small tables, the per-row column
 * coefficients, the de-alias LUT, the three phase tables in 1/65535 turns and
 * radialToZ - each the size its own dimensions imply. */
typedef struct
{
    uint32_t mode;
    uint32_t width;
    uint32_t height;
    uint32_t flags;
    float scalars[24];
    float alpha[3];
    float c_m[3];
    float c_md[3];
    float c_t[2][3];
    float row_coeffs[3];
    float inverse_r[3][3];
    float inverse_i[3][3];
} openk4a_table_header_t;

static bool table_read(void *destination, size_t size, FILE *file)
{
    return fread(destination, 1, size, file) == size;
}

static void model_from_scalars(openk4a_depth_model_t *model, const float *s)
{
    model->spatial_temp_factor = s[0];
    model->p0_phase_conversion = s[1];
    model->inv_2pi = s[2];
    model->two_pi = s[3];
    model->output_scale = s[4];
    model->ab_multiplier = s[5];
    model->ab_min_freq_threshold = s[6];
    model->ab_sum_threshold = s[7];
    model->ab_ratio_threshold = s[8];
    model->max_conf_sq = s[9];
    model->saturated_input = s[10];
    model->saturated_ab = s[11];
    model->reflectivity_min_threshold = s[12];
    model->radial_min = s[13];
    model->radial_max = s[14];
    model->invalid_lut_entry = s[15];
    model->jbl_exp_term = s[16];
    model->jbl_edge_threshold = s[17];
    model->center_low_ab_threshold = s[18];
    model->neighbor_low_ab_threshold = s[19];
    model->r_offset[0] = s[20];
    model->r_offset[1] = s[21];
    model->r_scale[0] = s[22];
    model->r_scale[1] = s[23];
}

/* Where a table file for a mode is looked for: the path the caller names in
 * OPENK4A_DEPTH_TABLES, then beside the executable, then the tree's own cache.
 * The name carries the depth mode, so the tables for several modes can sit
 * together. */
static bool model_file_find(k4a_depth_mode_t mode, char *out, size_t out_size)
{
    const char *given = getenv("OPENK4A_DEPTH_TABLES");
    if (given != NULL && given[0] != '\0')
    {
        FILE *named = fopen(given, "rb");
        if (named != NULL)
        {
            fclose(named);
            snprintf(out, out_size, "%s", given);
            return true;
        }
    }

    char exe[512];
    char exe_dir[512] = "";
    if (openk4a_exe_dir(exe, sizeof(exe)))
    {
        snprintf(exe_dir, sizeof(exe_dir), "%s", exe);
    }

    const char *candidates[] = {
        "%s\\depth_tables_%d.bin",
        "%s\\cache\\depth_tables_%d.bin",
        "%s\\..\\cache\\depth_tables_%d.bin",
        "bin\\cache\\depth_tables_%d.bin",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++)
    {
        if (exe_dir[0] == '\0' && candidates[i][0] == '%')
        {
            continue;
        }
        if (strstr(candidates[i], "%d") != NULL)
        {
            snprintf(out, out_size, candidates[i], exe_dir, (int)mode);
        }
        else
        {
            snprintf(out, out_size, candidates[i], exe_dir);
        }
        FILE *probe = fopen(out, "rb");
        if (probe != NULL)
        {
            fclose(probe);
            return true;
        }
    }
    return false;
}

static openk4a_depth_model_t *model_from_file(k4a_depth_mode_t mode, const char *path)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL)
    {
        return NULL;
    }
    char magic[8];
    if (fread(magic, 1, sizeof(magic), file) != sizeof(magic) ||
        (memcmp(magic, OPENK4A_DEPTH_TABLES_MAGIC, 8) != 0 && memcmp(magic, OPENK4A_DEPTH_TABLES_MAGIC_AK2, 8) != 0 &&
         memcmp(magic, OPENK4A_DEPTH_TABLES_MAGIC_AK64, 8) != 0 && memcmp(magic, OPENK4A_DEPTH_TABLES_MAGIC_V1, 8) != 0))
    {
        fclose(file);
        return NULL;
    }

    openk4a_table_header_t header;
    memset(&header, 0, sizeof(header));
    if (!table_read(&header, sizeof(header), file))
    {
        fclose(file);
        return NULL;
    }
    if (header.mode != (uint32_t)mode || header.width == 0 || header.height == 0)
    {
        openk4a_log(OPENK4A_LOG_WARNING, "%s holds %ux%u tables for mode %u, not this mode's",
                path, (unsigned)header.width, (unsigned)header.height, (unsigned)header.mode);
        fclose(file);
        return NULL;
    }

    openk4a_depth_model_t *model = model_alloc(mode, (int)header.width, (int)header.height);
    if (model == NULL || !model_arrays(model))
    {
        openk4a_depth_model_free(model);
        fclose(file);
        return NULL;
    }

    model->flags = header.flags;
    model_from_scalars(model, header.scalars);
    model->temperature_slope = OPENK4A_TEMP_SLOPE;
    model->temperature_intercept = OPENK4A_TEMP_INTERCEPT;
    model->track_temperature = true;
    memcpy(model->alpha, header.alpha, sizeof(model->alpha));
    memcpy(model->c_m, header.c_m, sizeof(model->c_m));
    memcpy(model->c_md, header.c_md, sizeof(model->c_md));
    memcpy(model->t, header.c_t, sizeof(model->t));
    memcpy(model->row_coeffs, header.row_coeffs, sizeof(model->row_coeffs));
    memcpy(model->inverse_r, header.inverse_r, sizeof(model->inverse_r));
    memcpy(model->inverse_i, header.inverse_i, sizeof(model->inverse_i));

    const size_t pixels = model->pixels;
    bool complete = table_read(model->col_coeffs, (size_t)model->height * 3 * sizeof(float), file) &&
                    table_read(model->lut, OPENK4A_DEALIAS_ENTRIES * 3 * sizeof(float), file);

    /* The file carries p0 as the engine's own R16 table, in 1/65535 turns;
     * the model wants the phase in radians, so it is converted as it is
     * read. */
    uint16_t *phase = (uint16_t *)openk4a_alloc(pixels * sizeof(uint16_t));
    if (phase == NULL)
    {
        complete = false;
    }
    for (int f = 0; f < 3; f++)
    {
        if (!complete || !table_read(phase, pixels * sizeof(uint16_t), file))
        {
            complete = false;
            break;
        }
        float *theta = model->theta + (size_t)f * model->pixels;
        for (size_t pixel = 0; pixel < pixels; pixel++)
        {
            theta[pixel] = (float)phase[pixel] * (1.0f / 65535.0f) * model->p0_phase_conversion;
        }
    }
    if (complete && !table_read(model->radial_to_z, pixels * sizeof(uint16_t), file))
    {
        complete = false;
    }
    openk4a_free(phase);
    fclose(file);

    if (!complete)
    {
        openk4a_log(OPENK4A_LOG_WARNING, "%s is short: it stops before the tables do", path);
        openk4a_depth_model_free(model);
        return NULL;
    }

    model_build_weight_table(model);
    model->source = OPENK4A_MODEL_FROM_FILE;
    snprintf(model->where, sizeof(model->where), "%s", path);
    return model;
}

/*-----------------------------------------------------------------------------
  The compiled-in form: one device's NFOV_UNBINNED calibration, with p0 as a
  row profile plus a column profile per frequency and radialToZ as a
  polynomial.
---------------------------------------------------------------------------*/

static openk4a_depth_model_t *model_from_builtin(k4a_depth_mode_t mode)
{
    if (mode != K4A_DEPTH_MODE_NFOV_UNBINNED)
    {
        return NULL;
    }

    openk4a_depth_model_t *model = model_alloc(mode, OPENK4A_BUILTIN_WIDTH, OPENK4A_BUILTIN_HEIGHT);
    if (model == NULL || !model_arrays(model))
    {
        openk4a_depth_model_free(model);
        return NULL;
    }

    model->flags = 1;
    model_from_scalars(model, openk4a_builtin_scalars);
    model->temperature_slope = OPENK4A_TEMP_SLOPE;
    model->temperature_intercept = OPENK4A_TEMP_INTERCEPT;
    model->track_temperature = true;
    model->block_spatial_temperature = false;
    memcpy(model->alpha, openk4a_builtin_alpha, sizeof(model->alpha));
    memcpy(model->c_m, openk4a_builtin_c_m, sizeof(model->c_m));
    memcpy(model->c_md, openk4a_builtin_c_md, sizeof(model->c_md));
    for (int k = 0; k < 2; k++)
    {
        for (int j = 0; j < 3; j++)
        {
            model->t[k][j] = openk4a_builtin_c_t[k * 3 + j];
        }
    }
    memcpy(model->row_coeffs, openk4a_builtin_row_coeffs, sizeof(model->row_coeffs));
    for (int k = 0; k < 3; k++)
    {
        for (int j = 0; j < 3; j++)
        {
            model->inverse_r[k][j] = openk4a_builtin_inverse_r[k * 3 + j];
            model->inverse_i[k][j] = openk4a_builtin_inverse_i[k * 3 + j];
        }
    }
    memcpy(model->col_coeffs, openk4a_builtin_col_coeffs, (size_t)model->height * 3 * sizeof(float));
    memcpy(model->lut, openk4a_builtin_lut, OPENK4A_DEALIAS_ENTRIES * 3 * sizeof(float));

    const float *const row_profile[3] = {
        openk4a_builtin_p0_row_0, openk4a_builtin_p0_row_1, openk4a_builtin_p0_row_2
    };
    const float *const col_profile[3] = {
        openk4a_builtin_p0_col_0, openk4a_builtin_p0_col_1, openk4a_builtin_p0_col_2
    };
    for (int f = 0; f < 3; f++)
    {
        float *theta = model->theta + (size_t)f * model->pixels;
        for (int row = 0; row < model->height; row++)
        {
            for (int column = 0; column < model->width; column++)
            {
                /* The profile is in turns and the composed table is its
                 * fractional part; the phase conversion takes it to radians
                 * with the rest of the model. */
                double turns = (double)row_profile[f][row] + (double)col_profile[f][column];
                turns -= floor(turns);
                theta[(size_t)row * model->width + column] = (float)(turns * model->p0_phase_conversion);
            }
        }
    }

    const float *origin = openk4a_builtin_radial_origin;
    for (int row = 0; row < model->height; row++)
    {
        const double v = ((double)row - (double)origin[1]) / (double)origin[3];
        for (int column = 0; column < model->width; column++)
        {
            const double u = ((double)column - (double)origin[0]) / (double)origin[2];
            double sum = 0.0;
            double u_power = 1.0;
            size_t k = 0;
            for (int i = 0; i <= openk4a_builtin_radial_degree; i++)
            {
                double v_power = 1.0;
                for (int j = 0; j <= openk4a_builtin_radial_degree - i; j++)
                {
                    sum += (double)openk4a_builtin_radial_coeffs[k] * u_power * v_power;
                    v_power *= v;
                    k++;
                }
                u_power *= u;
            }
            double scaled = sum * 65535.0 + 0.5;
            if (scaled < 0.0)
            {
                scaled = 0.0;
            }
            else if (scaled > 65535.0)
            {
                scaled = 65535.0;
            }
            model->radial_to_z[(size_t)row * model->width + column] = (uint16_t)scaled;
        }
    }

    model_build_weight_table(model);
    model->source = OPENK4A_MODEL_FROM_BUILTIN;
    snprintf(model->where, sizeof(model->where), "compiled in");
    return model;
}

/*-----------------------------------------------------------------------------
  The device's own calibration block, expanded. openk4a_block.c knows the
  container; this asks it for one mode's tables.
---------------------------------------------------------------------------*/

/* The device's own calibration block, expanded into one mode's tables. This
 * is the piece that makes OpenK4A work on a camera it has never seen: the block
 * is the camera's, and it holds a record set per mode. */
static bool block_expand(openk4a_depth_model_t *model,
                         const uint8_t *block,
                         size_t size,
                         const openk4a_calibration_t *calibration,
                         char *why,
                         size_t why_size);

/* The block's own mode numbering, and the grid each k4a mode decodes on. A
 * k4a mode that bins in software reads the native record and bins it. */
typedef struct
{
    uint8_t block_mode;
    int binning;
    int width;
    int height;
} block_mode_t;

static bool block_mode_of(k4a_depth_mode_t mode, block_mode_t *out)
{
    switch (mode)
    {
    case K4A_DEPTH_MODE_NFOV_UNBINNED:
        *out = (block_mode_t){ 4, 1, 640, 576 };
        return true;
    case K4A_DEPTH_MODE_NFOV_2X2BINNED:
        *out = (block_mode_t){ 4, 2, 320, 288 };
        return true;
    case K4A_DEPTH_MODE_WFOV_2X2BINNED:
        *out = (block_mode_t){ 7, 1, 512, 512 };
        return true;
    case K4A_DEPTH_MODE_WFOV_UNBINNED:
        *out = (block_mode_t){ 5, 1, 1024, 1024 };
        return true;
    default:
        return false;
    }
}

/* The illuminator's position from the mode's illumination profile record,
 * folded into a per-pixel u.L / 2 over the calibration's unit rays. */
static bool block_light_source(openk4a_depth_model_t *model,
                               const uint8_t *block,
                               size_t size,
                               uint8_t block_mode,
                               const openk4a_calibration_t *calibration)
{
    openk4a_calblock_illum_t illum;
    k4a_calibration_camera_t camera;
    if (calibration == NULL || !openk4a_calblock_find_illum(block, size, block_mode, &illum) ||
        !openk4a_calibration_for_depth_mode(calibration, model->mode, &camera))
    {
        return false;
    }
    const double lx = illum.sensor_to_light_source[0];
    const double ly = illum.sensor_to_light_source[1];
    const double lz = illum.sensor_to_light_source[2];
    float *table = (float *)openk4a_alloc_zero(model->pixels * sizeof(float));
    if (table == NULL)
    {
        return false;
    }
    for (int row = 0; row < model->height; row++)
    {
        for (int column = 0; column < model->width; column++)
        {
            const float point2d[2] = { (float)column, (float)row };
            float ray[3];
            int valid = 0;
            double value = 0.0;
            if (openk4a_calibration_unproject(&camera, point2d, 1.0f, ray, &valid) && valid)
            {
                const double x = ray[0];
                const double y = ray[1];
                const double norm = sqrt(1.0 + x * x + y * y);
                value = (x * lx + y * ly + lz) / norm * 0.5;
            }
            table[(size_t)row * model->width + column] = (float)value;
        }
    }
    openk4a_free(model->ls_half_dot);
    model->ls_half_dot = table;
    model->ls_quarter_sq = (float)((lx * lx + ly * ly + lz * lz) * 0.25);
    openk4a_log(OPENK4A_LOG_INFO, "illuminator at (%d, %d, %d) mm from the sensor for block mode %u", (int)lx, (int)ly, (int)lz, block_mode);
    return true;
}

/* radialToZ from the camera's own intrinsics: the cosine of each pixel's
 * ray against the optical axis, 1 / sqrt(1 + x^2 + y^2) for the undistorted
 * normalised ray, in 1/65535. */
static bool block_radial_to_z(openk4a_depth_model_t *model, const openk4a_calibration_t *calibration, char *why, size_t why_size)
{
    k4a_calibration_camera_t camera;
    if (calibration == NULL || !openk4a_calibration_for_depth_mode(calibration, model->mode, &camera))
    {
        snprintf(why, why_size, "no camera calibration to build radialToZ from");
        return false;
    }
    int invalid = 0;
    for (int row = 0; row < model->height; row++)
    {
        for (int column = 0; column < model->width; column++)
        {
            const float point2d[2] = { (float)column, (float)row };
            float ray[3];
            int valid = 0;
            double scaled = 0.0;
            if (openk4a_calibration_unproject(&camera, point2d, 1.0f, ray, &valid) && valid)
            {
                const double x = ray[0];
                const double y = ray[1];
                scaled = 65535.0 / sqrt(1.0 + x * x + y * y) + 0.5;
            }
            else
            {
                invalid++;
            }
            if (scaled > 65535.0)
            {
                scaled = 65535.0;
            }
            model->radial_to_z[(size_t)row * model->width + column] = (uint16_t)scaled;
        }
    }
    if (invalid > (int)model->pixels / 2)
    {
        snprintf(why, why_size, "the camera calibration would not unproject most of the frame");
        return false;
    }
    return true;
}

/* The device's own calibration block, expanded into one mode's tables.
 *
 * From the block: the P0 phase offsets, per mode and frequency, as a profile
 * per row plus a profile per column in radians. The column entries carry
 * three coefficients each; on the cameras seen so far only the last is set,
 * and a block that uses the others is declined rather than guessed at.
 *
 * From the camera's calibration document: radialToZ.
 *
 * From the engine's constants compiled in: the dealiasing tables, the tap
 * demodulation and the thresholds, which depend on the frequencies (the same
 * three for every depth mode) and not on the unit, and the spatial
 * temperature model, which is a unit's but small, and still the recorded
 * unit's until the block's own temperature records are understood. */
static bool block_expand(openk4a_depth_model_t *model,
                         const uint8_t *block,
                         size_t size,
                         const openk4a_calibration_t *calibration,
                         char *why,
                         size_t why_size)
{
    openk4a_calblock_info_t info;
    if (!openk4a_calblock_parse(block, size, &info, why, why_size))
    {
        return false;
    }
    block_mode_t bm;
    if (!block_mode_of(model->mode, &bm) || bm.width != model->width || bm.height != model->height)
    {
        snprintf(why, why_size, "no block mode for %s", openk4a_mode_name(model->mode));
        return false;
    }

    openk4a_calblock_p0_t p0[3];
    for (int f = 0; f < 3; f++)
    {
        if (!openk4a_calblock_find_p0(block, size, bm.block_mode, (uint8_t)(f + 1), &p0[f]))
        {
            snprintf(why, why_size, "no P0 record for block mode %u frequency %d", (unsigned)bm.block_mode, f + 1);
            return false;
        }
        if (p0[f].rows != model->height * bm.binning || p0[f].cols != model->width * bm.binning ||
            p0[f].row_coeff_count != 1 || p0[f].col_coeff_count < 1)
        {
            snprintf(why, why_size, "P0 record for mode %u is %ux%u with %u/%u coefficients, not the grid expected",
                     (unsigned)bm.block_mode, p0[f].cols, p0[f].rows, p0[f].row_coeff_count, p0[f].col_coeff_count);
            return false;
        }
        for (int column = 0; column < p0[f].cols; column++)
        {
            for (int index = 0; index + 1 < p0[f].col_coeff_count; index++)
            {
                if (openk4a_calblock_col_coeff(&p0[f], column, index) != 0.0f)
                {
                    snprintf(why, why_size, "the P0 column coefficients use a term this tree does not read");
                    return false;
                }
            }
        }
    }
    /* The frequencies the constants were made for: 198, 189 and 54 MHz. */
    if (p0[0].freq_10khz != 19800 || p0[1].freq_10khz != 18900 || p0[2].freq_10khz != 5400)
    {
        snprintf(why, why_size, "the block's frequencies (%u, %u, %u) are not the ones the dealiasing tables are for",
                 p0[0].freq_10khz, p0[1].freq_10khz, p0[2].freq_10khz);
        return false;
    }

    model->flags = 1;
    model_from_scalars(model, openk4a_builtin_scalars);
    model->temperature_slope = OPENK4A_TEMP_SLOPE;
    model->temperature_intercept = OPENK4A_TEMP_INTERCEPT;
    model->track_temperature = true;
    model->block_spatial_temperature = false;
    memcpy(model->alpha, openk4a_builtin_alpha, sizeof(model->alpha));
    memcpy(model->c_m, openk4a_builtin_c_m, sizeof(model->c_m));
    memcpy(model->c_md, openk4a_builtin_c_md, sizeof(model->c_md));
    for (int k = 0; k < 2; k++)
    {
        for (int j = 0; j < 3; j++)
        {
            model->t[k][j] = openk4a_builtin_c_t[k * 3 + j];
        }
    }
    for (int k = 0; k < 3; k++)
    {
        for (int j = 0; j < 3; j++)
        {
            model->inverse_r[k][j] = openk4a_builtin_inverse_r[k * 3 + j];
            model->inverse_i[k][j] = openk4a_builtin_inverse_i[k * 3 + j];
        }
    }
    memcpy(model->lut, openk4a_builtin_lut, OPENK4A_DEALIAS_ENTRIES * 3 * sizeof(float));

    /* The spatial temperature model, from the device's own records when it
     * has them for the mode: per row a polynomial in row / rows plus a
     * constant, per column a slope, all scaled by 0.01 (T - base). The
     * recorded camera's tables are the fallback, read by sensor row. */
    openk4a_calblock_spatial_temp_t spatial[3];
    bool have_spatial = true;
    for (int f = 0; f < 3 && have_spatial; f++)
    {
        have_spatial = openk4a_calblock_find_spatial_temp(block, size, bm.block_mode, (uint8_t)f, &spatial[f]) &&
                       spatial[f].rows == model->height * bm.binning && spatial[f].cols == model->width * bm.binning &&
                       spatial[f].freq_10khz == p0[f].freq_10khz && spatial[f].base_cal_temperature[0] > -40.0f &&
                       spatial[f].base_cal_temperature[0] < 120.0f;
    }
    if (have_spatial)
    {
        for (int row = 0; row < model->height; row++)
        {
            for (int f = 0; f < 3; f++)
            {
                const double v = (double)(row * bm.binning) / (double)spatial[f].rows;
                double value = 0.0;
                double power = 1.0;
                for (int k = 5; k < 10; k++)
                {
                    value += (double)spatial[f].column_temp_coeff[k] * power;
                    power *= v;
                }
                model->col_coeffs[(size_t)row * 3 + f] = (float)(value + (double)spatial[f].row_temp_coeff[1]);
            }
        }
        for (int f = 0; f < 3; f++)
        {
            model->row_coeffs[f] = spatial[f].row_temp_coeff[3] / (float)spatial[f].cols * (float)bm.binning;
        }
        model->temperature_slope = 0.01f;
        model->temperature_intercept = -0.01f * spatial[0].base_cal_temperature[0];
        model->block_spatial_temperature = true;
    }
    else
    {
        for (int row = 0; row < model->height; row++)
        {
            int sensor_row = (int)p0[0].offset_rows + row * bm.binning - 180;
            if (sensor_row < 0)
            {
                sensor_row = 0;
            }
            if (sensor_row >= OPENK4A_BUILTIN_HEIGHT)
            {
                sensor_row = OPENK4A_BUILTIN_HEIGHT - 1;
            }
            for (int f = 0; f < 3; f++)
            {
                model->col_coeffs[(size_t)row * 3 + f] = openk4a_builtin_col_coeffs[(size_t)sensor_row * 3 + f];
            }
        }
        for (int f = 0; f < 3; f++)
        {
            model->row_coeffs[f] = openk4a_builtin_row_coeffs[f] * (float)bm.binning;
        }
    }

    /* theta = p0 in radians: row profile plus column profile, the mean over
     * the 2x2 block for a binned mode, taken on the circle. */
    for (int f = 0; f < 3; f++)
    {
        float *theta = model->theta + (size_t)f * model->pixels;
        const int last = p0[f].col_coeff_count - 1;
        for (int row = 0; row < model->height; row++)
        {
            for (int column = 0; column < model->width; column++)
            {
                double value;
                if (bm.binning == 1)
                {
                    value = (double)openk4a_calblock_row_coeff(&p0[f], row, 0) + (double)openk4a_calblock_col_coeff(&p0[f], column, last);
                }
                else
                {
                    double cx = 0.0;
                    double cy = 0.0;
                    for (int dy = 0; dy < bm.binning; dy++)
                    {
                        for (int dx = 0; dx < bm.binning; dx++)
                        {
                            const double v = (double)openk4a_calblock_row_coeff(&p0[f], row * bm.binning + dy, 0) +
                                             (double)openk4a_calblock_col_coeff(&p0[f], column * bm.binning + dx, last);
                            cx += cos(v);
                            cy += sin(v);
                        }
                    }
                    value = atan2(cy, cx);
                }
                value = fmod(value, 2.0 * M_PI);
                if (value < 0.0)
                {
                    value += 2.0 * M_PI;
                }
                theta[(size_t)row * model->width + column] = (float)value;
            }
        }
    }

    if (!block_radial_to_z(model, calibration, why, why_size))
    {
        return false;
    }
    if (!block_light_source(model, block, size, bm.block_mode, calibration))
    {
        openk4a_log(OPENK4A_LOG_WARNING, "no illuminator position for %s in the block; distances are round-trip halves",
                openk4a_mode_name(model->mode));
    }
    model_build_weight_table(model);

    /* What the oracle (Microsoft's engine on this camera's frames) settled,
     * see docs/calibration-block.md: the engine's own invalidations, the
     * laser temperature correction, a radial scale and the IR scale. */
    model->engine_rules = true;

    /* The phase-to-millimetre constants from the modulation frequencies the
     * P0 records name: with f_k = M_k * f_base (f_base their greatest common
     * divisor, 9 MHz here, M = 22, 21, 6), a turn of frequency k is c / (2 f_k)
     * of range, and the three are combined with weights M_k^2 / sum(M^2), so
     * alpha_k = M_k * c / (2 f_base sum(M^2)); c_m = M and c_md = M / sum(M^2)
     * are the same combination's direction and its normalised form, which
     * the confidence test uses. The de-alias table, T, RScale and ROffset are
     * functions of M as well; they are the compiled-in ones, checked here to
     * be for the same M. */
    {
        unsigned m[3];
        unsigned gcd = p0[0].freq_10khz;
        for (int f = 1; f < 3; f++)
        {
            unsigned a = gcd, b = p0[f].freq_10khz;
            while (b != 0)
            {
                const unsigned t = a % b;
                a = b;
                b = t;
            }
            gcd = a;
        }
        double sum_sq = 0.0;
        for (int f = 0; f < 3; f++)
        {
            m[f] = gcd != 0 ? p0[f].freq_10khz / gcd : 0;
            sum_sq += (double)m[f] * (double)m[f];
        }
        if (gcd == 0 || m[0] != (unsigned)model->c_m[0] || m[1] != (unsigned)model->c_m[1] || m[2] != (unsigned)model->c_m[2])
        {
            snprintf(why, why_size, "the block's modulation frequencies (%u, %u, %u x 10 kHz) are not the %g:%g:%g the de-alias tables are for",
                     p0[0].freq_10khz, p0[1].freq_10khz, p0[2].freq_10khz, model->c_m[0], model->c_m[1], model->c_m[2]);
            return false;
        }
        const double f_base = (double)gcd * 1.0e4;
        for (int f = 0; f < 3; f++)
        {
            model->alpha[f] = (float)((double)m[f] * OPENK4A_ENGINE_LIGHT_SPEED_MM_PER_S / (2.0 * f_base * sum_sq));
            model->c_m[f] = (float)m[f];
            model->c_md[f] = (float)((double)m[f] / sum_sq);
        }
    }
    if (model->mode == K4A_DEPTH_MODE_WFOV_2X2BINNED || model->mode == K4A_DEPTH_MODE_WFOV_UNBINNED)
    {
        model->reflectivity_min_threshold *= OPENK4A_ORACLE_REFLECTIVITY_WFOV_SCALE;
    }
    switch (model->mode)
    {
    case K4A_DEPTH_MODE_NFOV_UNBINNED:
        model->ir_scale = OPENK4A_ORACLE_IR_SCALE_NFOV_UNBINNED;
        model->fitted_constant_mm = OPENK4A_FITTED_RESIDUAL_NFOV_UNBINNED_MM;
        model->fitted = true;
        break;
    case K4A_DEPTH_MODE_NFOV_2X2BINNED:
        model->ir_scale = OPENK4A_ORACLE_IR_SCALE_NFOV_2X2BINNED;
        model->fitted_constant_mm = OPENK4A_FITTED_RESIDUAL_NFOV_2X2BINNED_MM;
        model->fitted = true;
        break;
    case K4A_DEPTH_MODE_WFOV_2X2BINNED:
        model->ir_scale = OPENK4A_ORACLE_IR_SCALE_WFOV_2X2BINNED;
        model->fitted_constant_mm = OPENK4A_FITTED_RESIDUAL_WFOV_2X2BINNED_MM;
        model->fitted = true;
        break;
    case K4A_DEPTH_MODE_WFOV_UNBINNED:
        model->ir_scale = OPENK4A_ORACLE_IR_SCALE_WFOV_UNBINNED;
        model->fitted_constant_mm = OPENK4A_FITTED_RESIDUAL_WFOV_UNBINNED_MM;
        model->fitted = true;
        break;
    default:
        break;
    }

    /* The field of illumination: the record of the grid the mode decodes on
     * (the binned NFOV mode has its own, on its own grid). */
    {
        uint8_t foi_mode = bm.block_mode;
        if (model->mode == K4A_DEPTH_MODE_NFOV_2X2BINNED)
        {
            foi_mode = 1;
        }
        openk4a_calblock_foi_t foi;
        if (openk4a_calblock_find_foi(block, size, foi_mode, &foi) && foi.rows == model->height && foi.cols == model->width)
        {
            model->mask = (uint8_t *)openk4a_alloc_zero(model->pixels);
            if (model->mask != NULL)
            {
                for (int row = 0; row < model->height; row++)
                {
                    int first = 0, last = -1;
                    if (openk4a_calblock_foi_bounds(&foi, row, &first, &last))
                    {
                        for (int column = first; column <= last && column < model->width; column++)
                        {
                            model->mask[(size_t)row * model->width + column] = 1;
                        }
                    }
                }
            }
        }
        else
        {
            openk4a_log(OPENK4A_LOG_INFO, "no field-of-illumination mask for %s in the block; every pixel is lit",
                        openk4a_mode_name(model->mode));
        }
    }

    /* The laser (global) temperature correction: nine records, one per tap.
     * They are the laser's, not the mode's: measured on a warm-up series
     * against the engine (docs/calibration-block.md, "Warm-up series"), the
     * WFOV modes drift by -0.35 mm per degree when decoded with their own
     * records and not at all with the native NFOV mode's, so every mode
     * takes the native mode's set (block mode 4; mode 1's is the same model
     * to 0.03 mm per degree), and its own only when that set is missing. */
    model->have_global = false;
    if (have_spatial)
    {
        const uint8_t native_mode = 4;
        const uint8_t sources[2] = { native_mode, bm.block_mode };
        for (int which = 0; which < 2 && !model->have_global; which++)
        {
            bool all = true;
            for (int f = 0; f < 3 && all; f++)
            {
                for (int tap = 0; tap < 3 && all; tap++)
                {
                    openk4a_calblock_global_temp_t gt;
                    all = openk4a_calblock_find_global_temp(block, size, sources[which], (uint8_t)(f * 3 + tap + 1), &gt) &&
                          gt.freq_index == f;
                    if (all)
                    {
                        memcpy(model->global_coeff[f][tap], gt.phase_coeff, sizeof(gt.phase_coeff));
                    }
                }
            }
            if (all)
            {
                model->have_global = true;
                model->global_source_mode = sources[which];
            }
        }
        if (model->have_global)
        {
            model->global_tcal = spatial[0].base_cal_temperature[0];
        }
    }

    openk4a_log(OPENK4A_LOG_INFO, "calibration block: serial %s, config %s, %u records, P0 for %s read, temperature model %s%s%s",
                info.serial, info.config_version, info.records_found, openk4a_mode_name(model->mode),
                have_spatial ? "the device's (base temperature given)" : "the recorded camera's",
                model->have_global ? ", laser correction" : "", model->mask != NULL ? ", illumination mask" : "");
    return true;
}

openk4a_depth_model_t *openk4a_depth_model_open(k4a_depth_mode_t mode,
                                        const uint8_t *calibration_block,
                                        size_t calibration_block_size,
                                        const openk4a_calibration_t *calibration,
                                        char *where,
                                        size_t where_size)
{
    openk4a_depth_model_t *model = NULL;

    if (calibration_block != NULL && calibration_block_size > 0)
    {
        const openk4a_mode_t *mode_info = openk4a_mode_of(mode);
        model = mode_info != NULL ? model_alloc(mode, mode_info->width, mode_info->height) : NULL;
        if (model != NULL)
        {
            if (!model_arrays(model))
            {
                openk4a_depth_model_free(model);
                model = NULL;
            }
            else
            {
                char why[128] = "";
                if (!block_expand(model, calibration_block, calibration_block_size, calibration, why, sizeof(why)))
                {
                    openk4a_log(OPENK4A_LOG_INFO, "the calibration block has no usable tables for %s: %s",
                            openk4a_mode_name(mode), why);
                    openk4a_depth_model_free(model);
                    model = NULL;
                }
                else
                {
                    model->source = OPENK4A_MODEL_FROM_BLOCK;
                    snprintf(model->where, sizeof(model->where), "the device's own calibration");
                }
            }
        }
    }

    if (model == NULL)
    {
        char path[512];
        if (model_file_find(mode, path, sizeof(path)))
        {
            model = model_from_file(mode, path);
        }
    }

    if (model == NULL)
    {
        model = model_from_builtin(mode);
    }

    if (model == NULL)
    {
        return NULL;
    }

    model_build_rotation(model, model_factor_for(model, 0.0f));
    if (where != NULL)
    {
        snprintf(where, where_size, "%s", model->where);
    }
    return model;
}

/*=============================================================================
  The pass
=============================================================================*/

/* atan2, near enough: the angle is needed as a fraction of a turn, and a
 * degree-9 minimax polynomial for atan on [-1, 1] with the quadrant handled
 * by hand is good to about 1e-7 of a turn - a micron at the longest
 * frequency. The library call is 1.1 million calls a frame and was the
 * second-largest cost in the pass. */
static float atan2_turns(float y, float x)
{
    if (x == 0.0f && y == 0.0f)
    {
        return 0.0f;
    }
    const float ax = fabsf(x);
    const float ay = fabsf(y);
    const float larger = ax > ay ? ax : ay;
    const float smaller = ax > ay ? ay : ax;
    const float ratio = smaller / larger; /* 0..1 */
    const float ratio2 = ratio * ratio;

    /* atan(r), |r| <= 1, a six-term odd minimax polynomial: Horner in r^2
     * from the highest term down, then one multiply by r. Good to about a
     * millionth of a radian, which is a quarter of a micron at the longest
     * frequency - and the engine itself uses five terms rather than the
     * library call. */
    float angle = -0.01172120f;
    angle = angle * ratio2 + 0.05265332f;
    angle = angle * ratio2 + (-0.11643287f);
    angle = angle * ratio2 + 0.19354346f;
    angle = angle * ratio2 + (-0.33262347f);
    angle = angle * ratio2 + 0.99997726f;
    angle *= ratio;
    angle *= 0.15915494309189533577f; /* radians to turns: 1 / 2 pi */

    if (ay > ax)
    {
        angle = 0.25f - angle;
    }
    if (x < 0.0f)
    {
        angle = 0.5f - angle;
    }
    if (y < 0.0f)
    {
        angle = -angle;
    }
    float turns = angle;
    if (turns < 0.0f)
    {
        turns += 1.0f;
    }
    return turns;
}

/* Round to nearest, ties to even, which is what the engine's own round does. */
static float round_half_even(float value)
{
    const float floor_value = floorf(value);
    const float fraction = value - floor_value;
    if (fraction > 0.5f)
    {
        return floor_value + 1.0f;
    }
    if (fraction < 0.5f)
    {
        return floor_value;
    }
    return fmodf(floor_value, 2.0f) == 0.0f ? floor_value : floor_value + 1.0f;
}

/*=============================================================================
  The reference pass.

  This is the pass exactly as it was first written: one pixel at a time, the
  companding through openk4a_frame_value, the neighbourhood filter walking the
  interleaved projection, and the IR decoded by a separate sweep over the
  frame's taps. It is kept, rather than deleted, because a pass rewritten for
  speed needs something to be held to that is not itself rewritten: the fast
  pass below is compared against this one pixel by pixel, and the two agree
  exactly on the fixtures.
=============================================================================*/

/* The frame carries the temperature its own phase correction depends on, so
 * the correction is rebuilt when that has moved far enough to show. */
static void depth_track_temperature(openk4a_depth_model_t *model, const uint8_t *raw, size_t size)
{
    openk4a_frame_info_t frame;
    if (!openk4a_frame_info(raw, size, &frame))
    {
        return;
    }
    /* The footer's reading moves by half a degree between neighbouring
     * frames, which is the sensor's own reporting rather than the sensor
     * warming: following it frame by frame would rebuild the correction
     * almost every frame and cost more than the correction is worth. The
     * temperature that matters is the slow one, so it is smoothed and the
     * rebuild follows that. */
    model->smoothed_temperature = model->have_temperature
                                      ? model->smoothed_temperature +
                                            (frame.sensor_temp_c - model->smoothed_temperature) * 0.0625f
                                      : frame.sensor_temp_c;
    model->have_temperature = true;
    const float factor = model_factor_for(model, model->smoothed_temperature);
    const float moved = factor > model->built_factor ? factor - model->built_factor : model->built_factor - factor;

    /* The global correction follows the laser's temperature the same way. */
    float wanted[3] = { model->global_offset[0], model->global_offset[1], model->global_offset[2] };
    float moved_global = 0.0f;
    if (model->have_global)
    {
        model->smoothed_laser_temperature = model->have_laser
                                                ? model->smoothed_laser_temperature +
                                                      (frame.laser_temp_c[0] - model->smoothed_laser_temperature) * 0.0625f
                                                : frame.laser_temp_c[0];
        model->have_laser = true;
        const double x = (double)model->smoothed_laser_temperature / 100.0;
        const double x0 = (double)model->global_tcal / 100.0;
        for (int f = 0; f < 3; f++)
        {
            /* The frequency's phase follows its FIRST tap's polynomial (the
             * engine's reference channel), not the mean of the three. Measured
             * on a warm-up series against the engine: the mean left a drift of
             * -0.27 mm per degree, the first tap's polynomial predicts the
             * observed change to 0.03 mm at 4.4 degrees (see
             * docs/calibration-block.md, "Warm-up series"). */
            double at = 0.0, at0 = 0.0, px = 1.0, px0 = 1.0;
            for (int k = 0; k < 8; k++)
            {
                at += model->global_coeff[f][0][k] * px;
                at0 += model->global_coeff[f][0][k] * px0;
                px *= x;
                px0 *= x0;
            }
            const double turns = at - at0;
            wanted[f] = (float)(-turns * 2.0 * M_PI);
            const float d = wanted[f] > model->global_offset[f] ? wanted[f] - model->global_offset[f] : model->global_offset[f] - wanted[f];
            moved_global = d > moved_global ? d : moved_global;
        }
    }
    /* A quarter of a millimetre at the longest frequency is worth a rebuild. */
    if (moved > OPENK4A_TEMPERATURE_STEP * model->temperature_slope || moved_global > 2.0e-3f)
    {
        memcpy(model->global_offset, wanted, sizeof(wanted));
        model_build_rotation(model, factor);
    }

    /* The fitted residual follows the same smoothed laser temperature; a
     * frame without the laser model gets the constant alone. One float per
     * frame, in the output's units, so the CPU and Metal passes add the
     * same number. */
    if (model->fitted)
    {
        const double t = model->have_laser ? (double)model->smoothed_laser_temperature : OPENK4A_FITTED_RESIDUAL_T0_C;
        const double dt = t - OPENK4A_FITTED_RESIDUAL_T0_C;
        const double mm = model->fitted_constant_mm + OPENK4A_FITTED_RESIDUAL_K_MM_PER_C2 * dt * dt;
        model->fitted_residual_units = (float)(mm / (65535.0 * (double)model->output_scale));
    }
}

void openk4a_depth_decode_reference(openk4a_depth_model_t *model,
                                const uint8_t *raw,
                                size_t size,
                                uint16_t *depth,
                                openk4a_depth_times_t *times)
{
    if (!openk4a_depth_model_valid(model) || raw == NULL || depth == NULL)
    {
        return;
    }
    const uint64_t decode_start = openk4a_now_fine_nsec();

    depth_track_temperature(model, raw, size);

    const int width = model->width;
    const int height = model->height;
    const size_t pixels = model->pixels;
    const float inv_2pi = model->inv_2pi;
    /* OPENK4A_DEPTH_TIMING=1 says how the frame's time is split, which is the
     * only way to know whether a change helped the part it was meant to. */
    static int timing = -1;
    if (timing < 0)
    {
        const char *setting = getenv("OPENK4A_DEPTH_TIMING");
        timing = setting != NULL && setting[0] == '1' ? 1 : 0;
    }
    const uint64_t projection_start = openk4a_now_fine_nsec();

    /* One vector per frequency per pixel: the unit direction the filter
     * averages, and the amplitude the gates run on. */
    float *vectors = (float *)openk4a_alloc(pixels * 3 * 3 * sizeof(float));
    if (vectors == NULL)
    {
        return;
    }

    /* A group of eight bytes carries five pixels, and all five pixels' taps
     * come from the same set of groups: unpacking per pixel would read and
     * shift the same eight bytes five times over. A mode that bins 2x2 reads
     * four sub-pixels for every output pixel, so that one walks its pixels
     * one at a time. */
    const openk4a_mode_t *mode_info = openk4a_mode_of(model->mode);
    /* A layout this tree has not proved can be swept from outside rather than
     * recompiled: OPENK4A_TAP_STRIDE is the sub-image pixels between taps. */
    openk4a_mode_t override;
    if (mode_info != NULL)
    {
        const char *given = getenv("OPENK4A_TAP_STRIDE");
        if (given != NULL && given[0] != '\0')
        {
            override = *mode_info;
            override.tap_stride = (size_t)atoi(given);
            mode_info = &override;
        }
    }
    const size_t tap_groups = mode_info != NULL && mode_info->tap_stride != 0
                                  ? mode_info->tap_stride / OPENK4A_PIXELS_PER_GROUP
                                  : openk4a_frame_tap_groups(pixels);
    uint32_t taps[OPENK4A_TAP_COUNT][OPENK4A_PIXELS_PER_GROUP];
    const bool groupwise = mode_info != NULL && mode_info->binning == 1;
    const size_t groups = (pixels + OPENK4A_PIXELS_PER_GROUP - 1) / OPENK4A_PIXELS_PER_GROUP;
    for (size_t group = 0; group < (groupwise ? groups : 0); group++)
    {
        for (size_t tap = 0; tap < OPENK4A_TAP_COUNT; tap++)
        {
            openk4a_frame_group(raw, size, group + tap * tap_groups, taps[tap]);
        }
        for (size_t position = 0; position < OPENK4A_PIXELS_PER_GROUP; position++)
        {
            const size_t pixel = group * OPENK4A_PIXELS_PER_GROUP + position;
            if (pixel >= pixels)
            {
                /* A grid that is not a whole number of groups: 1024x1024 is
                 * not, and its last group is short. */
                continue;
            }
            for (int f = 0; f < 3; f++)
            {
                const uint32_t field_a = taps[f * 3][position];
                const uint32_t field_b = taps[f * 3 + 1][position];
                const uint32_t field_c = taps[f * 3 + 2][position];
                const float a = openk4a_frame_value(field_a);
                const float b = openk4a_frame_value(field_b);
                const float c = openk4a_frame_value(field_c);

                const float real = model->inverse_r[f][0] * a + model->inverse_r[f][1] * b +
                                   model->inverse_r[f][2] * c;
                const float imaginary = model->inverse_i[f][0] * a + model->inverse_i[f][1] * b +
                                        model->inverse_i[f][2] * c;

                const float *rotate = model->rotate + ((size_t)f * pixels + pixel) * 2;
                const float x = real * rotate[0] - imaginary * rotate[1];
                const float y = real * rotate[1] + imaginary * rotate[0];
                const float squared = x * x + y * y;
                const float magnitude = sqrtf(squared);

                float *out = vectors + ((size_t)f * pixels + pixel) * 3;
                /* One reciprocal instead of two divisions. */
                const float inverse = magnitude > 0.0f ? 1.0f / magnitude : 0.0f;
                out[0] = x * inverse;
                out[1] = y * inverse;
                out[2] = magnitude;
            }
        }
    }

    /* A mode that bins 2x2 reads four sub-pixels for every output pixel, so
     * its taps come from four places at once and are taken one pixel at a
     * time rather than a group at a time. */
    for (size_t pixel = 0; !groupwise && pixel < pixels; pixel++)
    {
        float values[OPENK4A_TAP_COUNT];
        openk4a_frame_taps(raw, size, mode_info, pixel, values);
        for (int f = 0; f < 3; f++)
        {
            const float a = values[f * 3];
            const float b = values[f * 3 + 1];
            const float c = values[f * 3 + 2];
            const float real = model->inverse_r[f][0] * a + model->inverse_r[f][1] * b + model->inverse_r[f][2] * c;
            const float imaginary =
                model->inverse_i[f][0] * a + model->inverse_i[f][1] * b + model->inverse_i[f][2] * c;
            const float *rotate = model->rotate + ((size_t)f * pixels + pixel) * 2;
            const float x = real * rotate[0] - imaginary * rotate[1];
            const float y = real * rotate[1] + imaginary * rotate[0];
            const float magnitude = sqrtf(x * x + y * y);
            float *out = vectors + ((size_t)f * pixels + pixel) * 3;
            const float inverse = magnitude > 0.0f ? 1.0f / magnitude : 0.0f;
            out[0] = x * inverse;
            out[1] = y * inverse;
            out[2] = magnitude;
        }
    }

    /* The neighbourhood filter. A neighbour counts by how nearly its phase
     * agrees, which is what keeps a depth discontinuity from being averaged
     * across; a pixel too dark to have a phase of its own is averaged without
     * the weighting, which is the engine's own cCenterLowABThreshold. */
    const float centre_dim_threshold = model->center_low_ab_threshold;
    const uint64_t filter_start = openk4a_now_fine_nsec();
    for (int row = 0; row < height; row++)
    {
        for (int column = 0; column < width; column++)
        {
            const size_t pixel = (size_t)row * width + (size_t)column;
            float phase[3];
            float amplitude[3];

            for (int f = 0; f < 3; f++)
            {
                float *const base = vectors + (size_t)f * pixels * 3;
                const float *centre = base + pixel * 3;
                const float magnitude = centre[2];
                float sum_x = 0.0f;
                float sum_y = 0.0f;
                float sum_weight = 0.0f;
                if (magnitude > 0.0f)
                {
                    const float cx = centre[0];
                    const float cy = centre[1];
                    const bool dim = magnitude <= centre_dim_threshold;
                    const int first_row = row > 2 ? row - 2 : 0;
                    const int last_row = row + 2 < height ? row + 2 : height - 1;
                    const int first_column = column > 2 ? column - 2 : 0;
                    const int last_column = column + 2 < width ? column + 2 : width - 1;
                    for (int nb_row = first_row; nb_row <= last_row; nb_row++)
                    {
                        const float *other = base + ((size_t)nb_row * width + (size_t)first_column) * 3;
                        for (int nb_column = first_column; nb_column <= last_column; nb_column++, other += 3)
                        {
                            if (other[2] <= 0.0f)
                            {
                                continue;
                            }
                            const float nx = other[0];
                            const float ny = other[1];
                            float weight;
                            if (dim)
                            {
                                weight = 1.0f;
                            }
                            else
                            {
                                const float cosine = cx * nx + cy * ny;
                                int lookup = (int)((cosine + 1.0f) * model->weight_scale);
                                if (lookup < 0)
                                {
                                    lookup = 0;
                                }
                                else if (lookup >= OPENK4A_WEIGHT_ENTRIES)
                                {
                                    lookup = OPENK4A_WEIGHT_ENTRIES - 1;
                                }
                                weight = model->weight_table[lookup];
                            }
                            sum_x += weight * nx * other[2];
                            sum_y += weight * ny * other[2];
                            sum_weight += weight;
                        }
                    }
                }

                phase[f] = sum_weight > 0.0f ? atan2_turns(sum_y, sum_x) : 0.0f;
                amplitude[f] = sum_weight > 0.0f ? sqrtf(sum_x * sum_x + sum_y * sum_y) / sum_weight : magnitude;
            }

            float coarse[2];
            for (int k = 0; k < 2; k++)
            {
                coarse[k] = model->t[k][0] * phase[0] + model->t[k][1] * phase[1] + model->t[k][2] * phase[2];
            }
            const int index = (int)((round_half_even(coarse[1]) - model->r_offset[1]) * model->r_scale[0] +
                                    (round_half_even(coarse[0]) - model->r_offset[0]));

            bool valid = index >= 0 && index < OPENK4A_DEALIAS_ENTRIES;
            float radial = 0.0f;
            if (valid)
            {
                const float *wraps = model->lut + (size_t)index * 3;
                valid = wraps[0] != model->invalid_lut_entry;

                float de_aliased[3];
                for (int k = 0; k < 3; k++)
                {
                    de_aliased[k] = phase[k] + wraps[k];
                    radial += model->alpha[k] * de_aliased[k];
                }

                float along = 0.0f;
                for (int k = 0; k < 3; k++)
                {
                    along += model->c_m[k] * de_aliased[k];
                }
                float confidence = 0.0f;
                for (int k = 0; k < 3; k++)
                {
                    const float residual = de_aliased[k] - along * model->c_md[k];
                    confidence += residual * residual;
                }

                float lowest = amplitude[0];
                float highest = amplitude[0];
                float amplitude_sum = 0.0f;
                for (int k = 0; k < 3; k++)
                {
                    if (amplitude[k] < lowest)
                    {
                        lowest = amplitude[k];
                    }
                    if (amplitude[k] > highest)
                    {
                        highest = amplitude[k];
                    }
                    amplitude_sum += amplitude[k];
                }
                const float spread = highest > 0.0f ? (highest - lowest) / highest : 1.0f;
                amplitude_sum *= model->ab_multiplier;

                valid = confidence <= model->max_conf_sq && radial >= model->radial_min &&
                        radial <= model->radial_max && spread <= model->ab_ratio_threshold &&
                        lowest > model->ab_min_freq_threshold && amplitude_sum > model->ab_sum_threshold &&
                        amplitude_sum * radial * radial >= model->reflectivity_min_threshold;
            }

            if (!valid)
            {
                depth[pixel] = 0;
                continue;
            }

            float z = radial;
            if (model->ls_half_dot != NULL)
            {
                const float k = 65535.0f * model->output_scale;
                const float p = radial * k;
                const float denominator = p - model->ls_half_dot[pixel];
                if (denominator > 0.0f)
                {
                    z = ((p * p - model->ls_quarter_sq) / denominator) / k;
                }
            }
            z += model->fitted_residual_units;
            if ((model->flags & 1u) != 0)
            {
                z *= (float)model->radial_to_z[pixel] / 65535.0f;
            }
            const float value = z * 65535.0f * model->output_scale;
            depth[pixel] = (uint16_t)(value + 0.5f);
        }
    }

    openk4a_free(vectors);
    const uint64_t decode_end = openk4a_now_fine_nsec();
    if (times != NULL)
    {
        times->projection_nsec = filter_start - projection_start;
        times->filter_nsec = decode_end - filter_start;
        times->total_nsec = decode_end - decode_start;
    }
    if (timing)
    {
        openk4a_log(OPENK4A_LOG_INFO,
                "depth timing: projection %.2f ms, filter %.2f ms, total %.2f ms",
                (double)(filter_start - projection_start) / 1.0e6,
                (double)(decode_end - filter_start) / 1.0e6,
                (double)(decode_end - decode_start) / 1.0e6);
    }
    (void)inv_2pi;
}

/*=============================================================================
  The fast pass.

  The arithmetic is the reference pass's, to the last rounding; what changes
  is what it costs to arrange.

    - the companding is done in the integer domain and never leaves the
      vector unit: the twelve bits are a mantissa shift, which is a variable
      shift, and the reference's openk4a_frame_value call per tap is a call per
      tap;
    - the frame is unpacked once. Every tap plane of the frame is the same
      stream of groups, offset by a whole number of groups, so a group is
      read and unpacked once and its five fields land in all nine planes;
    - what the filter reads is three planes per frequency - the unit vector's
      two components and the amplitude - so a neighbour is three contiguous
      floats and not three strides into an interleaved array. That is what
      lets the filter run several pixels at a time;
    - the nine-tap IR is the sum of the three amplitudes the projection has
      already worked out, so the plane costs an add and a square root rather
      than a second sweep over the frame's taps;
    - the projection and the taps both live in buffers the model owns. A
      frame allocates nothing and faults in no fresh pages.
=============================================================================*/

/* The companded value of a twelve-bit field, signed, as a float: the same
 * numbers openk4a_frame_value returns, in a table of four-byte floats rather
 * than a call that widens to double and back. Two thousand and forty-eight
 * entries is 8 KB, which is small enough to sit in L1 while the pass asks
 * for ten million of them. */
static float openk4a_signed_value[2048];
static bool openk4a_signed_value_ready;

static void signed_value_init(void)
{
    if (openk4a_signed_value_ready)
    {
        return;
    }
    openk4a_code_table_init();
    for (uint32_t field = 0; field < 2048; field++)
    {
        /* openk4a_code_value is the tree's own companding table: the same
         * integer the reference's openk4a_frame_value widens to double. */
        const float magnitude = (float)openk4a_code_value(field & 0x3FF);
        openk4a_signed_value[field] = (field & 0x400) != 0 ? -magnitude : magnitude;
    }
    openk4a_signed_value_ready = true;
}

static inline float signed_value(uint32_t field)
{
    return openk4a_signed_value[field & 0x7FF];
}

/* The eight-bit code of WFOV unbinned frames: bit 7 the sign, the low seven
 * bits a logarithmically companded magnitude. The law was measured against
 * the engine's own output for a recorded frame: a geometric law
 * (25 * (1.08^m - 1)) keeps the ratio of the decoded IR to the engine's flat
 * from dim to bright, where mantissa/exponent laws fall away; on depth it
 * agrees with the engine within 100 mm on about half the pixels both call
 * valid, the rest sitting on other de-aliasing wraps, which the mode's
 * de-aliasing constants (still the NFOV ones) account for rather than the
 * law. A truncated twelve-bit code (openk4a_code_value(m << 4) / 2) scores
 * the same; neither is settled. */
static float openk4a_signed_value8[256];
static bool openk4a_signed_value8_ready;

/* The 8-bit code: bit 7 the sign, bits 4-6 a 3-bit exponent, bits 0-3 a
 * 4-bit mantissa with an implied leading one above exponent zero - the same
 * float the twelve-bit code is, three bits shorter: it is exactly the
 * twelve-bit value of (code << 3) divided by eight. What the byte codes is
 * not the sample but the DIFFERENCE from the pixel above it in the same
 * column (row 0 from zero), which is why one row of bytes looks like noise
 * and the column sums look like the picture. Measured against the camera's
 * own 2x2-binned twelve-bit readout of the same scene: the column sums
 * reproduce it to its own quantisation, slope 1.000. 0x80, a negative zero,
 * is the sensor's saturation code: a zero difference, and the pixel is
 * flagged. See docs/calibration-block.md. */
static float code8_magnitude(uint32_t m)
{
    const uint32_t exponent = (m >> 4) & 7;
    const uint32_t mantissa = m & 15;
    return exponent == 0 ? (float)mantissa : (float)((16u + mantissa) << (exponent - 1));
}

static void signed_value8_init(void)
{
    if (openk4a_signed_value8_ready)
    {
        return;
    }
    for (uint32_t code = 0; code < 256; code++)
    {
        const float magnitude = code8_magnitude(code & 0x7F);
        openk4a_signed_value8[code] = (code & 0x80) != 0 ? -magnitude : magnitude;
    }
    openk4a_signed_value8_ready = true;
}

/* One byte plane into values: the column sums of the coded differences,
 * the saturation code flagged as a negative zero (its difference is zero). */
static void unpack8_plane(const uint8_t *raw, size_t size, size_t first, size_t columns, size_t rows, float *destination)
{
    for (size_t column = 0; column < columns; column++)
    {
        int32_t acc = 0;
        for (size_t row = 0; row < rows; row++)
        {
            const size_t at = first + row * columns + column;
            const uint8_t byte = at < size ? raw[at] : 0;
            acc += (int32_t)openk4a_signed_value8[byte];
            destination[row * columns + column] = byte == 0x80 ? -0.0f : (float)acc;
        }
    }
}

static inline float signed_value8(uint32_t code)
{
    return openk4a_signed_value8[code & 0xFF];
}

/* One tap plane, read on its own rather than as part of the whole unpack.
 * Plane t of the frame's group stream starts at group t * tap_groups and runs
 * for the sub-image's worth of groups, so this is a walk over that span and
 * nothing else. */
bool openk4a_frame_tap_plane(const uint8_t *raw,
                         size_t size,
                         const openk4a_mode_t *mode,
                         size_t tap,
                         float *values,
                         size_t count)
{
    if (raw == NULL || mode == NULL || values == NULL || tap >= OPENK4A_TAP_COUNT || !mode->nine_taps)
    {
        return false;
    }
    signed_value_init();

    const size_t sub_pixels = openk4a_mode_sub_pixels(mode);
    if (mode->code_bits == 8)
    {
        if (count < sub_pixels)
        {
            return false; /* the column sums need the whole plane */
        }
        signed_value8_init();
        const size_t stride = mode->tap_stride != 0 ? mode->tap_stride : sub_pixels + 160;
        const size_t columns = (size_t)mode->width * (size_t)mode->binning;
        unpack8_plane(raw, size, mode->header_bytes + tap * stride, columns, sub_pixels / columns, values);
        return true;
    }
    const size_t tap_groups = mode->tap_stride != 0 ? mode->tap_stride / OPENK4A_PIXELS_PER_GROUP
                                                    : openk4a_frame_tap_groups(sub_pixels);
    const size_t groups = (sub_pixels + OPENK4A_PIXELS_PER_GROUP - 1) / OPENK4A_PIXELS_PER_GROUP;
    const size_t first = tap * tap_groups;
    size_t written = 0;
    uint32_t fields[OPENK4A_PIXELS_PER_GROUP];

    for (size_t group = 0; group < groups && written < count; group++)
    {
        const size_t byte = OPENK4A_FRAME_HEADER_BYTES + (first + group) * OPENK4A_GROUP_BYTES;
        if (byte + OPENK4A_GROUP_BYTES > size)
        {
            break;
        }
        const uint8_t *const bytes = raw + byte;
        const uint32_t lows = (uint32_t)(bytes[5] & 0x0F) | ((uint32_t)(bytes[5] >> 4) << 4) |
                              ((uint32_t)(bytes[6] & 0x0F) << 8) | ((uint32_t)(bytes[6] >> 4) << 12) |
                              ((uint32_t)(bytes[7] & 0x0F) << 16);
        for (size_t i = 0; i < OPENK4A_PIXELS_PER_GROUP; i++)
        {
            fields[i] = ((uint32_t)bytes[i] << 4) | ((lows >> (4 * i)) & 0x0F);
        }
        for (size_t i = 0; i < OPENK4A_PIXELS_PER_GROUP && written < count; i++)
        {
            values[written++] = signed_value(fields[i]);
        }
    }
    while (written < count)
    {
        values[written++] = 0.0f;
    }
    return true;
}

/* The frame's layout, resolved once for the whole pass: which taps sit how
 * far apart, where the frame's own groups end, and whether the taps are read
 * a group at a time or four sub-pixels to a pixel. */
typedef struct
{
    const openk4a_mode_t *mode;
    size_t tap_groups;
    size_t groups;
    bool groupwise;
} openk4a_layout_t;

static openk4a_layout_t depth_layout(const openk4a_depth_model_t *model)
{
    openk4a_layout_t layout;
    layout.mode = openk4a_mode_of(model->mode);
    layout.groupwise = layout.mode != NULL && layout.mode->binning == 1;
    const size_t pixels = model->pixels;
    size_t tap_stride = 0;
    if (layout.mode != NULL)
    {
        tap_stride = layout.mode->tap_stride;
    }
    /* A layout this tree has not proved can be swept from outside rather than
     * recompiled: OPENK4A_TAP_STRIDE is the sub-image pixels between taps. */
    static size_t override_stride = 0;
    static bool override_read;
    if (!override_read)
    {
        override_read = true;
        const char *given = getenv("OPENK4A_TAP_STRIDE");
        override_stride = given != NULL && given[0] != '\0' ? (size_t)atoi(given) : 0;
    }
    if (override_stride != 0)
    {
        tap_stride = override_stride;
    }
    layout.tap_groups = tap_stride != 0 ? tap_stride / OPENK4A_PIXELS_PER_GROUP
                                        : openk4a_frame_tap_groups(model->sub_pixels);
    layout.groups = (pixels + OPENK4A_PIXELS_PER_GROUP - 1) / OPENK4A_PIXELS_PER_GROUP;
    return layout;
}

/*-----------------------------------------------------------------------------
  Unpacking the frame into its tap planes.

  Plane t of the tap set is the frame's own group stream, offset by t whole
  group strides; so one walk over the frame fills every plane. A group of
  eight bytes carries five fields and lands in all nine planes at once, which
  is why the frame is read once and not nine times.

  A mode that bins 2x2 reads four sub-pixels to a pixel, so its planes are
  built over the sub-image and summed down into the output grid as they are
  written. The four are quartered and added as floats: every companded value
  is a whole number below 2^17, so a quarter of it is exact in single
  precision, and the four quarters of a 2x2 block add exactly.
---------------------------------------------------------------------------*/

static void depth_unpack(openk4a_depth_model_t *model, const uint8_t *raw, size_t size, const openk4a_layout_t *layout)
{
    const size_t sub_pixels = model->sub_pixels;
    if (layout->mode != NULL && layout->mode->code_bits == 8)
    {
        /* One byte a pixel, plane after plane, each a column sum. */
        signed_value8_init();
        const size_t stride = layout->mode->tap_stride != 0 ? layout->mode->tap_stride : sub_pixels + 160;
        const size_t columns = (size_t)layout->mode->width * (size_t)layout->mode->binning;
        for (size_t t = 0; t < OPENK4A_TAP_COUNT; t++)
        {
            unpack8_plane(raw, size, layout->mode->header_bytes + t * stride, columns, sub_pixels / columns,
                          model->tap_sub + t * sub_pixels);
        }
        return;
    }
    const size_t tap_groups = layout->tap_groups;
    const size_t groups = (sub_pixels + OPENK4A_PIXELS_PER_GROUP - 1) / OPENK4A_PIXELS_PER_GROUP;
    /* The frame holds every tap plane one after another, so its last group
     * is the last group of the last plane, not of the first. */
    const size_t frame_groups = groups + (size_t)(OPENK4A_TAP_COUNT - 1) * tap_groups;
    float *const tap = model->tap_sub;
    uint32_t fields[OPENK4A_PIXELS_PER_GROUP];
    signed_value_init();

    /* Every plane is the same group stream, one tap stride apart. Plane t
     * holds the frame's groups [t * stride, t * stride + groups), so a frame
     * group belongs to at most a couple of planes and usually to exactly one:
     * the planes whose window it has reached and not yet left. Tracking those
     * two edges as counters keeps the inner loop to the groups that are
     * actually written, which over a whole frame is one write of five values
     * per frame group and not nine tests of which to skip. */
    size_t lowest = 0;
    size_t highest = 0;
    size_t opens_at = tap_groups;              /* when the next plane opens */
    size_t expires_at = groups;                /* when the first plane is full */

    for (size_t group = 0; group < frame_groups; group++)
    {
        if (group == opens_at && highest + 1 < OPENK4A_TAP_COUNT)
        {
            highest++;
            opens_at += tap_groups;
        }
        while (lowest <= highest && group == expires_at)
        {
            lowest++;
            expires_at += tap_groups;
        }
        /* The same five-to-eight unpacking openk4a_frame_group does, here rather
         * than there: it is six hundred and sixty thousand calls a frame and
         * it is eight loads and five shifts long, which is a call this pass
         * cannot afford. */
        const size_t byte = OPENK4A_FRAME_HEADER_BYTES + group * OPENK4A_GROUP_BYTES;
        if (byte + OPENK4A_GROUP_BYTES <= size)
        {
            const uint8_t *const bytes = raw + byte;
            const uint32_t lows = (uint32_t)(bytes[5] & 0x0F) | ((uint32_t)(bytes[5] >> 4) << 4) |
                                  ((uint32_t)(bytes[6] & 0x0F) << 8) | ((uint32_t)(bytes[6] >> 4) << 12) |
                                  ((uint32_t)(bytes[7] & 0x0F) << 16);
            for (size_t i = 0; i < OPENK4A_PIXELS_PER_GROUP; i++)
            {
                fields[i] = ((uint32_t)bytes[i] << 4) | ((lows >> (4 * i)) & 0x0F);
            }
        }
        else
        {
            for (size_t i = 0; i < OPENK4A_PIXELS_PER_GROUP; i++)
            {
                fields[i] = 0;
            }
        }
        for (size_t tap_index = lowest; tap_index <= highest; tap_index++)
        {
            const size_t within = group - tap_index * tap_groups;
            const size_t base = within * OPENK4A_PIXELS_PER_GROUP;
            if (base >= sub_pixels)
            {
                continue;
            }
            float *const destination = tap + tap_index * sub_pixels + base;
            size_t write = sub_pixels - base;
            if (write > OPENK4A_PIXELS_PER_GROUP)
            {
                write = OPENK4A_PIXELS_PER_GROUP;
            }
            for (size_t i = 0; i < write; i++)
            {
                destination[i] = signed_value(fields[i]);
            }
        }
    }
}

/* A mode that bins 2x2 reads four sub-pixels to a pixel: the planes above
 * are over the sub-image, and this sums each 2x2 block of them down. The
 * four quarters are exact in single precision - a companded value is a whole
 * number below 2^17, so a quarter of it is exact, and so is the sum of four
 * of them - which is why this agrees with the reference's double division to
 * the last count. */
/* A tap that unpacked from the sensor's saturation code (0x400: the sign bit
 * with no magnitude) is a negative zero, which nothing else produces. */
static inline bool tap_is_saturated(float tap)
{
    uint32_t bits;
    memcpy(&bits, &tap, sizeof(bits));
    return bits == 0x80000000u;
}

static void depth_bin(const openk4a_depth_model_t *model)
{
    const size_t pixels = model->pixels;
    const size_t sub_pixels = model->sub_pixels;
    const size_t sub_width = (size_t)model->width * (size_t)model->binning;
    const int binning = model->binning;
    const float quarter = 1.0f / (float)(binning * binning);

    for (int tap_index = 0; tap_index < OPENK4A_TAP_COUNT; tap_index++)
    {
        const float *const source = model->tap_sub + (size_t)tap_index * sub_pixels;
        float *const destination = model->tap + (size_t)tap_index * pixels;
        for (int row = 0; row < model->height; row++)
        {
            const float *line = source + (size_t)row * (size_t)binning * sub_width;
            float *out = destination + (size_t)row * (size_t)model->width;
            uint8_t *const saturated = model->saturated + (size_t)row * (size_t)model->width;
            for (int column = 0; column < model->width; column++)
            {
                float total = 0.0f;
                if (tap_index == 0)
                {
                    saturated[column] = 0;
                }
                for (int dy = 0; dy < binning; dy++)
                {
                    for (int dx = 0; dx < binning; dx++)
                    {
                        const float sub = line[(size_t)dy * sub_width + (size_t)column * (size_t)binning + (size_t)dx];
                        if (tap_is_saturated(sub))
                        {
                            saturated[column] = 1;
                        }
                        total += sub;
                    }
                }
                out[column] = total * quarter;
            }
        }
    }
}

/*-----------------------------------------------------------------------------
  The projection, and the IR with it.

  Per frequency: the three taps through the inverse of the sensor's phase
  matrix, the phase correction as a rotation, and the amplitude. The
  amplitude is both the weight the filter carries and the number the IR is
  the sum of, which is why the plane comes out of this pass and not a second
  one.
---------------------------------------------------------------------------*/

static void depth_project(openk4a_depth_model_t *model, uint16_t *ir)
{
    const size_t pixels = model->pixels;
    const float *const tap = model->tap;
    float *const proj = model->proj;

    for (int f = 0; f < 3; f++)
    {
        const float *const ta = tap + (size_t)(f * 3 + 0) * pixels;
        const float *const tb = tap + (size_t)(f * 3 + 1) * pixels;
        const float *const tc = tap + (size_t)(f * 3 + 2) * pixels;
        float *const qx = proj + (size_t)(f * 3 + 0) * pixels;
        float *const qy = proj + (size_t)(f * 3 + 1) * pixels;
        float *const qm = proj + (size_t)(f * 3 + 2) * pixels;
        const float r0 = model->inverse_r[f][0];
        const float r1 = model->inverse_r[f][1];
        const float r2 = model->inverse_r[f][2];
        const float i0 = model->inverse_i[f][0];
        const float i1 = model->inverse_i[f][1];
        const float i2 = model->inverse_i[f][2];
        const float *const rotate = model->rotate + (size_t)f * pixels * 2;
        size_t pixel = 0;

#if OPENK4A_HAVE_AVX2
        /* The three planes are contiguous, so this is three loads and the
         * same arithmetic the scalar loop below does. */
        {
            const __m256 vr0 = _mm256_set1_ps(r0);
            const __m256 vr1 = _mm256_set1_ps(r1);
            const __m256 vr2 = _mm256_set1_ps(r2);
            const __m256 vi0 = _mm256_set1_ps(i0);
            const __m256 vi1 = _mm256_set1_ps(i1);
            const __m256 vi2 = _mm256_set1_ps(i2);
            const __m256 zero = _mm256_setzero_ps();
            const __m256 two_thirds = _mm256_set1_ps(2.0f / 3.0f);
            /* The rotation is stored cos then sin per pixel, so eight pixels
             * are sixteen floats with the two halves interleaved; the two
             * shuffles take them apart and the permute puts them back in
             * pixel order, which is what the stores below want. */
            const __m256i deinterleave = _mm256_setr_epi32(0, 1, 4, 5, 2, 3, 6, 7);
            for (; pixel + 8 <= pixels; pixel += 8)
            {
                const __m256 a = _mm256_loadu_ps(ta + pixel);
                const __m256 b = _mm256_loadu_ps(tb + pixel);
                const __m256 c = _mm256_loadu_ps(tc + pixel);
                /* The three terms of each row of the inverse matrix, fused
                 * the way the scalar expression contracts: the first product
                 * plain, the other two accumulated into it. */
                const __m256 real = _mm256_fmadd_ps(vr2, c, _mm256_fmadd_ps(vr0, a, _mm256_mul_ps(vr1, b)));
                const __m256 imaginary = _mm256_fmadd_ps(vi2, c, _mm256_fmadd_ps(vi0, a, _mm256_mul_ps(vi1, b)));
                const __m256 rotation_low = _mm256_loadu_ps(rotate + pixel * 2);
                const __m256 rotation_high = _mm256_loadu_ps(rotate + pixel * 2 + 8);
                const __m256 cosine =
                    _mm256_permutevar8x32_ps(_mm256_shuffle_ps(rotation_low, rotation_high, 0x88), deinterleave);
                const __m256 sine =
                    _mm256_permutevar8x32_ps(_mm256_shuffle_ps(rotation_low, rotation_high, 0xDD), deinterleave);
                const __m256 x = _mm256_fmsub_ps(real, cosine, _mm256_mul_ps(imaginary, sine));
                const __m256 y = _mm256_fmadd_ps(real, sine, _mm256_mul_ps(cosine, imaginary));
                const __m256 magnitude =
                    _mm256_sqrt_ps(_mm256_fmadd_ps(x, x, _mm256_mul_ps(y, y)));
                const __m256 positive = _mm256_cmp_ps(magnitude, zero, _CMP_GT_OQ);
                const __m256 inverse = _mm256_and_ps(_mm256_div_ps(_mm256_set1_ps(1.0f), magnitude), positive);
                _mm256_storeu_ps(qx + pixel, _mm256_mul_ps(x, inverse));
                _mm256_storeu_ps(qy + pixel, _mm256_mul_ps(y, inverse));
                _mm256_storeu_ps(qm + pixel, magnitude);

                if (model->binning == 1)
                {
                    for (size_t lane = 0; lane < 8; lane++)
                    {
                        if (f == 0)
                        {
                            model->saturated[pixel + lane] = 0;
                        }
                        if (tap_is_saturated(ta[pixel + lane]) || tap_is_saturated(tb[pixel + lane]) || tap_is_saturated(tc[pixel + lane]))
                        {
                            model->saturated[pixel + lane] = 1;
                        }
                    }
                }
                if (ir != NULL)
                {
                    __m256 squared = _mm256_mul_ps(a, a);
                    squared = _mm256_fmadd_ps(b, b, squared);
                    squared = _mm256_fmadd_ps(c, c, squared);
                    squared = _mm256_fnmadd_ps(a, b, squared);
                    squared = _mm256_fnmadd_ps(a, c, squared);
                    squared = _mm256_fnmadd_ps(b, c, squared);
                    const __m256 amplitude =
                        _mm256_mul_ps(two_thirds, _mm256_sqrt_ps(_mm256_max_ps(squared, zero)));
                    _mm256_storeu_ps(model->ir_amp + pixel,
                                     _mm256_add_ps(_mm256_loadu_ps(model->ir_amp + pixel), amplitude));
                }
            }
        }
#endif

        for (; pixel < pixels; pixel++)
        {
            const float a = ta[pixel];
            const float b = tb[pixel];
            const float c = tc[pixel];
            if (model->binning == 1)
            {
                /* The sensor's saturation code unpacks to a negative zero. */
                if (f == 0)
                {
                    model->saturated[pixel] = 0;
                }
                if (tap_is_saturated(a) || tap_is_saturated(b) || tap_is_saturated(c))
                {
                    model->saturated[pixel] = 1;
                }
            }

            const float real = r0 * a + r1 * b + r2 * c;
            const float imaginary = i0 * a + i1 * b + i2 * c;
            const float cosine = rotate[pixel * 2];
            const float sine = rotate[pixel * 2 + 1];
            /* The rotation is what the phase correction is, and the
             * amplitude is the length of the rotated vector: the reference
             * takes the square root after the rotation, and the pass is held
             * to it to the last bit, so this does too rather than using the
             * rotation's invariance to save two multiplies. */
            const float x = real * cosine - imaginary * sine;
            const float y = real * sine + imaginary * cosine;
            const float magnitude = sqrtf(x * x + y * y);
            const float inverse = magnitude > 0.0f ? 1.0f / magnitude : 0.0f;
            qx[pixel] = x * inverse;
            qy[pixel] = y * inverse;
            qm[pixel] = magnitude;

            if (ir != NULL)
            {
                /* The engine's three-phase demodulation of one group, as a
                 * quadratic form: (4/9)(a^2 + b^2 + c^2 - ab - ac - bc). */
                float squared = a * a + b * b + c * c - a * b - a * c - b * c;
                if (squared < 0.0f)
                {
                    squared = 0.0f;
                }
                model->ir_amp[pixel] += (2.0f / 3.0f) * sqrtf(squared);
            }
        }
    }

    if (ir != NULL)
    {
        for (size_t pixel = 0; pixel < pixels; pixel++)
        {
            const float value = model->ir_amp[pixel] * model->ir_scale;
            if (value >= 32767.0f)
            {
                ir[pixel] = 32767;
            }
            else
            {
                ir[pixel] = (uint16_t)(value + 0.5f);
            }
        }
    }
}

/*-----------------------------------------------------------------------------
  The neighbourhood filter.

  A neighbour counts by how nearly its phase agrees with the centre's, which
  is what keeps a depth discontinuity from being averaged across; a pixel too
  dark to have a phase of its own is averaged without the weighting, which is
  the engine's own cCenterLowABThreshold. The arithmetic below is the
  reference's, read off the three planes the projection wrote.
---------------------------------------------------------------------------*/

/* From the three phases and the three amplitudes to the millimetres: the
 * de-alias table, the radial distance, the confidence and the gates. Shared
 * by both paths, so there is one copy of it and not two that can drift. */
static inline void depth_conclude(const openk4a_depth_model_t *model,
                                  size_t pixel,
                                  const float phase[3],
                                  const float amplitude[3],
                                  uint16_t *depth)
{
    if (model->engine_rules && (model->saturated[pixel] != 0 || (model->mask != NULL && model->mask[pixel] == 0)))
    {
        depth[pixel] = 0;
        return;
    }
    float coarse[2];
    for (int k = 0; k < 2; k++)
    {
        coarse[k] = model->t[k][0] * phase[0] + model->t[k][1] * phase[1] + model->t[k][2] * phase[2];
    }
    const int index = (int)((round_half_even(coarse[1]) - model->r_offset[1]) * model->r_scale[0] +
                            (round_half_even(coarse[0]) - model->r_offset[0]));

    bool valid = index >= 0 && index < OPENK4A_DEALIAS_ENTRIES;
    float radial = 0.0f;
    if (valid)
    {
        const float *wraps = model->lut + (size_t)index * 3;
        valid = wraps[0] != model->invalid_lut_entry;

        float de_aliased[3];
        for (int k = 0; k < 3; k++)
        {
            de_aliased[k] = phase[k] + wraps[k];
            radial += model->alpha[k] * de_aliased[k];
        }

        float along = 0.0f;
        for (int k = 0; k < 3; k++)
        {
            along += model->c_m[k] * de_aliased[k];
        }
        float confidence = 0.0f;
        for (int k = 0; k < 3; k++)
        {
            const float residual = de_aliased[k] - along * model->c_md[k];
            confidence += residual * residual;
        }

        float lowest = amplitude[0];
        float highest = amplitude[0];
        float amplitude_sum = 0.0f;
        for (int k = 0; k < 3; k++)
        {
            if (amplitude[k] < lowest)
            {
                lowest = amplitude[k];
            }
            if (amplitude[k] > highest)
            {
                highest = amplitude[k];
            }
            amplitude_sum += amplitude[k];
        }
        const float spread = highest > 0.0f ? (highest - lowest) / highest : 1.0f;
        amplitude_sum *= model->ab_multiplier;

        valid = confidence <= model->max_conf_sq && radial >= model->radial_min &&
                radial <= model->radial_max && spread <= model->ab_ratio_threshold &&
                lowest > model->ab_min_freq_threshold && amplitude_sum > model->ab_sum_threshold &&
                amplitude_sum * radial * radial >= model->reflectivity_min_threshold;
    }

    if (!valid)
    {
        depth[pixel] = 0;
        return;
    }

    float z = radial;
    if (model->ls_half_dot != NULL)
    {
        /* Round trip to the sensor's own distance, see the model's comment. */
        const float k = 65535.0f * model->output_scale;
        const float p = radial * k;
        const float denominator = p - model->ls_half_dot[pixel];
        if (denominator > 0.0f)
        {
            z = ((p * p - model->ls_quarter_sq) / denominator) / k;
        }
    }
    z += model->fitted_residual_units;
    if ((model->flags & 1u) != 0)
    {
        z *= (float)model->radial_to_z[pixel] / 65535.0f;
    }
    depth[pixel] = (uint16_t)(z * 65535.0f * model->output_scale + 0.5f);
}

/* One pixel, one neighbour at a time. */
static void depth_pixel(const openk4a_depth_model_t *model, int row, int column, uint16_t *depth)
{
    const int width = model->width;
    const int height = model->height;
    const size_t pixels = model->pixels;
    const float *const proj = model->proj;
    const size_t pixel = (size_t)row * (size_t)width + (size_t)column;
    const int first_row = row > 2 ? row - 2 : 0;
    const int last_row = row + 2 < height ? row + 2 : height - 1;
    const int first_column = column > 2 ? column - 2 : 0;
    const int last_column = column + 2 < width ? column + 2 : width - 1;
    float phase[3];
    float amplitude[3];

    for (int f = 0; f < 3; f++)
    {
        const float *const plane_x = proj + (size_t)(f * 3 + 0) * pixels;
        const float *const plane_y = proj + (size_t)(f * 3 + 1) * pixels;
        const float *const plane_m = proj + (size_t)(f * 3 + 2) * pixels;
        const float magnitude = plane_m[pixel];
        float sum_x = 0.0f;
        float sum_y = 0.0f;
        float sum_weight = 0.0f;
        if (magnitude > 0.0f)
        {
            const float cx = plane_x[pixel];
            const float cy = plane_y[pixel];
            const bool dim = magnitude <= model->center_low_ab_threshold;
            for (int nb_row = first_row; nb_row <= last_row; nb_row++)
            {
                const size_t row_base = (size_t)nb_row * (size_t)width + (size_t)first_column;
                for (int nb_column = first_column; nb_column <= last_column; nb_column++)
                {
                    const size_t other = row_base + (size_t)(nb_column - first_column);
                    const float other_magnitude = plane_m[other];
                    if (other_magnitude <= 0.0f)
                    {
                        continue;
                    }
                    float weight;
                    if (dim)
                    {
                        weight = 1.0f;
                    }
                    else
                    {
                        const float cosine = cx * plane_x[other] + cy * plane_y[other];
                        int lookup = (int)((cosine + 1.0f) * model->weight_scale);
                        if (lookup < 0)
                        {
                            lookup = 0;
                        }
                        else if (lookup >= OPENK4A_WEIGHT_ENTRIES)
                        {
                            lookup = OPENK4A_WEIGHT_ENTRIES - 1;
                        }
                        weight = model->weight_table[lookup];
                    }
                    /* The neighbour's vector, not its direction: the
                     * engine averages the complex values, so a bright
                     * neighbour counts for more and noise with no common
                     * phase cancels. The amplitude is the length of that
                     * mean, which is what makes its gates reject incoherent
                     * pixels (measured against the engine: see
                     * docs/calibration-block.md). */
                    sum_x += weight * plane_x[other] * other_magnitude;
                    sum_y += weight * plane_y[other] * other_magnitude;
                    sum_weight += weight;
                }
            }
        }

        phase[f] = sum_weight > 0.0f ? atan2_turns(sum_y, sum_x) : 0.0f;
        amplitude[f] = sum_weight > 0.0f ? sqrtf(sum_x * sum_x + sum_y * sum_y) / sum_weight : magnitude;
    }
    depth_conclude(model, pixel, phase, amplitude, depth);
}

#if OPENK4A_HAVE_AVX2

/* Eight pixels of one row, whose whole 5x5 window is inside the row. Each of
 * the three components of a neighbour is eight consecutive floats in its own
 * plane, so a neighbour is three plain loads; the weight is a gather from the
 * model's 4 KB table, which is the one place the vector unit has to reach for
 * an index of its own. */
static void depth_block(const openk4a_depth_model_t *model, int row, int column, uint16_t *depth)
{
    const int width = model->width;
    const int height = model->height;
    const size_t pixels = model->pixels;
    const float *const proj = model->proj;
    const __m256 zero = _mm256_setzero_ps();
    const __m256 one = _mm256_set1_ps(1.0f);
    const __m256 scale = _mm256_set1_ps(model->weight_scale);
    const __m256 highest_entry = _mm256_set1_ps((float)(OPENK4A_WEIGHT_ENTRIES - 1));
    const __m256 dim_threshold = _mm256_set1_ps(model->center_low_ab_threshold);

    float sum_x[3][8];
    float sum_y[3][8];
    float sum_weight[3][8];
    float centre_magnitude[3][8];

    for (int f = 0; f < 3; f++)
    {
        const float *const plane_x = proj + (size_t)(f * 3 + 0) * pixels;
        const float *const plane_y = proj + (size_t)(f * 3 + 1) * pixels;
        const float *const plane_m = proj + (size_t)(f * 3 + 2) * pixels;
        const size_t base = (size_t)row * (size_t)width + (size_t)column;
        const __m256 cx = _mm256_loadu_ps(plane_x + base);
        const __m256 cy = _mm256_loadu_ps(plane_y + base);
        const __m256 cm = _mm256_loadu_ps(plane_m + base);
        const __m256 active = _mm256_cmp_ps(cm, zero, _CMP_GT_OQ);
        const __m256 dim = _mm256_cmp_ps(cm, dim_threshold, _CMP_LE_OQ);

        __m256 acc_x = zero;
        __m256 acc_y = zero;
        __m256 acc_w = zero;
        for (int dr = -2; dr <= 2; dr++)
        {
            const int other_row = row + dr;
            if (other_row < 0 || other_row >= height)
            {
                continue;
            }
            const float *const nx_row = plane_x + (size_t)other_row * (size_t)width;
            const float *const ny_row = plane_y + (size_t)other_row * (size_t)width;
            const float *const nm_row = plane_m + (size_t)other_row * (size_t)width;
            for (int dc = -2; dc <= 2; dc++)
            {
                const int at = column + dc;
                const __m256 nx = _mm256_loadu_ps(nx_row + at);
                const __m256 ny = _mm256_loadu_ps(ny_row + at);
                const __m256 nm = _mm256_loadu_ps(nm_row + at);
                const __m256 present = _mm256_cmp_ps(nm, zero, _CMP_GT_OQ);
                const __m256 cosine = _mm256_fmadd_ps(cx, nx, _mm256_mul_ps(cy, ny));
                __m256 where = _mm256_mul_ps(_mm256_add_ps(cosine, one), scale);
                where = _mm256_max_ps(where, zero);
                where = _mm256_min_ps(where, highest_entry);
                __m256 weight = _mm256_i32gather_ps(model->weight_table, _mm256_cvttps_epi32(where), 4);
                weight = _mm256_blendv_ps(weight, one, dim);
                weight = _mm256_and_ps(weight, present);
                /* The scalar pass's order and roundings, no fused step. */
                acc_x = _mm256_add_ps(acc_x, _mm256_mul_ps(_mm256_mul_ps(weight, nx), nm));
                acc_y = _mm256_add_ps(acc_y, _mm256_mul_ps(_mm256_mul_ps(weight, ny), nm));
                acc_w = _mm256_add_ps(acc_w, weight);
            }
        }

        /* A lane whose centre has no phase of its own is the reference's
         * "the neighbourhood is not walked": its sums stay at zero. */
        _mm256_storeu_ps(sum_x[f], _mm256_and_ps(acc_x, active));
        _mm256_storeu_ps(sum_y[f], _mm256_and_ps(acc_y, active));
        _mm256_storeu_ps(sum_weight[f], _mm256_and_ps(acc_w, active));
        _mm256_storeu_ps(centre_magnitude[f], cm);
    }

    for (int lane = 0; lane < 8; lane++)
    {
        float phase[3];
        float amplitude[3];
        for (int f = 0; f < 3; f++)
        {
            if (sum_weight[f][lane] > 0.0f)
            {
                phase[f] = atan2_turns(sum_y[f][lane], sum_x[f][lane]);
                amplitude[f] = sqrtf(sum_x[f][lane] * sum_x[f][lane] + sum_y[f][lane] * sum_y[f][lane]) / sum_weight[f][lane];
            }
            else
            {
                phase[f] = 0.0f;
                amplitude[f] = centre_magnitude[f][lane];
            }
        }
        depth_conclude(model,
                       (size_t)row * (size_t)width + (size_t)column + (size_t)lane,
                       phase,
                       amplitude,
                       depth);
    }
}

#endif /* OPENK4A_HAVE_AVX2 */

static void depth_filter_row(const openk4a_depth_model_t *model, int row, uint16_t *depth)
{
    const int width = model->width;
    /* The block path needs the whole window inside the row; the columns it
     * cannot cover are the two at each edge and whatever is left over. */
    const int block_first = 2;
    const int block_last = width - 2;
    int column = 0;
    for (; column < block_first && column < width; column++)
    {
        depth_pixel(model, row, column, depth);
    }
#if OPENK4A_HAVE_AVX2
    for (; column + 8 <= block_last; column += 8)
    {
        depth_block(model, row, column, depth);
    }
#else
    (void)block_last;
#endif
    for (; column < width; column++)
    {
        depth_pixel(model, row, column, depth);
    }
}

/* Every row of the filter reads the projection and writes its own row of the
 * depth plane, so the rows run on every core there is. The answer is the
 * same as one core's, pixel for pixel: nothing is shared but read-only
 * planes. Rows are handed out in strips so the scheduling cost is paid a few
 * hundred times a frame rather than once a row. */
#define OPENK4A_FILTER_STRIP 8

static void depth_filter(const openk4a_depth_model_t *model, uint16_t *depth)
{
    const int height = model->height;
    const size_t strips = ((size_t)height + OPENK4A_FILTER_STRIP - 1) / OPENK4A_FILTER_STRIP;
#if defined(__APPLE__)
    dispatch_apply(strips, DISPATCH_APPLY_AUTO, ^(size_t strip) {
        const int first = (int)strip * OPENK4A_FILTER_STRIP;
        const int last = first + OPENK4A_FILTER_STRIP < height ? first + OPENK4A_FILTER_STRIP : height;
        for (int row = first; row < last; row++)
        {
            depth_filter_row(model, row, depth);
        }
    });
#else
    for (size_t strip = 0; strip < strips; strip++)
    {
        const int first = (int)strip * OPENK4A_FILTER_STRIP;
        const int last = first + OPENK4A_FILTER_STRIP < height ? first + OPENK4A_FILTER_STRIP : height;
        for (int row = first; row < last; row++)
        {
            depth_filter_row(model, row, depth);
        }
    }
#endif
}

/*-----------------------------------------------------------------------------
  The entry points.
---------------------------------------------------------------------------*/

void openk4a_depth_decode_full(openk4a_depth_model_t *model,
                           const uint8_t *raw,
                           size_t size,
                           uint16_t *depth,
                           uint16_t *ir,
                           openk4a_depth_times_t *times)
{
    if (!openk4a_depth_model_valid(model) || raw == NULL || (depth == NULL && ir == NULL))
    {
        return;
    }
    const uint64_t start = openk4a_now_fine_nsec();
    depth_track_temperature(model, raw, size);

    const openk4a_layout_t layout = depth_layout(model);
    if (layout.mode == NULL)
    {
        /* A mode the table does not carry: the reference is the only thing
         * that knows how to read it. */
        openk4a_depth_decode_reference(model, raw, size, depth, times);
        return;
    }

    if (ir != NULL)
    {
        memset(model->ir_amp, 0, model->pixels * sizeof(float));
    }

    const uint64_t prepare_start = openk4a_now_fine_nsec();
    depth_unpack(model, raw, size, &layout);
    if (model->binning != 1)
    {
        depth_bin(model);
    }
    const uint64_t project_start = openk4a_now_fine_nsec();
    depth_project(model, ir);
    const uint64_t filter_start = openk4a_now_fine_nsec();
    /* For measuring against the engine: the projection planes (3 frequencies
     * x unit vector x, y, magnitude) and the rotation table, raw. */
    const char *dump = getenv("OPENK4A_DUMP_PROJ");
    if (dump != NULL)
    {
        FILE *f = fopen(dump, "wb");
        if (f != NULL)
        {
            fwrite(model->proj, sizeof(float), model->pixels * 9, f);
            fwrite(model->rotate, sizeof(float), model->pixels * 6, f);
            fwrite(model->theta, sizeof(float), model->pixels * 3, f);
            fwrite(model->radial_to_z, sizeof(uint16_t), model->pixels, f);
            fclose(f);
        }
    }
    if (depth != NULL)
    {
        depth_filter(model, depth);
    }
    const uint64_t end = openk4a_now_fine_nsec();

    if (times != NULL)
    {
        times->projection_nsec = filter_start - prepare_start;
        times->filter_nsec = end - filter_start;
        times->total_nsec = end - start;
    }
    (void)project_start;
}

void openk4a_depth_decode(openk4a_depth_model_t *model, const uint8_t *raw, size_t size, uint16_t *depth)
{
    openk4a_depth_decode_full(model, raw, size, depth, NULL, NULL);
}

void openk4a_depth_decode_timed(openk4a_depth_model_t *model,
                            const uint8_t *raw,
                            size_t size,
                            uint16_t *depth,
                            openk4a_depth_times_t *times)
{
    openk4a_depth_decode_full(model, raw, size, depth, NULL, times);
}

/*=============================================================================
  The model's tables, for a decoder outside this file (the Metal one).
=============================================================================*/

bool openk4a_depth_model_temperature(const openk4a_depth_model_t *model, float *slope, float *intercept, float row_coeffs[3], bool *from_block)
{
    if (!openk4a_depth_model_valid(model))
    {
        return false;
    }
    if (slope != NULL) *slope = model->temperature_slope;
    if (intercept != NULL) *intercept = model->temperature_intercept;
    if (row_coeffs != NULL) memcpy(row_coeffs, model->row_coeffs, sizeof(model->row_coeffs));
    if (from_block != NULL) *from_block = model->block_spatial_temperature;
    return true;
}

float openk4a_depth_model_row_term(const openk4a_depth_model_t *model, int row, int frequency)
{
    if (!openk4a_depth_model_valid(model) || row < 0 || row >= model->height || frequency < 0 || frequency > 2)
    {
        return 0.0f;
    }
    return model->col_coeffs[(size_t)row * 3 + frequency];
}

bool openk4a_depth_model_tables(openk4a_depth_model_t *model, openk4a_depth_model_tables_t *out)
{
    if (!openk4a_depth_model_valid(model) || out == NULL)
    {
        return false;
    }
    const openk4a_layout_t layout = depth_layout(model);
    if (layout.mode == NULL)
    {
        return false;
    }
    memset(out, 0, sizeof(*out));
    out->mode = model->mode;
    out->width = model->width;
    out->height = model->height;
    out->pixels = model->pixels;
    out->sub_pixels = model->sub_pixels;
    out->binning = model->binning;
    out->flags = model->flags;
    out->tap_groups = layout.tap_groups;
    out->groups = (model->sub_pixels + OPENK4A_PIXELS_PER_GROUP - 1) / OPENK4A_PIXELS_PER_GROUP;
    out->code_bits = layout.mode->code_bits;
    out->header_bytes = layout.mode->header_bytes;
    out->tap_stride = layout.mode->tap_stride != 0 ? layout.mode->tap_stride : model->sub_pixels + 160;
    memcpy(out->alpha, model->alpha, sizeof(out->alpha));
    memcpy(out->c_m, model->c_m, sizeof(out->c_m));
    memcpy(out->c_md, model->c_md, sizeof(out->c_md));
    memcpy(out->t, model->t, sizeof(out->t));
    memcpy(out->inverse_r, model->inverse_r, sizeof(out->inverse_r));
    memcpy(out->inverse_i, model->inverse_i, sizeof(out->inverse_i));
    memcpy(out->r_offset, model->r_offset, sizeof(out->r_offset));
    memcpy(out->r_scale, model->r_scale, sizeof(out->r_scale));
    out->ab_multiplier = model->ab_multiplier;
    out->ab_min_freq_threshold = model->ab_min_freq_threshold;
    out->ab_sum_threshold = model->ab_sum_threshold;
    out->ab_ratio_threshold = model->ab_ratio_threshold;
    out->max_conf_sq = model->max_conf_sq;
    out->reflectivity_min_threshold = model->reflectivity_min_threshold;
    out->radial_min = model->radial_min;
    out->radial_max = model->radial_max;
    out->invalid_lut_entry = model->invalid_lut_entry;
    out->center_low_ab_threshold = model->center_low_ab_threshold;
    out->output_scale = model->output_scale;
    out->weight_scale = model->weight_scale;
    out->ir_scale = model->ir_scale;
    out->engine_rules = model->engine_rules;
    out->mask = model->mask;
    out->saturated = model->saturated;
    out->lut = model->lut;
    out->lut_entries = OPENK4A_DEALIAS_ENTRIES;
    out->rotate = model->rotate;
    out->radial_to_z = model->radial_to_z;
    out->weight_table = model->weight_table;
    out->weight_entries = OPENK4A_WEIGHT_ENTRIES;
    out->ls_half_dot = model->ls_half_dot;
    out->ls_quarter_sq = model->ls_quarter_sq;
    out->fitted_residual_units = model->fitted_residual_units;
    out->rotation_generation = model->rotation_generation;
    return true;
}

void openk4a_depth_model_prepare(openk4a_depth_model_t *model, const uint8_t *raw, size_t size)
{
    if (openk4a_depth_model_valid(model) && raw != NULL)
    {
        depth_track_temperature(model, raw, size);
    }
}

float openk4a_depth_signed_value(uint32_t field)
{
    signed_value_init();
    return signed_value(field);
}

float openk4a_depth_signed_value8(uint32_t code)
{
    signed_value8_init();
    return signed_value8(code);
}

void openk4a_depth_model_set_radial_output(openk4a_depth_model_t *model, bool radial)
{
    if (model != NULL)
    {
        if (radial)
        {
            model->flags &= ~1u;
        }
        else
        {
            model->flags |= 1u;
        }
    }
}
