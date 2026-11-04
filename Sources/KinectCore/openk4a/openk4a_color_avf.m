/*=============================================================================
  The colour camera, over AVFoundation.

  The colour device is a UVC camera and macOS has it bound to its own driver,
  which is what makes AVFoundation the honest way to read it: the same route
  every other program on the machine takes to a webcam, with no driver of our
  own in the way. The camera's native format is MJPG; AVFoundation decodes
  it, and the frames come back as pixel buffers in whichever of BGRA, NV12 or
  YUY2 was asked for. A caller asking for MJPG gets the decoded frame
  re-encoded, which costs a JPEG encode per frame.

  Timestamps: a frame's presentation time is on the host clock (the same
  mach_absolute_time openk4a_now_nsec reads). The depth side tells this
  module how that clock relates to the depth processor's 90 kHz clock, so a
  colour frame can carry a device timestamp the pairing in
  k4a_device_get_capture can compare against a depth frame's.

  Controls go over UVC class requests on the device's default pipe
  (openk4a_uvc.c), which macOS leaves reachable.
=============================================================================*/

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Foundation/Foundation.h>

#include "openk4a.h"

#include <errno.h>
#include <time.h>

#define OPENK4A_COLOR_QUEUE 8

@class OpenK4AColorDelegate;

struct openk4a_color
{
    AVCaptureSession *session;
    AVCaptureDevice *device;
    AVCaptureDeviceInput *input;
    AVCaptureVideoDataOutput *output;
    OpenK4AColorDelegate *delegate;
    dispatch_queue_t queue_dispatch;

    pthread_mutex_t lock;
    pthread_cond_t arrived;
    bool lock_inited;
    bool started;

    int width;
    int height;
    int stride;
    k4a_image_format_t format;
    OSType pixel_format;
    bool use_60hz_power;

    /* host nanoseconds minus device microseconds * 1000: what to subtract from
     * a frame's presentation time to put it on the depth clock. The offset of
     * a frame is its arrival minus its exposure, which is the transport
     * latency plus the clock difference; the smallest recent one is the
     * clock difference plus the least latency, which is the steady number. */
    int64_t host_minus_device_nsec;
    bool clock_expected; /* depth is running: frames before its clock is known are dropped */
    int64_t offsets[32];
    int offset_count;
    int offset_next;
    bool have_clock;

    k4a_image_t queue[OPENK4A_COLOR_QUEUE];
    int queue_count;

    openk4a_uvc_t uvc;
    openk4a_color_control_capabilities_t capabilities[K4A_COLOR_CONTROL_POWERLINE_FREQUENCY + 1];

    /* Per-frame metadata: the camera's current exposure, white balance and
     * gain, read over UVC every few frames and stamped on every image. */
    uint64_t meta_exposure_usec;
    uint32_t meta_white_balance;
    uint32_t meta_iso;
    int meta_age;        /* frames since the last UVC read */
    bool meta_valid;
    bool meta_logged;

    /* MJPG: a VideoToolbox JPEG session, kept while the size holds. */
    VTCompressionSessionRef jpeg_session;
    int jpeg_width;
    int jpeg_height;
};

static void color_refresh_metadata(openk4a_color_t *color, AVCaptureDevice *device);
static void jpeg_session_drop(openk4a_color_t *color);
static bool jpeg_encode(openk4a_color_t *color, CVPixelBufferRef pixels, int width, int height, uint8_t **out, size_t *out_size);

static void color_accept(openk4a_color_t *color, CMSampleBufferRef sample);

@interface OpenK4AColorDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, assign) openk4a_color_t *color;
@end

@implementation OpenK4AColorDelegate
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection
{
    (void)output;
    (void)connection;
    if (self.color != NULL)
    {
        color_accept(self.color, sampleBuffer);
    }
}
@end

/*=============================================================================
  Finding the camera
=============================================================================*/

#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>

/* The USB location ids of the colour cameras with this serial, from IOKit:
 * AVFoundation does not expose a serial, but its uniqueID for a USB camera
 * is built from the device's location id and its vendor/product ids. */
static NSArray<NSNumber *> *location_ids_for_serial(const char *serial)
{
    NSMutableArray<NSNumber *> *locations = [NSMutableArray array];
    if (serial == NULL || serial[0] == '\0')
    {
        return locations;
    }
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL)
    {
        return locations;
    }
    int vendor = 0x045E, product = 0x097D;
    CFDictionarySetValue(matching, CFSTR(kUSBVendorID), (__bridge CFNumberRef)@(vendor));
    CFDictionarySetValue(matching, CFSTR(kUSBProductID), (__bridge CFNumberRef)@(product));
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS)
    {
        return locations;
    }
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL)
    {
        NSString *found = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR(kUSBSerialNumberString), kCFAllocatorDefault, 0));
        NSNumber *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR(kUSBDevicePropertyLocationID), kCFAllocatorDefault, 0));
        if ([found isKindOfClass:[NSString class]] && [location isKindOfClass:[NSNumber class]] &&
            strcmp(found.UTF8String, serial) == 0)
        {
            [locations addObject:location];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return locations;
}

/* Whether an AVFoundation uniqueID names a USB device at this location id.
 * The id is "0x" + the location id in hex (its trailing zero byte dropped,
 * as macOS spells it) + vendor + product, so both spellings are tried. */
static bool unique_id_matches_location(NSString *uniqueID, uint32_t location)
{
    NSString *lower = uniqueID.lowercaseString;
    NSString *a = [NSString stringWithFormat:@"0x%x%04x%04x", location, 0x045E, 0x097D];
    NSString *b = [NSString stringWithFormat:@"0x%x%04x%04x", location >> 8, 0x045E, 0x097D];
    return [lower isEqualToString:a] || [lower isEqualToString:b] || [lower hasPrefix:[NSString stringWithFormat:@"0x%x", location]];
}

