/*=============================================================================
  libusb.

  Two of the camera's three USB functions are plain vendor-specific
  interfaces that nothing in macOS claims: the depth processor (045E:097C,
  interface 0) and the colour MCU (interface 2 of the colour device,
  045E:097D). Both speak the same command protocol - a twenty-byte header, an
  optional payload, then a sixteen-byte response carrying the transaction's
  own id - and both stream frames or IMU samples over a third endpoint.

  Three things about the protocol are worth writing down (from OpenK4A):

    - a session can start with a packet the last one left behind, so a
      command waits for the response carrying its own id rather than the
      first one to arrive;
    - the device ends a transfer with a zero-length packet, so a read that
      comes back empty is read again;
    - a read can come back with fewer bytes than were asked for, and asking
      for more than exists is not an error.
=============================================================================*/

#include "openk4a.h"

#include <errno.h>
#include <time.h>
#include <unistd.h>

#define OPENK4A_USB_VID 0x045E

const openk4a_usb_id_t OPENK4A_USB_DEPTH = { 0x097C, 0, 0x02, 0x81, 0x83 };
const openk4a_usb_id_t OPENK4A_USB_COLOR = { 0x097D, 2, 0x04, 0x83, 0x82 };

#pragma pack(push, 1)
typedef struct
{
    uint32_t packet_type;
    uint32_t packet_transaction_id;
    uint32_t payload_size;
    uint32_t command;
    uint32_t reserved;
} openk4a_command_header_t;

typedef struct
{
    openk4a_command_header_t header;
    uint8_t data[OPENK4A_CMD_PACKET_DATA_BYTES];
} openk4a_command_packet_t;

typedef struct
{
    uint32_t packet_type;
    uint32_t packet_transaction_id;
    uint32_t status;
    uint32_t reserved;
} openk4a_command_response_t;
#pragma pack(pop)

/*=============================================================================
  The context and its event thread
=============================================================================*/

static libusb_context *usb_context;
static pthread_t usb_thread;
static bool usb_thread_running;
static pthread_mutex_t usb_context_lock = PTHREAD_MUTEX_INITIALIZER;

static void *usb_event_thread(void *parameter)
{
    (void)parameter;
    pthread_setname_np("openk4a.libusb");
    while (usb_thread_running)
    {
        struct timeval tv = { 0, 250000 };
        libusb_handle_events_timeout_completed(usb_context, &tv, NULL);
    }
    return NULL;
}

/* The context lives for the process. Tearing it down at exit is not worth
 * it: a program that quits with a camera open would trip libusb's own
 * consistency checks on the way out, and the kernel reclaims everything
 * anyway. */

libusb_context *openk4a_usb_context(void)
{
    pthread_mutex_lock(&usb_context_lock);
    if (usb_context == NULL)
    {
        if (libusb_init(&usb_context) != 0)
        {
            usb_context = NULL;
        }
        else
        {
            usb_thread_running = true;
            if (pthread_create(&usb_thread, NULL, usb_event_thread, NULL) != 0)
            {
                usb_thread_running = false;
                libusb_exit(usb_context);
                usb_context = NULL;
            }
        }
    }
    pthread_mutex_unlock(&usb_context_lock);
    return usb_context;
}

/*=============================================================================
  Finding a camera
=============================================================================*/

/* The nth device of a kind, in the order libusb lists them. The caller holds
 * a reference on the returned device. */
static libusb_device *find_device(const openk4a_usb_id_t *id, uint32_t index, uint32_t *count)
{
    libusb_context *context = openk4a_usb_context();
    if (count != NULL)
    {
        *count = 0;
    }
    if (context == NULL)
    {
        return NULL;
    }
    libusb_device **list = NULL;
    const ssize_t n = libusb_get_device_list(context, &list);
    libusb_device *found = NULL;
    uint32_t seen = 0;
    for (ssize_t i = 0; i < n; i++)
    {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(list[i], &descriptor) != 0)
        {
            continue;
        }
        if (descriptor.idVendor != OPENK4A_USB_VID || descriptor.idProduct != id->pid)
        {
            continue;
        }
        if (seen == index && found == NULL)
        {
            found = libusb_ref_device(list[i]);
        }
        seen++;
    }
    if (n >= 0)
    {
        libusb_free_device_list(list, 1);
    }
    if (count != NULL)
    {
        *count = seen;
    }
    return found;
}

