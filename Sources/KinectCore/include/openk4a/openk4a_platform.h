/*=============================================================================
  The macOS side of OpenK4A: libusb for the two command devices and the
  streams, pthreads for the IMU reader, AVFoundation (in openk4a_color_avf.m)
  for the colour camera. Everything Windows-specific that openk4a_win.h once
  named lives here instead.
=============================================================================*/

#ifndef OPENK4A_PLATFORM_H
#define OPENK4A_PLATFORM_H

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <libusb.h>

/* One stream read in flight: a libusb bulk transfer on the stream endpoint
 * whose completion is signalled on a condition variable, so a caller can wait
 * for the frame with a timeout while the next read is already posted. */
typedef struct
{
    struct libusb_transfer *transfer;
    uint8_t *buffer;
    size_t size;
    size_t transferred;
    int status;         /* libusb_transfer_status once complete */
    bool pending;
    bool ready;
    bool inited;
    pthread_mutex_t lock;
    pthread_cond_t done;
} openk4a_io_t;

typedef struct
{
    libusb_device_handle *handle;
    int interface_number;
    uint8_t endpoint_out;
    uint8_t endpoint_in;
    uint8_t endpoint_stream;
    uint32_t transaction_id;
    uint32_t command_timeout_ms;
    uint32_t stream_timeout_ms;
    uint8_t bus;
    uint8_t address;
    char path[64];
    char serial[128];
} openk4a_usb_t;

/* The shared libusb context and the thread that pumps its events. Started on
 * the first open; torn down at exit. */
libusb_context *openk4a_usb_context(void);

/* UVC controls for the colour camera, sent as control transfers to the
 * colour device's default pipe, which macOS leaves reachable even while its
 * own driver owns the video interfaces. Implemented in openk4a_uvc.c. */
typedef struct
{
    openk4a_usb_t *usb;        /* the colour MCU's open handle: same device */
    uint8_t vc_interface;
    uint8_t camera_terminal_id;
    uint8_t processing_unit_id;
    bool scanned;
} openk4a_uvc_t;

bool openk4a_uvc_scan(openk4a_uvc_t *uvc, openk4a_usb_t *usb);
bool openk4a_uvc_get(openk4a_uvc_t *uvc, uint8_t request, uint8_t unit, uint8_t selector, void *data, uint16_t size);
bool openk4a_uvc_set(openk4a_uvc_t *uvc, uint8_t unit, uint8_t selector, const void *data, uint16_t size);

/* The Metal depth decoder (openk4a_depth_metal.m). create returns NULL when
 * there is no Metal device. */
struct openk4a_depth_model;
void *openk4a_metal_decoder_create(void);
void openk4a_metal_decoder_destroy(void *decoder);
bool openk4a_metal_decode(void *decoder, struct openk4a_depth_model *model, const uint8_t *raw, size_t size, uint16_t *depth, uint16_t *ir);

#endif /* OPENK4A_PLATFORM_H */