static AVCaptureDevice *find_camera(const char *serial, uint32_t device_index)
{
    NSArray<AVCaptureDeviceType> *types = @[ AVCaptureDeviceTypeExternal ];
    AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    NSMutableArray<AVCaptureDevice *> *matches = [NSMutableArray array];
    for (AVCaptureDevice *device in discovery.devices)
    {
        NSString *model = device.modelID ?: @"";
        if ([model containsString:@"VendorID_1118"] && [model containsString:@"ProductID_2429"])
        {
            [matches addObject:device];
        }
    }
    [matches sortUsingComparator:^NSComparisonResult(AVCaptureDevice *a, AVCaptureDevice *b) {
        return [a.uniqueID compare:b.uniqueID];
    }];

    /* By serial first: the camera whose USB location AVFoundation's id names. */
    NSArray<NSNumber *> *locations = location_ids_for_serial(serial);
    for (NSNumber *location in locations)
    {
        for (AVCaptureDevice *device in matches)
        {
            if (unique_id_matches_location(device.uniqueID, location.unsignedIntValue))
            {
                openk4a_log(OPENK4A_LOG_INFO, "colour camera %s paired with serial %s by USB location 0x%x",
                        device.uniqueID.UTF8String, serial, location.unsignedIntValue);
                return device;
            }
        }
    }
    /* Then the only camera there is, which needs no pairing. */
    if (matches.count == 1 && serial != NULL && serial[0] != '\0')
    {
        return matches[0];
    }
    if (serial != NULL && serial[0] != '\0' && matches.count > 1)
    {
        openk4a_log(OPENK4A_LOG_WARNING, "no colour camera matched serial %s by USB location; falling back to index %u",
                serial, (unsigned)device_index);
    }
    if (device_index < matches.count)
    {
        return matches[device_index];
    }
    openk4a_log(OPENK4A_LOG_ERROR, "AVFoundation lists %lu Azure Kinect colour camera(s); index %u is not one of them "
                                 "(has the app been granted camera access?)",
            (unsigned long)matches.count, (unsigned)device_index);
    return nil;
}

openk4a_color_t *openk4a_color_create(const openk4a_usb_t *color_mcu, uint32_t device_index)
{
    @autoreleasepool
    {
        openk4a_color_t *color = (openk4a_color_t *)openk4a_alloc_zero(sizeof(openk4a_color_t));
        if (color == NULL)
        {
            return NULL;
        }
        if (pthread_mutex_init(&color->lock, NULL) != 0 || pthread_cond_init(&color->arrived, NULL) != 0)
        {
            openk4a_free(color);
            return NULL;
        }
        color->lock_inited = true;

        AVCaptureDevice *device = find_camera(color_mcu != NULL ? color_mcu->serial : NULL, device_index);
        if (device == nil)
        {
            openk4a_color_destroy(color);
            return NULL;
        }
        color->device = device;
        color->session = [[AVCaptureSession alloc] init];
        color->delegate = [[OpenK4AColorDelegate alloc] init];
        color->delegate.color = color;
        color->queue_dispatch = dispatch_queue_create("openk4a.color", DISPATCH_QUEUE_SERIAL);

        /* The controls ride on the colour MCU's handle: same USB device. */
        (void)openk4a_uvc_scan(&color->uvc, (openk4a_usb_t *)color_mcu);
        return color;
    }
}

void openk4a_color_destroy(openk4a_color_t *color)
{
    if (color == NULL)
    {
        return;
    }
    @autoreleasepool
    {
        openk4a_color_stop(color);
        jpeg_session_drop(color);
        if (color->delegate != nil)
        {
            color->delegate.color = NULL;
        }
        color->delegate = nil;
        color->output = nil;
        color->input = nil;
        color->session = nil;
        color->device = nil;
        color->queue_dispatch = nil;
    }
    for (int i = 0; i < color->queue_count; i++)
    {
        k4a_image_release(color->queue[i]);
    }
    color->queue_count = 0;
    if (color->lock_inited)
    {
        pthread_cond_destroy(&color->arrived);
        pthread_mutex_destroy(&color->lock);
    }
    openk4a_free(color);
}

/*=============================================================================
  Formats
=============================================================================*/

static float fps_of_config(const k4a_device_configuration_t *config)
{
    switch (config->camera_fps)
    {
    case K4A_FRAMES_PER_SECOND_5:
        return 5.0f;
    case K4A_FRAMES_PER_SECOND_15:
        return 15.0f;
    default:
        return 30.0f;
    }
}