uint32_t openk4a_usb_count(const openk4a_usb_id_t *id)
{
    uint32_t count = 0;
    libusb_device *device = find_device(id, UINT32_MAX, &count);
    if (device != NULL)
    {
        libusb_unref_device(device);
    }
    return count;
}

bool openk4a_usb_path(const openk4a_usb_id_t *id, uint32_t index, char *out, size_t out_size)
{
    libusb_device *device = find_device(id, index, NULL);
    if (device == NULL)
    {
        return false;
    }
    snprintf(out, out_size, "usb:%u.%u", (unsigned)libusb_get_bus_number(device), (unsigned)libusb_get_device_address(device));
    libusb_unref_device(device);
    return true;
}

void openk4a_usb_serial_from_path(const char *path, char *serial, size_t serial_size)
{
    /* There is no serial in a bus address; the serial is read from the device
     * on open instead. */
    (void)path;
    if (serial_size > 0)
    {
        serial[0] = '\0';
    }
}

/*=============================================================================
  Opening
=============================================================================*/

static bool endpoint_present(libusb_device *device, int interface_number, uint8_t address)
{
    struct libusb_config_descriptor *config = NULL;
    if (libusb_get_active_config_descriptor(device, &config) != 0 || config == NULL)
    {
        return false;
    }
    bool present = false;
    for (int i = 0; i < config->bNumInterfaces && !present; i++)
    {
        for (int a = 0; a < config->interface[i].num_altsetting && !present; a++)
        {
            const struct libusb_interface_descriptor *alt = &config->interface[i].altsetting[a];
            if (alt->bInterfaceNumber != interface_number)
            {
                continue;
            }
            for (int e = 0; e < alt->bNumEndpoints; e++)
            {
                if (alt->endpoint[e].bEndpointAddress == address)
                {
                    present = true;
                    break;
                }
            }
        }
    }
    libusb_free_config_descriptor(config);
    return present;
}

/* The serial string of a device, read through a short-lived handle. Empty
 * when the device cannot be opened (another process may hold it exclusively,
 * which on macOS it never does for these functions). */
static bool device_serial(libusb_device *device, char *out, size_t out_size)
{
    out[0] = '\0';
    struct libusb_device_descriptor descriptor;
    if (libusb_get_device_descriptor(device, &descriptor) != 0 || descriptor.iSerialNumber == 0)
    {
        return false;
    }
    libusb_device_handle *handle = NULL;
    if (libusb_open(device, &handle) != 0)
    {
        return false;
    }
    unsigned char serial[128];
    const int got = libusb_get_string_descriptor_ascii(handle, descriptor.iSerialNumber, serial, sizeof(serial) - 1);
    libusb_close(handle);
    if (got <= 0)
    {
        return false;
    }
    serial[got] = '\0';
    snprintf(out, out_size, "%s", (const char *)serial);
    return true;
}

/* The device of a kind with this serial, or NULL. The caller holds the reference. */
static libusb_device *find_device_by_serial(const openk4a_usb_id_t *id, const char *serial)
{
    libusb_context *context = openk4a_usb_context();
    if (context == NULL || serial == NULL || serial[0] == '\0')
    {
        return NULL;
    }
    libusb_device **list = NULL;
    const ssize_t n = libusb_get_device_list(context, &list);
    libusb_device *found = NULL;
    for (ssize_t i = 0; i < n && found == NULL; i++)
    {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(list[i], &descriptor) != 0 || descriptor.idVendor != OPENK4A_USB_VID ||
            descriptor.idProduct != id->pid)
        {
            continue;
        }
        char candidate[128];
        if (device_serial(list[i], candidate, sizeof(candidate)) && strcmp(candidate, serial) == 0)
        {
            found = libusb_ref_device(list[i]);
        }
    }
    if (n >= 0)
    {
        libusb_free_device_list(list, 1);
    }
    return found;
}

