/* The official depth engine, run as a black box on a recorded raw frame.
 *
 * Loads Microsoft's libdepthengine through the plugin interface its own SDK
 * uses (k4aplugin.h, MIT), feeds it the device's calibration block and one
 * raw frame, and writes the depth and IR planes it returns. This is the
 * ground truth the open decoder is measured against. Linux only (the engine
 * needs an OpenGL 4.4 context, which Mesa's llvmpipe provides under Xvfb). */
#include "k4aplugin.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *read_file(const char *path, size_t *size)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); *size = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc(*size);
    if (fread(data, 1, *size, f) != *size) { perror(path); exit(2); }
    fclose(f);
    return data;
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: oracle <mode: nfov_unbinned|nfov_2x2binned|wfov_2x2binned|wfov_unbinned> <calibration_block.bin> <frame.raw> <out-prefix> [camera_calibration.bin]\n"
                        "  ORACLE_OUTPUT=radial writes radial depth instead of Z; the optional blob is a k4a_calibration_camera_t\n");
        return 2;
    }
    const char *output_env = getenv("ORACLE_OUTPUT");
    const k4a_depth_engine_output_type_t output_type = output_env != NULL && strcmp(output_env, "radial") == 0
                                                           ? K4A_DEPTH_ENGINE_OUTPUT_TYPE_RADIAL_DEPTH
                                                           : K4A_DEPTH_ENGINE_OUTPUT_TYPE_Z_DEPTH;
    void *camera_calibration = NULL;
    if (argc > 5) {
        size_t cal_blob_size = 0;
        camera_calibration = read_file(argv[5], &cal_blob_size);
        fprintf(stderr, "camera calibration blob: %zu bytes\n", cal_blob_size);
    }
    k4a_depth_engine_mode_t mode;
    k4a_depth_engine_input_type_t input = K4A_DEPTH_ENGINE_INPUT_TYPE_12BIT_COMPRESSED;
    if (!strcmp(argv[1], "nfov_unbinned")) mode = K4A_DEPTH_ENGINE_MODE_LT_NATIVE;
    else if (!strcmp(argv[1], "nfov_2x2binned")) mode = K4A_DEPTH_ENGINE_MODE_LT_SW_BINNING;
    else if (!strcmp(argv[1], "wfov_2x2binned")) mode = K4A_DEPTH_ENGINE_MODE_QUARTER_MEGA_PIXEL;
    else if (!strcmp(argv[1], "wfov_unbinned")) { mode = K4A_DEPTH_ENGINE_MODE_MEGA_PIXEL; input = K4A_DEPTH_ENGINE_INPUT_TYPE_8BIT_COMPRESSED; }
    else { fprintf(stderr, "unknown mode %s\n", argv[1]); return 2; }

    void *lib = dlopen("libdepthengine.so.2.0", RTLD_NOW);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 3; }
    k4a_register_plugin_fn reg = (k4a_register_plugin_fn)dlsym(lib, K4A_PLUGIN_EXPORTED_FUNCTION);
    if (!reg) { fprintf(stderr, "no %s\n", K4A_PLUGIN_EXPORTED_FUNCTION); return 3; }
    k4a_plugin_t plugin;
    memset(&plugin, 0, sizeof(plugin));
    if (!reg(&plugin)) { fprintf(stderr, "register failed\n"); return 3; }
    fprintf(stderr, "depth engine %u.%u.%u\n", plugin.version.major, plugin.version.minor, plugin.version.patch);

    size_t cal_size, raw_size;
    uint8_t *cal = read_file(argv[2], &cal_size);
    uint8_t *raw = read_file(argv[3], &raw_size);

    k4a_depth_engine_context_t *engine = NULL;
    k4a_depth_engine_result_code_t rc = plugin.depth_engine_create_and_initialize(&engine, cal_size, cal, mode, input, camera_calibration, NULL, NULL);
    if (rc != K4A_DEPTH_ENGINE_RESULT_SUCCEEDED) { fprintf(stderr, "create failed: %d\n", rc); return 4; }
    size_t out_size = plugin.depth_engine_get_output_frame_size(engine);
    fprintf(stderr, "output frame size %zu bytes\n", out_size);
    uint8_t *out = calloc(1, out_size);

    k4a_depth_engine_output_frame_info_t info;
    memset(&info, 0, sizeof(info));
    rc = plugin.depth_engine_process_frame(engine, raw, raw_size, output_type, out, out_size, &info, NULL);
    if (rc != K4A_DEPTH_ENGINE_RESULT_SUCCEEDED) { fprintf(stderr, "process failed: %d\n", rc); return 5; }
    fprintf(stderr, "output %ux%u, sensor %.2f C, laser %.2f/%.2f C, exposure ticks %llu\n", info.output_width, info.output_height,
            info.sensor_temp, info.laser_temp[0], info.laser_temp[1], (unsigned long long)info.center_of_exposure_in_ticks);

    /* The SDK reads depth first, IR after it, each width*height*2 bytes. */
    const size_t plane = (size_t)info.output_width * info.output_height * 2;
    char path[1024];
    snprintf(path, sizeof path, "%s.depth.u16", argv[4]);
    FILE *f = fopen(path, "wb"); fwrite(out, 1, plane, f); fclose(f);
    snprintf(path, sizeof path, "%s.ir.u16", argv[4]);
    f = fopen(path, "wb"); fwrite(out + plane, 1, out_size >= 2 * plane ? plane : 0, f); fclose(f);
    snprintf(path, sizeof path, "%s.info.txt", argv[4]);
    f = fopen(path, "w"); fprintf(f, "%u %u %.3f %.3f %.3f %llu\n", info.output_width, info.output_height, info.sensor_temp, info.laser_temp[0], info.laser_temp[1], (unsigned long long)info.center_of_exposure_in_ticks); fclose(f);

    plugin.depth_engine_destroy(&engine);
    return 0;
}