static bool color_pick_format(openk4a_color_t *color, const k4a_device_configuration_t *config)
{
    int width = 0;
    int height = 0;
    if (!openk4a_color_grid(config->color_resolution, &width, &height))
    {
        return false;
    }
    switch (config->color_format)
    {
    case K4A_IMAGE_FORMAT_COLOR_NV12:
        color->pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        break;
    case K4A_IMAGE_FORMAT_COLOR_YUY2:
        color->pixel_format = kCVPixelFormatType_422YpCbCr8_yuvs;
        break;
    case K4A_IMAGE_FORMAT_COLOR_MJPG:
    case K4A_IMAGE_FORMAT_COLOR_BGRA32:
        color->pixel_format = kCVPixelFormatType_32BGRA;
        break;
    default:
        openk4a_log(OPENK4A_LOG_ERROR, "colour format %d is not one this camera has", (int)config->color_format);
        return false;
    }
    const float fps = fps_of_config(config);

    /* Prefer the camera's own MJPG at the asked-for size: the colour stream
     * shares the cable with 5.3 MB depth frames, and uncompressed colour costs
     * the depth stream frames. */
    AVCaptureDeviceFormat *chosen = nil;
    AVCaptureDeviceFormat *fallback = nil;
    for (AVCaptureDeviceFormat *format in color->device.formats)
    {
        CMFormatDescriptionRef description = format.formatDescription;
        const CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(description);
        if (dimensions.width != width || dimensions.height != height)
        {
            continue;
        }
        bool rate_ok = false;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges)
        {
            if (range.minFrameRate <= fps + 0.01 && range.maxFrameRate >= fps - 0.01)
            {
                rate_ok = true;
                break;
            }
        }
        if (!rate_ok)
        {
            continue;
        }
        const FourCharCode subtype = CMFormatDescriptionGetMediaSubType(description);
        if (subtype == kCMVideoCodecType_JPEG_OpenDML || subtype == kCMVideoCodecType_JPEG)
        {
            chosen = format;
            break;
        }
        if (fallback == nil)
        {
            fallback = format;
        }
    }
    if (chosen == nil)
    {
        chosen = fallback;
    }
    static bool listed;
    if (getenv("OPENK4A_TRACE_COLOR") != NULL && !listed)
    {
        listed = true;
        for (AVCaptureDeviceFormat *format in color->device.formats)
        {
            const CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            const FourCharCode subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription);
            double max_fps = 0;
            for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges)
            {
                max_fps = range.maxFrameRate > max_fps ? range.maxFrameRate : max_fps;
            }
            openk4a_log(OPENK4A_LOG_INFO, "colour format: %dx%d up to %g fps '%c%c%c%c'%s", dimensions.width, dimensions.height,
                    max_fps, (char)(subtype >> 24), (char)(subtype >> 16), (char)(subtype >> 8), (char)subtype,
                    format == chosen ? "  <- chosen" : "");
        }
    }
    if (chosen == nil)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the colour camera does not offer %dx%d at %g fps; it has:", width, height, (double)fps);
        for (AVCaptureDeviceFormat *format in color->device.formats)
        {
            const CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            const FourCharCode subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription);
            double max_fps = 0;
            for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges)
            {
                max_fps = range.maxFrameRate > max_fps ? range.maxFrameRate : max_fps;
            }
            openk4a_log(OPENK4A_LOG_ERROR, "  %dx%d up to %g fps, '%c%c%c%c'", dimensions.width, dimensions.height, max_fps,
                    (char)(subtype >> 24), (char)(subtype >> 16), (char)(subtype >> 8), (char)subtype);
        }
        return false;
    }

    NSError *error = nil;
    if (![color->device lockForConfiguration:&error])
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the colour camera would not lock for configuration: %s",
                error.localizedDescription.UTF8String);
        return false;
    }
    @try
    {
        color->device.activeFormat = chosen;
    }
    @catch (NSException *exception)
    {
        [color->device unlockForConfiguration];
        openk4a_log(OPENK4A_LOG_ERROR, "the colour camera would not take the format: %s", exception.reason.UTF8String);
        return false;
    }
    /* The camera's rates are ranges of exactly one value each, and not a
     * round one (1000000/30000030), so the duration is the range's own
     * rather than 1/fps. */
    AVFrameRateRange *rate = nil;
    for (AVFrameRateRange *range in chosen.videoSupportedFrameRateRanges)
    {
        if (range.minFrameRate <= fps + 0.01 && range.maxFrameRate >= fps - 0.01)
        {
            rate = range;
            break;
        }
    }
    @try
    {
        if (rate != nil)
        {
            color->device.activeVideoMinFrameDuration = rate.minFrameDuration;
            color->device.activeVideoMaxFrameDuration = rate.maxFrameDuration;
        }
    }
    @catch (NSException *exception)
    {
        openk4a_log(OPENK4A_LOG_INFO, "the colour camera keeps its own frame duration: %s", exception.reason.UTF8String);
    }
    [color->device unlockForConfiguration];

    color->width = width;
    color->height = height;
    color->format = config->color_format;
    color->stride = openk4a_format_stride(config->color_format, width);
    return true;
}

/*=============================================================================
  Frames
=============================================================================*/

/* The camera's own stream is MJPG, but AVFoundation hands it over decoded,
 * so a caller asking for MJPG gets the frame encoded again: VideoToolbox's
 * JPEG encoder (hardware where the machine has it), one baseline JPEG per
 * frame. The session lives for as long as the frame size holds. */
typedef struct
{
    uint8_t *data;
    size_t size;
    bool done;
} openk4a_jpeg_result_t;

static void jpeg_session_drop(openk4a_color_t *color)
{
    if (color->jpeg_session != NULL)
    {
        VTCompressionSessionInvalidate(color->jpeg_session);
        CFRelease(color->jpeg_session);
        color->jpeg_session = NULL;
    }
}

static bool jpeg_session_prepare(openk4a_color_t *color, int width, int height)
{
    if (color->jpeg_session != NULL && color->jpeg_width == width && color->jpeg_height == height)
    {
        return true;
    }
    jpeg_session_drop(color);
    VTCompressionSessionRef session = NULL;
    const OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)width, (int32_t)height, kCMVideoCodecType_JPEG,
                                                       NULL, NULL, NULL, NULL, NULL, &session);
    if (status != noErr || session == NULL)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "colour: no JPEG encoder (VideoToolbox status %d)", (int)status);
        return false;
    }
    VTSessionSetProperty(session, kVTCompressionPropertyKey_Quality, (__bridge CFTypeRef) @0.9);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTCompressionSessionPrepareToEncodeFrames(session);
    color->jpeg_session = session;
    color->jpeg_width = width;
    color->jpeg_height = height;
    return true;
}