/*=============================================================================
  Cameras as pairs: a depth function and a colour function with one serial
=============================================================================*/

static int compare_serials(const void *a, const void *b)
{
    return strcmp((const char *)a, (const char *)b);
}

/* The serials of every camera that has both functions attached, sorted, so
 * an index means the same camera from one call to the next. */
static uint32_t paired_serials(char serials[][OPENK4A_SERIAL_CHARS], uint32_t capacity)
{
    libusb_context *context = openk4a_usb_context();
    if (context == NULL)
    {
        return 0;
    }
    libusb_device **list = NULL;
    const ssize_t n = libusb_get_device_list(context, &list);
    char depth[16][OPENK4A_SERIAL_CHARS];
    char color[16][OPENK4A_SERIAL_CHARS];
    uint32_t depth_count = 0;
    uint32_t color_count = 0;
    for (ssize_t i = 0; i < n; i++)
    {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(list[i], &descriptor) != 0 || descriptor.idVendor != OPENK4A_USB_VID)
        {
            continue;
        }
        char serial[OPENK4A_SERIAL_CHARS];
        if (descriptor.idProduct == OPENK4A_USB_DEPTH.pid && depth_count < 16 && device_serial(list[i], serial, sizeof(serial)))
        {
            snprintf(depth[depth_count++], OPENK4A_SERIAL_CHARS, "%s", serial);
        }
        else if (descriptor.idProduct == OPENK4A_USB_COLOR.pid && color_count < 16 && device_serial(list[i], serial, sizeof(serial)))
        {
            snprintf(color[color_count++], OPENK4A_SERIAL_CHARS, "%s", serial);
        }
    }
    if (n >= 0)
    {
        libusb_free_device_list(list, 1);
    }
    uint32_t count = 0;
    for (uint32_t d = 0; d < depth_count && count < capacity; d++)
    {
        for (uint32_t c = 0; c < color_count; c++)
        {
            if (strcmp(depth[d], color[c]) == 0)
            {
                snprintf(serials[count++], OPENK4A_SERIAL_CHARS, "%s", depth[d]);
                break;
            }
        }
    }
    if (count > 1)
    {
        qsort(serials, count, OPENK4A_SERIAL_CHARS, compare_serials);
    }
    return count;
}

uint32_t openk4a_usb_camera_count(void)
{
    char serials[16][OPENK4A_SERIAL_CHARS];
    return paired_serials(serials, 16);
}

bool openk4a_usb_camera_serial(uint32_t index, char *out, size_t out_size)
{
    char serials[16][OPENK4A_SERIAL_CHARS];
    const uint32_t count = paired_serials(serials, 16);
    if (index >= count)
    {
        if (out_size > 0)
        {
            out[0] = '\0';
        }
        return false;
    }
    snprintf(out, out_size, "%s", serials[index]);
    return true;
}

