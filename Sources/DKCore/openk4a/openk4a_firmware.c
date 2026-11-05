/*=============================================================================
  Firmware: the package format and the update sequence, as the SDK's
  firmware.c and its updater tool do it (Microsoft, MIT).

  A package is one file: a header naming the versions it carries, the
  component images, an authentication block, and a CRC-32 over everything
  before the last four bytes. The update is one bulk write of the whole
  package to the depth MCU (DEV_CMD_DOWNLOAD_FIRMWARE), then polling
  DEV_CMD_GET_FIRMWARE_UPDATE_STATUS no faster than twice a second until each
  component reports finished, then a reset (the colour MCU's, falling back
  to the depth MCU's), after which the device re-enumerates and its versions
  are read back.
=============================================================================*/

#include "openk4a.h"

#include <time.h>
#include <unistd.h>

#define OPENK4A_FIRMWARE_MAX_DEPTH_CONFIG 5
#define OPENK4A_FIRMWARE_UPDATE_TIMEOUT_MS (10 * 60 * 1000)
#define OPENK4A_DEPTH_CMD_RESET 0x00000000u
#define OPENK4A_DEPTH_CMD_DOWNLOAD_FIRMWARE 0x00000202u
#define OPENK4A_DEPTH_CMD_GET_FIRMWARE_UPDATE_STATUS 0x00000203u

#pragma pack(push, 1)
typedef struct
{
    uint16_t version_major;
    uint16_t version_minor;
    uint8_t reserved[8];
} openk4a_package_depth_config_t;

typedef struct
{
    uint8_t signature_type;
    uint8_t build_configuration;
    uint32_t auth_block_start;
    uint8_t depth_version_major;
    uint8_t depth_version_minor;
    uint16_t depth_version_build;
    uint8_t reserved_1[8];
    uint8_t rgb_version_major;
    uint8_t rgb_version_minor;
    uint16_t rgb_version_build;
    uint8_t reserved_2[8];
    uint8_t audio_version_major;
    uint8_t audio_version_minor;
    uint16_t audio_version_build;
    uint8_t reserved_3[8];
    uint16_t number_depth_config;
    openk4a_package_depth_config_t depth_config[OPENK4A_FIRMWARE_MAX_DEPTH_CONFIG];
} openk4a_package_header_t;

typedef struct
{
    uint8_t last_package; /* 1: the whole package in one write */
    uint8_t package_size; /* legacy, unchecked by the firmware */
} openk4a_package_info_t;

typedef struct
{
    uint16_t depth_status;
    uint16_t rgb_status;
    uint16_t audio_status;
    uint16_t depth_configure_status;
} openk4a_update_status_wire_t;
#pragma pack(pop)

static uint32_t crc32_of(const uint8_t *data, size_t length)
{
    uint32_t table[256];
    for (uint32_t i = 0; i < 256; i++)
    {
        uint32_t element = i;
        for (int j = 0; j < 8; j++)
        {
            element = (element & 1) ? ((element >> 1) ^ 0xEDB88320u) : (element >> 1);
        }
        table[i] = element;
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t n = 0; n < length; n++)
    {
        crc = ((crc >> 8) & 0x00FFFFFFu) ^ table[(crc ^ data[n]) & 0xFF];
    }
    return crc;
}