static bool jpeg_encode(openk4a_color_t *color, CVPixelBufferRef pixels, int width, int height, uint8_t **out, size_t *out_size)
{
    if (!jpeg_session_prepare(color, width, height))
    {
        return false;
    }
    __block openk4a_jpeg_result_t result = { NULL, 0, false };
    const OSStatus submitted = VTCompressionSessionEncodeFrameWithOutputHandler(
        color->jpeg_session, pixels, CMTimeMake(1, 30), kCMTimeInvalid, NULL, NULL,
        ^(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sampleBuffer) {
            (void)flags;
            if (status == noErr && sampleBuffer != NULL)
            {
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
                const size_t length = block != NULL ? CMBlockBufferGetDataLength(block) : 0;
                if (length > 0)
                {
                    uint8_t *copy = (uint8_t *)openk4a_alloc(length);
                    if (copy != NULL && CMBlockBufferCopyDataBytes(block, 0, length, copy) == kCMBlockBufferNoErr)
                    {
                        result.data = copy;
                        result.size = length;
                    }
                    else
                    {
                        openk4a_free(copy);
                    }
                }
            }
            result.done = true;
        });
    if (submitted != noErr)
    {
        openk4a_log(OPENK4A_LOG_WARNING, "colour: JPEG encode would not start (%d)", (int)submitted);
        jpeg_session_drop(color);
        return false;
    }
    /* One frame at a time: the handler has run by the time this returns. */
    VTCompressionSessionCompleteFrames(color->jpeg_session, kCMTimeInvalid);
    if (!result.done || result.data == NULL)
    {
        return false;
    }
    *out = result.data;
    *out_size = result.size;
    return true;
}

static void color_accept(openk4a_color_t *color, CMSampleBufferRef sample)
{
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (pixels == NULL)
    {
        return;
    }
    const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    const uint64_t system_nsec = (uint64_t)(CMTimeGetSeconds(pts) * 1.0e9);

    if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
    {
        return;
    }
    const int width = (int)CVPixelBufferGetWidth(pixels);
    const int height = (int)CVPixelBufferGetHeight(pixels);
    uint8_t *copy = NULL;
    size_t size = 0;
    int stride = color->stride;
    bool ok = false;

    if (width != color->width || height != color->height)
    {
        openk4a_log(OPENK4A_LOG_WARNING, "colour: a %dx%d frame arrived for a %dx%d stream", width, height, color->width,
                color->height);
    }
    else if (color->format == K4A_IMAGE_FORMAT_COLOR_MJPG)
    {
        ok = jpeg_encode(color, pixels, width, height, &copy, &size);
        stride = 0;
    }
    else if (color->format == K4A_IMAGE_FORMAT_COLOR_NV12)
    {
        /* Two planes, packed to the K4A layout: luma then interleaved chroma,
         * both at a stride of one byte a pixel. */
        size = (size_t)width * (size_t)height * 3 / 2;
        copy = (uint8_t *)openk4a_alloc(size);
        if (copy != NULL && CVPixelBufferGetPlaneCount(pixels) == 2)
        {
            const uint8_t *luma = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixels, 0);
            const size_t luma_stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0);
            const uint8_t *chroma = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixels, 1);
            const size_t chroma_stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1);
            for (int row = 0; row < height; row++)
            {
                memcpy(copy + (size_t)row * (size_t)width, luma + (size_t)row * luma_stride, (size_t)width);
            }
            uint8_t *chroma_out = copy + (size_t)width * (size_t)height;
            for (int row = 0; row < height / 2; row++)
            {
                memcpy(chroma_out + (size_t)row * (size_t)width, chroma + (size_t)row * chroma_stride, (size_t)width);
            }
            ok = true;
        }
    }
    else
    {
        /* BGRA or YUY2: one plane, repacked to the K4A stride. */
        size = (size_t)stride * (size_t)height;
        copy = (uint8_t *)openk4a_alloc(size);
        const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pixels);
        const size_t source_stride = CVPixelBufferGetBytesPerRow(pixels);
        if (copy != NULL && base != NULL)
        {
            for (int row = 0; row < height; row++)
            {
                memcpy(copy + (size_t)row * (size_t)stride, base + (size_t)row * source_stride, (size_t)stride);
            }
            ok = true;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);

    if (!ok)
    {
        openk4a_free(copy);
        return;
    }
    k4a_image_t image = openk4a_image_create(color->format, color->width, color->height, stride, size, copy, NULL, NULL);
    if (image == NULL)
    {
        openk4a_free(copy);
        return;
    }

    pthread_mutex_lock(&color->lock);
    if (color->clock_expected && !color->have_clock)
    {
        /* Until a depth frame has set the clock, a colour frame has no device
         * time to carry; the SDK drops these too. */
        pthread_mutex_unlock(&color->lock);
        k4a_image_release(image);
        return;
    }
    uint64_t device_usec = system_nsec / 1000ULL;
    if (color->have_clock)
    {
        const int64_t on_device = ((int64_t)system_nsec - color->host_minus_device_nsec) / 1000;
        device_usec = on_device > 0 ? (uint64_t)on_device : 0;
    }
    k4a_image_set_device_timestamp_usec(image, device_usec);
    k4a_image_set_system_timestamp_nsec(image, system_nsec);
    pthread_mutex_unlock(&color->lock);

    /* The camera's exposure, white balance and gain as they stand: read
     * every third frame (three control transfers, about a millisecond each,
     * on this thread) and stamped on every frame. */
    if (!color->meta_valid || ++color->meta_age >= 3)
    {
        color_refresh_metadata(color, color->device);
        color->meta_age = 0;
    }
    k4a_image_set_exposure_usec(image, color->meta_exposure_usec);
    k4a_image_set_white_balance(image, color->meta_white_balance);
    k4a_image_set_iso_speed(image, color->meta_iso);

    pthread_mutex_lock(&color->lock);
    if (color->queue_count == OPENK4A_COLOR_QUEUE)
    {
        k4a_image_release(color->queue[0]);
        memmove(color->queue, color->queue + 1, sizeof(color->queue) - sizeof(color->queue[0]));
        color->queue_count--;
    }
    color->queue[color->queue_count++] = image;
    pthread_cond_broadcast(&color->arrived);
    pthread_mutex_unlock(&color->lock);
}