static bool usb_open_device(openk4a_usb_t *usb, const openk4a_usb_id_t *id, libusb_device *device)
{
    libusb_device_handle *handle = NULL;
    int rc = libusb_open(device, &handle);
    if (rc != 0)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "cannot open 045E:%04X: %s", (unsigned)id->pid, libusb_error_name(rc));
        libusb_unref_device(device);
        return false;
    }

    const int interface_number = id->interface_mi < 0 ? 0 : id->interface_mi;
    if (!endpoint_present(device, interface_number, id->endpoint_out) ||
        !endpoint_present(device, interface_number, id->endpoint_in) ||
        !endpoint_present(device, interface_number, id->endpoint_stream))
    {
        openk4a_log(OPENK4A_LOG_ERROR, "the expected endpoints are not on interface %d of 045E:%04X", interface_number, (unsigned)id->pid);
        libusb_close(handle);
        libusb_unref_device(device);
        return false;
    }

    rc = libusb_claim_interface(handle, interface_number);
    if (rc != 0)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "cannot claim interface %d of 045E:%04X: %s (is another program using the camera?)",
                interface_number, (unsigned)id->pid, libusb_error_name(rc));
        libusb_close(handle);
        libusb_unref_device(device);
        return false;
    }

    struct libusb_device_descriptor descriptor;
    if (libusb_get_device_descriptor(device, &descriptor) == 0 && descriptor.iSerialNumber != 0)
    {
        unsigned char serial[sizeof(usb->serial)];
        const int got = libusb_get_string_descriptor_ascii(handle, descriptor.iSerialNumber, serial, sizeof(serial) - 1);
        if (got > 0)
        {
            serial[got] = '\0';
            snprintf(usb->serial, sizeof(usb->serial), "%s", (const char *)serial);
        }
    }
    usb->bus = libusb_get_bus_number(device);
    usb->address = libusb_get_device_address(device);
    snprintf(usb->path, sizeof(usb->path), "usb:%u.%u", (unsigned)usb->bus, (unsigned)usb->address);
    libusb_unref_device(device);

    usb->handle = handle;
    usb->interface_number = interface_number;
    usb->endpoint_out = id->endpoint_out;
    usb->endpoint_in = id->endpoint_in;
    usb->endpoint_stream = id->endpoint_stream;
    return true;
}

bool openk4a_usb_open(openk4a_usb_t *usb, const openk4a_usb_id_t *id, uint32_t index)
{
    memset(usb, 0, sizeof(*usb));
    usb->command_timeout_ms = OPENK4A_CMD_TIMEOUT_MS;
    usb->stream_timeout_ms = OPENK4A_CMD_TIMEOUT_MS;
    libusb_device *device = find_device(id, index, NULL);
    if (device == NULL)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "no Kinect device 045E:%04X at index %u", (unsigned)id->pid, (unsigned)index);
        return false;
    }
    return usb_open_device(usb, id, device);
}

bool openk4a_usb_open_serial(openk4a_usb_t *usb, const openk4a_usb_id_t *id, const char *serial)
{
    memset(usb, 0, sizeof(*usb));
    usb->command_timeout_ms = OPENK4A_CMD_TIMEOUT_MS;
    usb->stream_timeout_ms = OPENK4A_CMD_TIMEOUT_MS;
    libusb_device *device = find_device_by_serial(id, serial);
    if (device == NULL)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "no Kinect device 045E:%04X with serial %s", (unsigned)id->pid, serial != NULL ? serial : "");
        return false;
    }
    return usb_open_device(usb, id, device);
}

/*=============================================================================
  Hotplug

  libusb's Darwin backend reports arrivals and departures on the event
  thread. A departure cannot be asked for its serial (the device is gone),
  so serials are remembered by bus and address as devices are seen.
=============================================================================*/

typedef struct
{
    openk4a_hotplug_fn *callback;
    void *context;
    int token;
} hotplug_subscriber_t;

static hotplug_subscriber_t hotplug_subscribers[8];
static int hotplug_next_token = 1;
static libusb_hotplug_callback_handle hotplug_handle;
static bool hotplug_registered;
static pthread_mutex_t hotplug_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct
{
    uint8_t bus;
    uint8_t address;
    char serial[OPENK4A_SERIAL_CHARS];
} hotplug_seen_t;

static hotplug_seen_t hotplug_seen[32];

static void hotplug_notify(bool arrived, const char *serial)
{
    hotplug_subscriber_t copy[8];
    pthread_mutex_lock(&hotplug_lock);
    memcpy(copy, hotplug_subscribers, sizeof(copy));
    pthread_mutex_unlock(&hotplug_lock);
    for (int i = 0; i < 8; i++)
    {
        if (copy[i].callback != NULL)
        {
            copy[i].callback(copy[i].context, arrived, serial);
        }
    }
}