bool openk4a_firmware_parse_package(const uint8_t *buffer, size_t size, openk4a_firmware_package_t *out)
{
    if (buffer == NULL || out == NULL)
    {
        return false;
    }
    memset(out, 0, sizeof(*out));
    if (size < sizeof(openk4a_package_header_t) + sizeof(uint32_t))
    {
        snprintf(out->why, sizeof(out->why), "too small for a package header (%zu bytes)", size);
        return false;
    }
    openk4a_package_header_t header;
    memcpy(&header, buffer, sizeof(header));
    out->package_valid = true;
    out->signature_type = (k4a_firmware_signature_t)header.signature_type;
    out->build_config = (k4a_firmware_build_t)header.build_configuration;

    const size_t crc_offset = size - sizeof(uint32_t);
    uint32_t stored = 0;
    memcpy(&stored, buffer + crc_offset, sizeof(stored));
    const uint32_t computed = crc32_of(buffer, crc_offset);
    out->crc_valid = stored == computed;
    if (!out->crc_valid)
    {
        snprintf(out->why, sizeof(out->why), "CRC mismatch: stored 0x%08X, computed 0x%08X", stored, computed);
        out->package_valid = false;
    }

    out->rgb.major = header.rgb_version_major;
    out->rgb.minor = header.rgb_version_minor;
    out->rgb.iteration = header.rgb_version_build;
    out->depth.major = header.depth_version_major;
    out->depth.minor = header.depth_version_minor;
    out->depth.iteration = header.depth_version_build;
    out->audio.major = header.audio_version_major;
    out->audio.minor = header.audio_version_minor;
    out->audio.iteration = header.audio_version_build;

    if (header.number_depth_config > OPENK4A_FIRMWARE_MAX_DEPTH_CONFIG)
    {
        snprintf(out->why, sizeof(out->why), "too many depth configurations (%u)", (unsigned)header.number_depth_config);
        out->package_valid = false;
    }
    else
    {
        out->depth_config_count = (uint8_t)header.number_depth_config;
    }
    for (int i = 0; i < OPENK4A_FIRMWARE_MAX_DEPTH_CONFIG; i++)
    {
        out->depth_config[i].major = header.depth_config[i].version_major;
        out->depth_config[i].minor = header.depth_config[i].version_minor;
        out->depth_config[i].iteration = 0;
    }

    if ((size_t)header.auth_block_start + 6 > size)
    {
        snprintf(out->why, sizeof(out->why), "authentication block not found");
        out->package_valid = false;
    }
    else
    {
        uint32_t certificate_start = 0;
        uint16_t certificate_length = 0;
        memcpy(&certificate_start, buffer + header.auth_block_start, sizeof(certificate_start));
        memcpy(&certificate_length, buffer + header.auth_block_start + sizeof(certificate_start), sizeof(certificate_length));
        if (certificate_length < 1 || (size_t)certificate_start + certificate_length > size)
        {
            snprintf(out->why, sizeof(out->why), "authentication block invalid");
            out->package_valid = false;
        }
        else
        {
            out->certificate_type = (k4a_firmware_signature_t)buffer[certificate_start];
        }
    }
    return out->package_valid;
}

static void status_of(uint16_t wire, openk4a_firmware_component_status_t *status)
{
    status->version_check = (openk4a_firmware_operation_t)((wire >> 0) & 0x3);
    status->authentication_check = (openk4a_firmware_operation_t)((wire >> 2) & 0x3);
    status->image_transfer = (openk4a_firmware_operation_t)((wire >> 4) & 0x3);
    status->flash_erase = (openk4a_firmware_operation_t)((wire >> 6) & 0x3);
    status->flash_write = (openk4a_firmware_operation_t)((wire >> 8) & 0x3);
    status->overall = (openk4a_firmware_operation_t)((wire >> 14) & 0x3);
}

bool openk4a_firmware_status(k4a_device_t device_handle, openk4a_firmware_status_t *status)
{
    openk4a_device_t *device = (openk4a_device_t *)device_handle;
    if (device == NULL || status == NULL)
    {
        return false;
    }
    openk4a_update_status_wire_t wire;
    memset(&wire, 0, sizeof(wire));
    size_t read = 0;
    if (!openk4a_usb_read_command(&device->usb_depth, OPENK4A_DEPTH_CMD_GET_FIRMWARE_UPDATE_STATUS, &wire, sizeof(wire), &read) ||
        read < sizeof(wire))
    {
        return false;
    }
    status_of(wire.depth_status, &status->depth);
    status_of(wire.rgb_status, &status->rgb);
    status_of(wire.audio_status, &status->audio);
    status_of(wire.depth_configure_status, &status->depth_config);
    return true;
}