void openk4a_color_expect_clock(openk4a_color_t *color, bool expected)
{
    if (color != NULL)
    {
        pthread_mutex_lock(&color->lock);
        color->clock_expected = expected;
        pthread_mutex_unlock(&color->lock);
    }
}

void openk4a_color_set_clock(openk4a_color_t *color, uint64_t depth_device_usec, uint64_t host_arrival_nsec)
{
    if (color == NULL)
    {
        return;
    }
    /* The depth frame's exposure sits roughly one transfer before its
     * arrival; the offset is smoothed so a late frame does not swing it. */
    const int64_t offset = (int64_t)host_arrival_nsec - (int64_t)depth_device_usec * 1000;
    const int window = (int)(sizeof(color->offsets) / sizeof(color->offsets[0]));
    pthread_mutex_lock(&color->lock);
    color->offsets[color->offset_next] = offset;
    color->offset_next = (color->offset_next + 1) % window;
    if (color->offset_count < window)
    {
        color->offset_count++;
    }
    int64_t smallest = color->offsets[0];
    for (int i = 1; i < color->offset_count; i++)
    {
        if (color->offsets[i] < smallest)
        {
            smallest = color->offsets[i];
        }
    }
    /* The smallest offset still carries the depth frame's own journey: the
     * rest of its exposure after the centre, the readout and 5 MB over USB,
     * which together come to about 40 ms on this hardware. Taking that off
     * puts a colour frame exposed at the same instant on the same number. */
    static int64_t latency_nsec = -1;
    if (latency_nsec < 0)
    {
        const char *given = getenv("OPENK4A_DEPTH_LATENCY_MS");
        latency_nsec = (given != NULL ? atoll(given) : 40) * 1000000LL;
    }
    color->host_minus_device_nsec = smallest - latency_nsec;
    color->have_clock = true;
    pthread_mutex_unlock(&color->lock);
}

bool openk4a_color_start(openk4a_color_t *color, const k4a_device_configuration_t *config)
{
    if (color == NULL || color->started)
    {
        return false;
    }
    @autoreleasepool
    {
        if (!color_pick_format(color, config))
        {
            return false;
        }
        NSError *error = nil;
        [color->session beginConfiguration];
        if (color->input == nil)
        {
            color->input = [AVCaptureDeviceInput deviceInputWithDevice:color->device error:&error];
            if (color->input == nil || ![color->session canAddInput:color->input])
            {
                [color->session commitConfiguration];
                openk4a_log(OPENK4A_LOG_ERROR, "the colour camera would not open: %s",
                        error.localizedDescription.UTF8String ?: "cannot add input");
                color->input = nil;
                return false;
            }
            [color->session addInput:color->input];
        }
        if (color->output == nil)
        {
            color->output = [[AVCaptureVideoDataOutput alloc] init];
            color->output.alwaysDiscardsLateVideoFrames = YES;
            [color->output setSampleBufferDelegate:color->delegate queue:color->queue_dispatch];
            if (![color->session canAddOutput:color->output])
            {
                [color->session commitConfiguration];
                openk4a_log(OPENK4A_LOG_ERROR, "the colour session would not take a video output");
                color->output = nil;
                return false;
            }
            [color->session addOutput:color->output];
        }
        color->output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(color->pixel_format) };
        [color->session commitConfiguration];

        /* Adding the input puts the session's preset on the device, so the
         * format is set again now that the input is in, and the device's own
         * format is what the session then streams. */
        if (!color_pick_format(color, config))
        {
            return false;
        }

        pthread_mutex_lock(&color->lock);
        for (int i = 0; i < color->queue_count; i++)
        {
            k4a_image_release(color->queue[i]);
        }
        color->queue_count = 0;
        color->offset_count = 0;
        color->offset_next = 0;
        color->have_clock = false;
        color->started = true;
        pthread_mutex_unlock(&color->lock);

        [color->session startRunning];
        /* Starting applies the session's preset to the device; on macOS the
         * device's own format sticks only when it is set on a running
         * session, so it is set one more time here. */
        if (!color_pick_format(color, config))
        {
            [color->session stopRunning];
            return false;
        }
        {
            const CMVideoDimensions active = CMVideoFormatDescriptionGetDimensions(color->device.activeFormat.formatDescription);
            openk4a_log(OPENK4A_LOG_INFO, "colour: streaming %dx%d (asked %dx%d)", active.width, active.height, color->width, color->height);
        }
        if (!color->session.isRunning)
        {
            pthread_mutex_lock(&color->lock);
            color->started = false;
            pthread_mutex_unlock(&color->lock);
            openk4a_log(OPENK4A_LOG_ERROR, "the colour session would not start running");
            return false;
        }
        return true;
    }
}