typedef struct
{
    libusb_device *device;
} hotplug_arrival_t;

/* The serial is read on a thread of its own: opening a device from inside
 * libusb's callback is not allowed. */
static void *hotplug_arrival_thread(void *parameter)
{
    hotplug_arrival_t *arrival = (hotplug_arrival_t *)parameter;
    char serial[OPENK4A_SERIAL_CHARS] = "";
    /* The device may still be settling: a few tries over a second. */
    for (int attempt = 0; attempt < 10 && !device_serial(arrival->device, serial, sizeof(serial)); attempt++)
    {
        usleep(100000);
    }
    const uint8_t bus = libusb_get_bus_number(arrival->device);
    const uint8_t address = libusb_get_device_address(arrival->device);
    libusb_unref_device(arrival->device);
    free(arrival);
    pthread_mutex_lock(&hotplug_lock);
    int slot = -1;
    for (int i = 0; i < 32; i++)
    {
        if (hotplug_seen[i].serial[0] == '\0' && slot < 0)
        {
            slot = i;
        }
        if (hotplug_seen[i].bus == bus && hotplug_seen[i].address == address && hotplug_seen[i].serial[0] != '\0')
        {
            slot = i;
            break;
        }
    }
    if (slot >= 0)
    {
        hotplug_seen[slot].bus = bus;
        hotplug_seen[slot].address = address;
        snprintf(hotplug_seen[slot].serial, OPENK4A_SERIAL_CHARS, "%s", serial);
    }
    pthread_mutex_unlock(&hotplug_lock);
    hotplug_notify(true, serial);
    return NULL;
}

static int LIBUSB_CALL hotplug_event(libusb_context *context, libusb_device *device, libusb_hotplug_event event, void *user_data)
{
    (void)context;
    (void)user_data;
    if (event == LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED)
    {
        hotplug_arrival_t *arrival = (hotplug_arrival_t *)calloc(1, sizeof(*arrival));
        if (arrival != NULL)
        {
            arrival->device = libusb_ref_device(device);
            pthread_t thread;
            pthread_attr_t attributes;
            pthread_attr_init(&attributes);
            pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
            if (pthread_create(&thread, &attributes, hotplug_arrival_thread, arrival) != 0)
            {
                libusb_unref_device(device);
                free(arrival);
            }
            pthread_attr_destroy(&attributes);
        }
    }
    else if (event == LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT)
    {
        const uint8_t bus = libusb_get_bus_number(device);
        const uint8_t address = libusb_get_device_address(device);
        char serial[OPENK4A_SERIAL_CHARS] = "";
        pthread_mutex_lock(&hotplug_lock);
        for (int i = 0; i < 32; i++)
        {
            if (hotplug_seen[i].bus == bus && hotplug_seen[i].address == address && hotplug_seen[i].serial[0] != '\0')
            {
                snprintf(serial, sizeof(serial), "%s", hotplug_seen[i].serial);
                hotplug_seen[i].serial[0] = '\0';
                break;
            }
        }
        pthread_mutex_unlock(&hotplug_lock);
        hotplug_notify(false, serial);
    }
    return 0; /* keep the registration */
}

