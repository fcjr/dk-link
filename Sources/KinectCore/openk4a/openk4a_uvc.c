/*=============================================================================
  UVC controls over libusb.

  macOS binds its own driver to the colour camera's video interfaces, which
  is what makes AVFoundation the way to read frames - but the camera's
  controls (exposure, white balance, gain and the rest) are class requests on
  the device's default pipe, and the default pipe is not something an
  interface driver owns. So they are sent here as plain control transfers on
  the same handle the colour MCU is open on, which is the same USB device.

  The unit ids come from the VideoControl interface's class-specific
  descriptors: an input terminal of type camera (the CT, exposure and the
  like) and a processing unit (the PU, everything else).
=============================================================================*/

#include "openk4a.h"

#define UVC_CC_VIDEO 0x0E
#define UVC_SC_VIDEOCONTROL 0x01
#define UVC_CS_INTERFACE 0x24
#define UVC_VC_INPUT_TERMINAL 0x02
#define UVC_VC_PROCESSING_UNIT 0x05
#define UVC_ITT_CAMERA 0x0201

#define UVC_SET_CUR 0x01
#define UVC_REQUEST_TIMEOUT_MS 1000

bool openk4a_uvc_scan(openk4a_uvc_t *uvc, openk4a_usb_t *usb)
{
    memset(uvc, 0, sizeof(*uvc));
    uvc->usb = usb;
    if (usb == NULL || usb->handle == NULL)
    {
        return false;
    }
    libusb_device *device = libusb_get_device(usb->handle);
    struct libusb_config_descriptor *config = NULL;
    if (libusb_get_active_config_descriptor(device, &config) != 0 || config == NULL)
    {
        return false;
    }
    bool found = false;
    for (int i = 0; i < config->bNumInterfaces && !found; i++)
    {
        for (int a = 0; a < config->interface[i].num_altsetting && !found; a++)
        {
            const struct libusb_interface_descriptor *alt = &config->interface[i].altsetting[a];
            if (alt->bInterfaceClass != UVC_CC_VIDEO || alt->bInterfaceSubClass != UVC_SC_VIDEOCONTROL)
            {
                continue;
            }
            uvc->vc_interface = alt->bInterfaceNumber;
            const unsigned char *extra = alt->extra;
            int left = alt->extra_length;
            while (left >= 3)
            {
                const int length = extra[0];
                if (length < 3 || length > left)
                {
                    break;
                }
                if (extra[1] == UVC_CS_INTERFACE)
                {
                    if (extra[2] == UVC_VC_INPUT_TERMINAL && length >= 8)
                    {
                        const uint16_t type = (uint16_t)(extra[4] | (extra[5] << 8));
                        if (type == UVC_ITT_CAMERA && uvc->camera_terminal_id == 0)
                        {
                            uvc->camera_terminal_id = extra[3];
                        }
                    }
                    else if (extra[2] == UVC_VC_PROCESSING_UNIT && length >= 4 && uvc->processing_unit_id == 0)
                    {
                        uvc->processing_unit_id = extra[3];
                    }
                }
                extra += length;
                left -= length;
            }
            found = uvc->camera_terminal_id != 0 || uvc->processing_unit_id != 0;
        }
    }
    libusb_free_config_descriptor(config);
    uvc->scanned = found;
    if (!found)
    {
        openk4a_log(OPENK4A_LOG_WARNING, "no UVC VideoControl units found on the colour device; camera controls are off");
    }
    return found;
}

bool openk4a_uvc_get(openk4a_uvc_t *uvc, uint8_t request, uint8_t unit, uint8_t selector, void *data, uint16_t size)
{
    if (uvc == NULL || !uvc->scanned || uvc->usb == NULL || uvc->usb->handle == NULL)
    {
        return false;
    }
    const int rc = libusb_control_transfer(uvc->usb->handle,
                                           LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE,
                                           request,
                                           (uint16_t)(selector << 8),
                                           (uint16_t)((unit << 8) | uvc->vc_interface),
                                           (unsigned char *)data,
                                           size,
                                           UVC_REQUEST_TIMEOUT_MS);
    if (rc < 0)
    {
        openk4a_log(OPENK4A_LOG_TRACE, "uvc get %02X unit %u selector %u failed: %s", request, unit, selector, libusb_error_name(rc));
        return false;
    }
    return rc == (int)size;
}

bool openk4a_uvc_set(openk4a_uvc_t *uvc, uint8_t unit, uint8_t selector, const void *data, uint16_t size)
{
    if (uvc == NULL || !uvc->scanned || uvc->usb == NULL || uvc->usb->handle == NULL)
    {
        return false;
    }
    const int rc = libusb_control_transfer(uvc->usb->handle,
                                           LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE,
                                           UVC_SET_CUR,
                                           (uint16_t)(selector << 8),
                                           (uint16_t)((unit << 8) | uvc->vc_interface),
                                           (unsigned char *)data,
                                           size,
                                           UVC_REQUEST_TIMEOUT_MS);
    if (rc < 0)
    {
        openk4a_log(OPENK4A_LOG_WARNING, "uvc set unit %u selector %u failed: %s", unit, selector, libusb_error_name(rc));
        return false;
    }
    return rc == (int)size;
}