void openk4a_color_stop(openk4a_color_t *color)
{
    if (color == NULL || !color->started)
    {
        return;
    }
    @autoreleasepool
    {
        [color->session stopRunning];
    }
    pthread_mutex_lock(&color->lock);
    color->started = false;
    pthread_cond_broadcast(&color->arrived);
    pthread_mutex_unlock(&color->lock);
}

bool openk4a_color_take_latest(openk4a_color_t *color, openk4a_color_frame_t *out)
{
    out->image = NULL;
    out->device_timestamp_usec = 0;
    if (color == NULL)
    {
        return false;
    }
    pthread_mutex_lock(&color->lock);
    if (color->queue_count == 0)
    {
        pthread_mutex_unlock(&color->lock);
        return false;
    }
    out->image = color->queue[color->queue_count - 1];
    out->device_timestamp_usec = k4a_image_get_device_timestamp_usec(out->image);
    for (int i = 0; i + 1 < color->queue_count; i++)
    {
        k4a_image_release(color->queue[i]);
    }
    color->queue_count = 0;
    pthread_mutex_unlock(&color->lock);
    return true;
}

bool openk4a_color_wait(openk4a_color_t *color, int timeout_ms)
{
    if (color == NULL)
    {
        return false;
    }
    pthread_mutex_lock(&color->lock);
    if (color->queue_count > 0)
    {
        pthread_mutex_unlock(&color->lock);
        return true;
    }
    if (timeout_ms < 0)
    {
        while (color->queue_count == 0 && color->started)
        {
            pthread_cond_wait(&color->arrived, &color->lock);
        }
    }
    else
    {
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += timeout_ms / 1000;
        deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
        if (deadline.tv_nsec >= 1000000000L)
        {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000L;
        }
        while (color->queue_count == 0 && color->started)
        {
            if (pthread_cond_timedwait(&color->arrived, &color->lock, &deadline) == ETIMEDOUT)
            {
                break;
            }
        }
    }
    const bool have = color->queue_count > 0;
    pthread_mutex_unlock(&color->lock);
    return have;
}

bool openk4a_color_take(openk4a_color_t *color, uint64_t depth_device_usec, openk4a_color_frame_t *out)
{
    out->image = NULL;
    out->device_timestamp_usec = 0;
    if (color == NULL)
    {
        return false;
    }
    pthread_mutex_lock(&color->lock);
    if (color->queue_count == 0)
    {
        pthread_mutex_unlock(&color->lock);
        return false;
    }
    int best = 0;
    uint64_t best_distance = UINT64_MAX;
    for (int i = 0; i < color->queue_count; i++)
    {
        const uint64_t timestamp = k4a_image_get_device_timestamp_usec(color->queue[i]);
        const uint64_t distance = timestamp > depth_device_usec ? timestamp - depth_device_usec : depth_device_usec - timestamp;
        if (distance < best_distance)
        {
            best_distance = distance;
            best = i;
        }
    }
    out->image = color->queue[best];
    out->device_timestamp_usec = k4a_image_get_device_timestamp_usec(out->image);
    for (int i = 0; i < best; i++)
    {
        k4a_image_release(color->queue[i]);
    }
    for (int i = best + 1; i < color->queue_count; i++)
    {
        color->queue[i - best - 1] = color->queue[i];
    }
    color->queue_count -= best + 1;
    pthread_mutex_unlock(&color->lock);
    return true;
}

void openk4a_color_release(openk4a_color_frame_t *frame)
{
    if (frame != NULL && frame->image != NULL)
    {
        k4a_image_release(frame->image);
        frame->image = NULL;
    }
}

/*=============================================================================
  The controls, as UVC requests
=============================================================================*/

#define UVC_GET_CUR 0x81
#define UVC_GET_MIN 0x82
#define UVC_GET_MAX 0x83
#define UVC_GET_RES 0x84
#define UVC_GET_INFO 0x86
#define UVC_GET_DEF 0x87

#define UVC_CT_AE_MODE 0x02
#define UVC_CT_AE_PRIORITY 0x03
#define UVC_CT_EXPOSURE_TIME_ABSOLUTE 0x04
#define UVC_PU_BACKLIGHT_COMPENSATION 0x01
#define UVC_PU_BRIGHTNESS 0x02
#define UVC_PU_CONTRAST 0x03
#define UVC_PU_GAIN 0x04
#define UVC_PU_POWER_LINE_FREQUENCY 0x05
#define UVC_PU_SATURATION 0x07
#define UVC_PU_SHARPNESS 0x08
#define UVC_PU_WHITE_BALANCE_TEMPERATURE 0x0A
#define UVC_PU_WHITE_BALANCE_TEMPERATURE_AUTO 0x0B

#define UVC_AE_MODE_MANUAL 1
#define UVC_AE_MODE_APERTURE_PRIORITY 8

typedef struct
{
    bool camera_terminal; /* else processing unit */
    uint8_t selector;
    uint16_t size;
    bool is_signed;
    bool has_auto;
} openk4a_uvc_control_t;