int openk4a_hotplug_subscribe(openk4a_hotplug_fn *callback, void *context)
{
    libusb_context *usb = openk4a_usb_context();
    if (usb == NULL || callback == NULL || !libusb_has_capability(LIBUSB_CAP_HAS_HOTPLUG))
    {
        return 0;
    }
    pthread_mutex_lock(&hotplug_lock);
    int token = 0;
    for (int i = 0; i < 8; i++)
    {
        if (hotplug_subscribers[i].callback == NULL)
        {
            token = hotplug_next_token++;
            hotplug_subscribers[i].callback = callback;
            hotplug_subscribers[i].context = context;
            hotplug_subscribers[i].token = token;
            break;
        }
    }
    const bool need_registration = token != 0 && !hotplug_registered;
    pthread_mutex_unlock(&hotplug_lock);
    if (need_registration)
    {
        /* The depth function stands for the camera: it is the one every
         * program opens first. ENUMERATE reports what is already attached. */
        const int rc = libusb_hotplug_register_callback(usb,
                                                        LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED | LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT,
                                                        LIBUSB_HOTPLUG_ENUMERATE,
                                                        OPENK4A_USB_VID,
                                                        OPENK4A_USB_DEPTH.pid,
                                                        LIBUSB_HOTPLUG_MATCH_ANY,
                                                        hotplug_event,
                                                        NULL,
                                                        &hotplug_handle);
        pthread_mutex_lock(&hotplug_lock);
        hotplug_registered = rc == LIBUSB_SUCCESS;
        if (!hotplug_registered)
        {
            for (int i = 0; i < 8; i++)
            {
                if (hotplug_subscribers[i].token == token)
                {
                    memset(&hotplug_subscribers[i], 0, sizeof(hotplug_subscribers[i]));
                }
            }
            token = 0;
            openk4a_log(OPENK4A_LOG_WARNING, "hotplug registration failed: %s", libusb_error_name(rc));
        }
        pthread_mutex_unlock(&hotplug_lock);
    }
    return token;
}

void openk4a_hotplug_unsubscribe(int token)
{
    pthread_mutex_lock(&hotplug_lock);
    for (int i = 0; i < 8; i++)
    {
        if (hotplug_subscribers[i].token == token && token != 0)
        {
            memset(&hotplug_subscribers[i], 0, sizeof(hotplug_subscribers[i]));
        }
    }
    pthread_mutex_unlock(&hotplug_lock);
}

void openk4a_usb_close(openk4a_usb_t *usb)
{
    if (usb == NULL || usb->handle == NULL)
    {
        return;
    }
    libusb_release_interface(usb->handle, usb->interface_number);
    libusb_close(usb->handle);
    usb->handle = NULL;
}

bool openk4a_usb_set_timeout(openk4a_usb_t *usb, uint8_t endpoint, uint32_t milliseconds)
{
    if (usb == NULL)
    {
        return false;
    }
    if (endpoint == usb->endpoint_stream)
    {
        usb->stream_timeout_ms = milliseconds;
    }
    else
    {
        usb->command_timeout_ms = milliseconds;
    }
    return true;
}

/*=============================================================================
  Reading and writing
=============================================================================*/

static bool read_bulk(openk4a_usb_t *usb, uint8_t endpoint, void *buffer, size_t size, size_t *received)
{
    for (int attempt = 0; attempt < OPENK4A_READ_ATTEMPTS; attempt++)
    {
        int got = 0;
        const int rc = libusb_bulk_transfer(usb->handle, endpoint, (unsigned char *)buffer, (int)size, &got,
                                            usb->command_timeout_ms);
        if (rc != 0 && rc != LIBUSB_ERROR_TIMEOUT)
        {
            openk4a_log(OPENK4A_LOG_ERROR, "reading %zu bytes failed: %s", size, libusb_error_name(rc));
            return false;
        }
        if (rc == LIBUSB_ERROR_TIMEOUT && got == 0)
        {
            openk4a_log(OPENK4A_LOG_ERROR, "reading %zu bytes timed out", size);
            return false;
        }
        if (got > 0)
        {
            *received = (size_t)got;
            return true;
        }
    }
    *received = 0;
    return true;
}

static bool write_bulk(openk4a_usb_t *usb, uint8_t endpoint, const void *buffer, size_t size)
{
    int sent = 0;
    const int rc = libusb_bulk_transfer(usb->handle, endpoint, (unsigned char *)buffer, (int)size, &sent,
                                        usb->command_timeout_ms);
    return rc == 0 && (size_t)sent == size;
}

