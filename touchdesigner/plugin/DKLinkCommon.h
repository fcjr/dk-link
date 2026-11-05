/* Shared helpers for the DK Link TOP and CHOP: parameter menus that
 * match the Windows operators, and the mapping onto the library's enums. */
#pragma once
#include "dklinktd.h"
#include <cstring>

namespace kaz {

/* Windows DK Link TOP menu orders, with "off" added at the end where the
 * library allows a sensor to be left off. */
static const char *kDepthNames[] = { "narrowunbinned", "widebinned", "narrowbinned", "wideunbinned", "passiveir", "off" };
static const char *kDepthLabels[] = { "Narrow FOV - Unbinned (640x576)", "Wide FOV - 2x2 Binned (512x512)",
                                      "Narrow FOV - 2x2 Binned (320x288)", "Wide FOV - Unbinned (1024x1024)",
                                      "Passive IR (1024x1024)", "Off" };
static const ktd_depth_mode kDepthModes[] = { KTD_DEPTH_NFOV_UNBINNED, KTD_DEPTH_WFOV_2X2BINNED, KTD_DEPTH_NFOV_2X2BINNED,
                                              KTD_DEPTH_WFOV_UNBINNED, KTD_DEPTH_PASSIVE_IR, KTD_DEPTH_OFF };

static const char *kColorNames[] = { "1280x720", "1920x1080", "2560x1440", "2048x1536", "3840x2160", "4096x3072", "off" };
static const char *kColorLabels[] = { "1280 x 720 (16:9)", "1920 x 1080 (16:9)", "2560 x 1440 (16:9)",
                                      "2048 x 1536 (4:3)", "3840 x 2160 (16:9)", "4096 x 3072 (4:3)", "Off" };
static const ktd_color_resolution kColorModes[] = { KTD_COLOR_720P, KTD_COLOR_1080P, KTD_COLOR_1440P, KTD_COLOR_1536P,
                                                    KTD_COLOR_2160P, KTD_COLOR_3072P, KTD_COLOR_OFF };

static const char *kFpsNames[] = { "fps5", "fps15", "fps30" };
static const char *kFpsLabels[] = { "5", "15", "30" };
static const ktd_fps kFpsModes[] = { KTD_FPS_5, KTD_FPS_15, KTD_FPS_30 };

/* The Windows Image menu, in its order. Entries the library cannot provide
 * are kept so patches load, and the node warns instead. */
static const char *kImageNames[] = { "color", "colorremap", "depth", "depthremap", "ir", "irremap",
                                     "playerindex", "playerindexremap", "pointcloud", "pointcloudremap" };
static const char *kImageLabels[] = { "Color", "Color aligned to Depth", "Depth", "Depth aligned to Color", "IR",
                                      "IR aligned to Color", "Player Index", "Player Index aligned to Color",
                                      "Point Cloud", "Point Cloud aligned to Color" };
static const int kImageKinds[] = { KTD_IMAGE_COLOR, KTD_IMAGE_COLOR_IN_DEPTH, KTD_IMAGE_DEPTH, KTD_IMAGE_DEPTH_IN_COLOR,
                                   KTD_IMAGE_IR, -1, KTD_IMAGE_PLAYER_INDEX, -1, KTD_IMAGE_POINT_CLOUD,
                                   KTD_IMAGE_COLOR_POINT_CLOUD };

template <typename T, size_t N> constexpr int count(const T (&)[N]) { return (int)N; }

inline bool configEquals(const ktd_config &a, const ktd_config &b)
{
    return a.depth_mode == b.depth_mode && a.color_resolution == b.color_resolution && a.fps == b.fps &&
           a.body_tracking == b.body_tracking && a.device_index == b.device_index;
}

} // namespace kaz