static bool control_of(k4a_color_control_command_t command, openk4a_uvc_control_t *out)
{
    switch (command)
    {
    case K4A_COLOR_CONTROL_EXPOSURE_TIME_ABSOLUTE:
        *out = (openk4a_uvc_control_t){ true, UVC_CT_EXPOSURE_TIME_ABSOLUTE, 4, false, true };
        return true;
    case K4A_COLOR_CONTROL_AUTO_EXPOSURE_PRIORITY:
        *out = (openk4a_uvc_control_t){ true, UVC_CT_AE_PRIORITY, 1, false, false };
        return true;
    case K4A_COLOR_CONTROL_BRIGHTNESS:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_BRIGHTNESS, 2, true, false };
        return true;
    case K4A_COLOR_CONTROL_CONTRAST:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_CONTRAST, 2, false, false };
        return true;
    case K4A_COLOR_CONTROL_SATURATION:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_SATURATION, 2, false, false };
        return true;
    case K4A_COLOR_CONTROL_SHARPNESS:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_SHARPNESS, 2, false, false };
        return true;
    case K4A_COLOR_CONTROL_WHITEBALANCE:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_WHITE_BALANCE_TEMPERATURE, 2, false, true };
        return true;
    case K4A_COLOR_CONTROL_BACKLIGHT_COMPENSATION:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_BACKLIGHT_COMPENSATION, 2, false, false };
        return true;
    case K4A_COLOR_CONTROL_GAIN:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_GAIN, 2, false, false };
        return true;
    case K4A_COLOR_CONTROL_POWERLINE_FREQUENCY:
        *out = (openk4a_uvc_control_t){ false, UVC_PU_POWER_LINE_FREQUENCY, 1, false, false };
        return true;
    default:
        return false;
    }
}

static uint8_t unit_of(openk4a_color_t *color, const openk4a_uvc_control_t *control)
{
    return control->camera_terminal ? color->uvc.camera_terminal_id : color->uvc.processing_unit_id;
}

static bool uvc_read(openk4a_color_t *color, const openk4a_uvc_control_t *control, uint8_t request, int32_t *value)
{
    uint8_t raw[4] = { 0 };
    if (!openk4a_uvc_get(&color->uvc, request, unit_of(color, control), control->selector, raw, control->size))
    {
        return false;
    }
    uint32_t bits = 0;
    for (uint16_t i = 0; i < control->size; i++)
    {
        bits |= (uint32_t)raw[i] << (8 * i);
    }
    if (control->is_signed && control->size == 2)
    {
        *value = (int16_t)bits;
    }
    else if (control->is_signed && control->size == 1)
    {
        *value = (int8_t)bits;
    }
    else
    {
        *value = (int32_t)bits;
    }
    return true;
}

static bool uvc_write(openk4a_color_t *color, const openk4a_uvc_control_t *control, int32_t value)
{
    uint8_t raw[4];
    for (uint16_t i = 0; i < control->size; i++)
    {
        raw[i] = (uint8_t)(((uint32_t)value >> (8 * i)) & 0xFF);
    }
    return openk4a_uvc_set(&color->uvc, unit_of(color, control), control->selector, raw, control->size);
}

/* The exposure the camera takes is in units of 100 microseconds over UVC;
 * the API counts microseconds. */
#define OPENK4A_EXPOSURE_UNIT_USEC 100

bool openk4a_color_control_capabilities(openk4a_color_t *color,
                                        k4a_color_control_command_t command,
                                        openk4a_color_control_capabilities_t *out)
{
    openk4a_uvc_control_t control;
    if (color == NULL || out == NULL || !control_of(command, &control))
    {
        return false;
    }
    if (color->capabilities[command].valid)
    {
        *out = color->capabilities[command];
        return true;
    }
    int32_t min_value = 0;
    int32_t max_value = 0;
    int32_t step = 1;
    int32_t default_value = 0;
    if (!uvc_read(color, &control, UVC_GET_MIN, &min_value) || !uvc_read(color, &control, UVC_GET_MAX, &max_value) ||
        !uvc_read(color, &control, UVC_GET_DEF, &default_value))
    {
        return false;
    }
    (void)uvc_read(color, &control, UVC_GET_RES, &step);

    openk4a_color_control_capabilities_t result;
    memset(&result, 0, sizeof(result));
    result.supports_auto = control.has_auto;
    result.min_value = min_value;
    result.max_value = max_value;
    result.step_value = step > 0 ? step : 1;
    result.default_value = default_value;
    result.default_mode = control.has_auto ? K4A_COLOR_CONTROL_MODE_AUTO : K4A_COLOR_CONTROL_MODE_MANUAL;
    if (command == K4A_COLOR_CONTROL_EXPOSURE_TIME_ABSOLUTE)
    {
        result.min_value *= OPENK4A_EXPOSURE_UNIT_USEC;
        result.max_value *= OPENK4A_EXPOSURE_UNIT_USEC;
        result.step_value *= OPENK4A_EXPOSURE_UNIT_USEC;
        result.default_value *= OPENK4A_EXPOSURE_UNIT_USEC;
    }
    result.valid = true;
    color->capabilities[command] = result;
    *out = result;
    return true;
}

bool openk4a_color_control_get(openk4a_color_t *color,
                               k4a_color_control_command_t command,
                               k4a_color_control_mode_t *mode,
                               int32_t *value)
{
    openk4a_uvc_control_t control;
    if (color == NULL || mode == NULL || value == NULL || !control_of(command, &control))
    {
        return false;
    }
    int32_t raw = 0;
    if (!uvc_read(color, &control, UVC_GET_CUR, &raw))
    {
        return false;
    }
    *mode = K4A_COLOR_CONTROL_MODE_MANUAL;
    if (command == K4A_COLOR_CONTROL_EXPOSURE_TIME_ABSOLUTE)
    {
        const openk4a_uvc_control_t ae = { true, UVC_CT_AE_MODE, 1, false, false };
        int32_t ae_mode = UVC_AE_MODE_MANUAL;
        if (uvc_read(color, &ae, UVC_GET_CUR, &ae_mode) && ae_mode != UVC_AE_MODE_MANUAL)
        {
            *mode = K4A_COLOR_CONTROL_MODE_AUTO;
        }
        raw *= OPENK4A_EXPOSURE_UNIT_USEC;
    }
    else if (command == K4A_COLOR_CONTROL_WHITEBALANCE)
    {
        const openk4a_uvc_control_t wb_auto = { false, UVC_PU_WHITE_BALANCE_TEMPERATURE_AUTO, 1, false, false };
        int32_t automatic = 0;
        if (uvc_read(color, &wb_auto, UVC_GET_CUR, &automatic) && automatic != 0)
        {
            *mode = K4A_COLOR_CONTROL_MODE_AUTO;
        }
    }
    *value = raw;
    return true;
}