bool openk4a_usb_command(openk4a_usb_t *usb,
                         uint32_t command,
                         const void *command_data,
                         size_t command_data_size,
                         const void *tx_data,
                         size_t tx_size,
                         void *rx_data,
                         size_t rx_size,
                         size_t *bytes_read,
                         uint32_t *status)
{
    if (usb == NULL || usb->handle == NULL)
    {
        return false;
    }
    if (bytes_read != NULL)
    {
        *bytes_read = 0;
    }
    if (command_data_size > OPENK4A_CMD_PACKET_DATA_BYTES)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "command %08X carries %zu bytes of data, over the packet's %d",
                command, command_data_size, OPENK4A_CMD_PACKET_DATA_BYTES);
        return false;
    }

    const size_t payload_size = rx_size != 0 ? rx_size : tx_size;

    openk4a_command_packet_t packet;
    memset(&packet, 0, sizeof(packet));
    packet.header.packet_type = OPENK4A_CMD_PACKET_TYPE;
    packet.header.packet_transaction_id = usb->transaction_id++;
    packet.header.payload_size = (uint32_t)payload_size;
    packet.header.command = command;
    if (command_data != NULL && command_data_size > 0)
    {
        memcpy(packet.data, command_data, command_data_size);
    }

    if (!write_bulk(usb, usb->endpoint_out, &packet, sizeof(openk4a_command_header_t) + command_data_size))
    {
        openk4a_log(OPENK4A_LOG_ERROR, "command %08X: sending the header failed", command);
        return false;
    }
    if (tx_data != NULL && tx_size > 0 && !write_bulk(usb, usb->endpoint_out, tx_data, tx_size))
    {
        openk4a_log(OPENK4A_LOG_ERROR, "command %08X: sending %zu bytes failed", command, tx_size);
        return false;
    }

    if (rx_data != NULL && rx_size > 0)
    {
        size_t got = 0;
        if (!read_bulk(usb, usb->endpoint_in, rx_data, rx_size, &got))
        {
            return false;
        }
        if (bytes_read != NULL)
        {
            *bytes_read = got;
        }
    }

    openk4a_command_response_t response;
    memset(&response, 0, sizeof(response));
    bool matched = false;
    for (int attempt = 0; attempt < 3 && !matched; attempt++)
    {
        size_t got = 0;
        if (!read_bulk(usb, usb->endpoint_in, &response, sizeof(response), &got))
        {
            return false;
        }
        if (got != sizeof(response))
        {
            openk4a_log(OPENK4A_LOG_ERROR, "command %08X: the response was %zu bytes, not %zu", command, got, sizeof(response));
            return false;
        }
        matched = response.packet_type == OPENK4A_CMD_PACKET_TYPE_RESPONSE &&
                  response.packet_transaction_id == packet.header.packet_transaction_id;
        if (!matched)
        {
            openk4a_log(OPENK4A_LOG_TRACE, "command %08X: dropped a response for id %u (this command is id %u)",
                    command, response.packet_transaction_id, packet.header.packet_transaction_id);
        }
    }
    if (!matched)
    {
        openk4a_log(OPENK4A_LOG_ERROR, "command %08X (id %u): the response never carried its id (last: type %08X id %u status %08X)",
                command, packet.header.packet_transaction_id, response.packet_type, response.packet_transaction_id, response.status);
        return false;
    }
    if (status != NULL)
    {
        *status = response.status;
    }
    return response.status == 0;
}

/*=============================================================================
  Asynchronous stream reads
=============================================================================*/

static void LIBUSB_CALL io_complete(struct libusb_transfer *transfer)
{
    openk4a_io_t *io = (openk4a_io_t *)transfer->user_data;
    pthread_mutex_lock(&io->lock);
    io->transferred = (size_t)transfer->actual_length;
    io->status = (int)transfer->status;
    io->pending = false;
    io->ready = true;
    pthread_cond_broadcast(&io->done);
    pthread_mutex_unlock(&io->lock);
}

static bool io_init(openk4a_io_t *io)
{
    if (io->inited)
    {
        return true;
    }
    if (pthread_mutex_init(&io->lock, NULL) != 0)
    {
        return false;
    }
    if (pthread_cond_init(&io->done, NULL) != 0)
    {
        pthread_mutex_destroy(&io->lock);
        return false;
    }
    io->inited = true;
    return true;
}