bool openk4a_firmware_download(k4a_device_t device_handle, const uint8_t *package, size_t size)
{
    openk4a_device_t *device = (openk4a_device_t *)device_handle;
    if (device == NULL || package == NULL || size == 0)
    {
        return false;
    }
    openk4a_package_info_t info;
    info.last_package = 1;
    info.package_size = (uint8_t)size; /* what the SDK sends; the firmware ignores it */
    openk4a_log(OPENK4A_LOG_INFO, "sending %zu bytes of firmware to the depth MCU", size);
    uint32_t status = 0;
    const bool sent = openk4a_usb_command(&device->usb_depth, OPENK4A_DEPTH_CMD_DOWNLOAD_FIRMWARE, &info, sizeof(info), package,
                                          size, NULL, 0, NULL, &status);
    if (!sent)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the depth MCU refused the firmware (status %08X)", status);
    }
    return sent;
}

static uint64_t now_ms(void)
{
    return openk4a_now_ms();
}

static bool component_done(const openk4a_firmware_component_status_t *status)
{
    return status->overall > OPENK4A_FIRMWARE_OPERATION_INPROGRESS;
}

bool openk4a_firmware_wait_update(k4a_device_t device_handle, openk4a_firmware_status_t *status, uint32_t timeout_ms)
{
    const uint64_t started = now_ms();
    for (;;)
    {
        if (!openk4a_firmware_status(device_handle, status))
        {
            return false;
        }
        if (component_done(&status->audio) && component_done(&status->depth_config) && component_done(&status->depth) &&
            component_done(&status->rgb))
        {
            return true;
        }
        if (now_ms() - started > (timeout_ms != 0 ? timeout_ms : OPENK4A_FIRMWARE_UPDATE_TIMEOUT_MS))
        {
            openk4a_log(OPENK4A_LOG_ERROR, "timed out waiting for the firmware update to complete");
            return false;
        }
        usleep(500000); /* the spec says no faster than 2 Hz */
    }
}

bool openk4a_firmware_reset(k4a_device_t device_handle)
{
    openk4a_device_t *device = (openk4a_device_t *)device_handle;
    if (device == NULL)
    {
        return false;
    }
    /* The colour MCU's reset restarts the whole device; the depth MCU's is
     * the fallback. */
    if (device->color_mcu_open && openk4a_usb_write_command(&device->usb_color, OPENK4A_COLOR_CMD_RESET, NULL, 0))
    {
        return true;
    }
    return openk4a_usb_write_command(&device->usb_depth, OPENK4A_DEPTH_CMD_RESET, NULL, 0);
}

openk4a_firmware_operation_t openk4a_firmware_component_result(const openk4a_firmware_component_status_t *status)
{
    /* The updater's own reading of a component: still going, failed at a
     * named step, or done. */
    if (status->overall == OPENK4A_FIRMWARE_OPERATION_INPROGRESS)
    {
        return OPENK4A_FIRMWARE_OPERATION_INPROGRESS;
    }
    if (status->overall == OPENK4A_FIRMWARE_OPERATION_SUCCEEDED)
    {
        return OPENK4A_FIRMWARE_OPERATION_SUCCEEDED;
    }
    return OPENK4A_FIRMWARE_OPERATION_FAILED;
}

const char *openk4a_firmware_operation_name(openk4a_firmware_operation_t operation)
{
    switch (operation)
    {
    case OPENK4A_FIRMWARE_OPERATION_INPROGRESS:
        return "in progress";
    case OPENK4A_FIRMWARE_OPERATION_FAILED:
        return "failed";
    case OPENK4A_FIRMWARE_OPERATION_SUCCEEDED:
        return "succeeded";
    default:
        return "unknown";
    }
}