bool openk4a_color_control_set(openk4a_color_t *color,
                               k4a_color_control_command_t command,
                               k4a_color_control_mode_t mode,
                               int32_t value)
{
    openk4a_uvc_control_t control;
    if (color == NULL || !control_of(command, &control) ||
        (mode != K4A_COLOR_CONTROL_MODE_AUTO && mode != K4A_COLOR_CONTROL_MODE_MANUAL))
    {
        return false;
    }
    if (mode == K4A_COLOR_CONTROL_MODE_AUTO && !control.has_auto)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "colour control %d has no automatic mode", (int)command);
        return false;
    }
    if (command == K4A_COLOR_CONTROL_EXPOSURE_TIME_ABSOLUTE)
    {
        const openk4a_uvc_control_t ae = { true, UVC_CT_AE_MODE, 1, false, false };
        if (!uvc_write(color, &ae, mode == K4A_COLOR_CONTROL_MODE_AUTO ? UVC_AE_MODE_APERTURE_PRIORITY : UVC_AE_MODE_MANUAL))
        {
            return false;
        }
        if (mode == K4A_COLOR_CONTROL_MODE_AUTO)
        {
            return true;
        }
        return uvc_write(color, &control, value / OPENK4A_EXPOSURE_UNIT_USEC);
    }
    if (command == K4A_COLOR_CONTROL_WHITEBALANCE)
    {
        const openk4a_uvc_control_t wb_auto = { false, UVC_PU_WHITE_BALANCE_TEMPERATURE_AUTO, 1, false, false };
        if (!uvc_write(color, &wb_auto, mode == K4A_COLOR_CONTROL_MODE_AUTO ? 1 : 0))
        {
            return false;
        }
        if (mode == K4A_COLOR_CONTROL_MODE_AUTO)
        {
            return true;
        }
    }
    if (!uvc_write(color, &control, value))
    {
        return false;
    }
    if (command == K4A_COLOR_CONTROL_POWERLINE_FREQUENCY)
    {
        color->use_60hz_power = value == 2;
    }
    return true;
}

/*=============================================================================
  Per-frame metadata
=============================================================================*/

/* Reads the camera's current exposure, white balance and gain over UVC, and
 * where macOS reports an exposure duration or ISO for the device, uses
 * those when the UVC read fails. ISO is reported as the sensor's gain
 * (0..255 on this camera): the device has no separate ISO control. */
static void color_refresh_metadata(openk4a_color_t *color, AVCaptureDevice *device)
{
    const openk4a_uvc_control_t exposure = { true, UVC_CT_EXPOSURE_TIME_ABSOLUTE, 4, false, true };
    const openk4a_uvc_control_t white_balance = { false, UVC_PU_WHITE_BALANCE_TEMPERATURE, 2, false, true };
    const openk4a_uvc_control_t gain = { false, UVC_PU_GAIN, 2, false, false };
    int32_t value = 0;
    bool any = false;
    const uint64_t started = openk4a_now_fine_nsec();
    if (uvc_read(color, &exposure, UVC_GET_CUR, &value))
    {
        color->meta_exposure_usec = (uint64_t)value * OPENK4A_EXPOSURE_UNIT_USEC;
        any = true;
    }
    else if (device != nil && [device respondsToSelector:NSSelectorFromString(@"exposureDuration")])
    {
        /* Not in the macOS SDK's headers, but some cameras answer it. */
        id boxed = [device valueForKey:@"exposureDuration"];
        CMTime duration = kCMTimeInvalid;
        if ([boxed isKindOfClass:[NSValue class]])
        {
            [(NSValue *)boxed getValue:&duration size:sizeof(duration)];
        }
        if (CMTIME_IS_VALID(duration) && duration.timescale != 0)
        {
            color->meta_exposure_usec = (uint64_t)(CMTimeGetSeconds(duration) * 1.0e6);
            any = true;
        }
    }
    if (uvc_read(color, &white_balance, UVC_GET_CUR, &value))
    {
        color->meta_white_balance = (uint32_t)value;
        any = true;
    }
    if (uvc_read(color, &gain, UVC_GET_CUR, &value))
    {
        color->meta_iso = (uint32_t)value;
        any = true;
    }
    else if (device != nil && [device respondsToSelector:NSSelectorFromString(@"ISO")])
    {
        id boxed = [device valueForKey:@"ISO"];
        if ([boxed isKindOfClass:[NSNumber class]])
        {
            color->meta_iso = (uint32_t)[(NSNumber *)boxed floatValue];
            any = true;
        }
    }
    if (!color->meta_logged)
    {
        color->meta_logged = true;
        openk4a_log(OPENK4A_LOG_INFO, "colour: metadata read takes %.2f ms (exposure %llu us, white balance %u K, gain %u)",
                (double)(openk4a_now_fine_nsec() - started) / 1e6, (unsigned long long)color->meta_exposure_usec,
                color->meta_white_balance, color->meta_iso);
    }
    color->meta_valid = any;
}