bool openk4a_usb_io_post(openk4a_usb_t *usb, openk4a_io_t *io)
{
    if (usb == NULL || usb->handle == NULL || io == NULL || io->buffer == NULL || !io_init(io))
    {
        return false;
    }
    if (io->transfer == NULL)
    {
        io->transfer = libusb_alloc_transfer(0);
        if (io->transfer == NULL)
        {
            return false;
        }
    }
    pthread_mutex_lock(&io->lock);
    if (io->pending)
    {
        pthread_mutex_unlock(&io->lock);
        return true; /* already in flight */
    }
    io->transferred = 0;
    io->ready = false;
    io->status = 0;
    libusb_fill_bulk_transfer(io->transfer, usb->handle, usb->endpoint_stream, io->buffer, (int)io->size, io_complete, io,
                              usb->stream_timeout_ms);
    const int rc = libusb_submit_transfer(io->transfer);
    if (rc != 0)
    {
        pthread_mutex_unlock(&io->lock);
        openk4a_log(OPENK4A_LOG_ERROR, "the stream read would not start: %s", libusb_error_name(rc));
        return false;
    }
    io->pending = true;
    pthread_mutex_unlock(&io->lock);
    return true;
}

int openk4a_usb_io_wait(openk4a_usb_t *usb, openk4a_io_t *io, int timeout_ms)
{
    (void)usb;
    if (io == NULL || !io->inited)
    {
        return OPENK4A_FAILED;
    }
    pthread_mutex_lock(&io->lock);
    if (!io->ready && !io->pending)
    {
        pthread_mutex_unlock(&io->lock);
        return OPENK4A_FAILED;
    }
    if (!io->ready)
    {
        if (timeout_ms < 0)
        {
            while (!io->ready)
            {
                pthread_cond_wait(&io->done, &io->lock);
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
            while (!io->ready)
            {
                if (pthread_cond_timedwait(&io->done, &io->lock, &deadline) == ETIMEDOUT)
                {
                    break;
                }
            }
        }
    }
    if (!io->ready)
    {
        pthread_mutex_unlock(&io->lock);
        return OPENK4A_TIMEOUT;
    }
    const int status = io->status;
    pthread_mutex_unlock(&io->lock);

    if (status == LIBUSB_TRANSFER_COMPLETED)
    {
        return OPENK4A_OK;
    }
    if (status == LIBUSB_TRANSFER_TIMED_OUT || status == LIBUSB_TRANSFER_CANCELLED)
    {
        /* A transfer the timeout cut short is how a frame that was not there
         * is reported; the caller re-posts and asks again. */
        return OPENK4A_TIMEOUT;
    }
    openk4a_log(OPENK4A_LOG_ERROR, "the stream read failed (status %d)", status);
    return OPENK4A_FAILED;
}

void openk4a_usb_io_cancel(openk4a_usb_t *usb, openk4a_io_t *io)
{
    (void)usb;
    if (io == NULL || !io->inited || io->transfer == NULL)
    {
        return;
    }
    pthread_mutex_lock(&io->lock);
    if (io->pending)
    {
        libusb_cancel_transfer(io->transfer);
        while (io->pending)
        {
            pthread_cond_wait(&io->done, &io->lock);
        }
    }
    io->ready = false;
    pthread_mutex_unlock(&io->lock);
}

void openk4a_usb_io_close(openk4a_usb_t *usb, openk4a_io_t *io)
{
    if (io == NULL)
    {
        return;
    }
    openk4a_usb_io_cancel(usb, io);
    if (io->transfer != NULL)
    {
        libusb_free_transfer(io->transfer);
        io->transfer = NULL;
    }
    if (io->inited)
    {
        pthread_cond_destroy(&io->done);
        pthread_mutex_destroy(&io->lock);
        io->inited = false;
    }
    openk4a_free(io->buffer);
    io->buffer = NULL;
}
